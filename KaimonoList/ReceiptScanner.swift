import SwiftUI
import UIKit
import Vision
import VisionKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - 文字認識(Vision)

/// レシート画像から文字を読み取り、行ごとの文字列にする。
/// 端末内で処理するため、画像やテキストが外部に送られることはない。
enum ReceiptTextRecognizer {

    static func recognizeLines(in image: UIImage) async throws -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)

        // 重い文字認識だけをバックグラウンドで行い、Sendable な (文字列, 位置) の組で受け取る。
        // 行へのまとめは呼び出し側で行う(既定のアクター分離の設定によらずコンパイルできるように)
        let recognized: [(String, CGRect)] = try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ja-JP", "en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            try handler.perform([request])

            return (request.results ?? []).compactMap { observation -> (String, CGRect)? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                return (text, observation.boundingBox)
            }
        }.value

        let fragments = recognized.map { ReceiptRowGrouper.Fragment(text: $0.0, box: $0.1) }
        return ReceiptRowGrouper.rows(from: fragments)
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

// MARK: - 端末内 AI での整形(Apple Intelligence 対応端末のみ)

/// 読み取った文字列を端末内の言語モデル(Foundation Models)で整理し、
/// 店名・日付・合計・品目を取り出す。レシートは店ごとにレイアウトが違うため、
/// ルールベースだけでは崩れやすい品目の切り分けを補う。
/// iOS 26 未満・非対応端末・Apple Intelligence オフのときは何もしない(nil を返す)。
enum ReceiptAIExtractor {

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static func extract(from lines: [String]) async -> ReceiptParser.Result? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard isAvailable else { return nil }
            do {
                let session = LanguageModelSession(instructions: """
            あなたはレシートの文字起こしから情報を取り出すアシスタントです。
            必ず次の形式の JSON だけを出力してください。説明文やコードブロックは不要です。
            {"storeName": "店名", "date": "yyyy-MM-dd", "total": 合計金額の整数, "items": [{"name": "商品名", "price": 小計の整数, "quantity": 個数の整数}]}
            - total は税込の支払い合計(円)。分からなければ 0
            - date が分からなければ空文字
            - items には購入した商品だけを入れる。小計・合計・消費税・お預り・お釣り・ポイント・支払方法は入れない
            - 商品名がはっきり読み取れないもの(数字・記号だけの断片、1文字だけの英字など)は無理に入れない
            - quantity はその商品を買った個数。1個なら 1
            - price は単価ではなく、その商品の小計(単価×個数、値引き後)。
              例:「2点 x @214 428」は {"name":"…","price":428,"quantity":2}、
                 「3コX198 594」は {"name":"…","price":594,"quantity":3}
            - 「@」や「単」の後ろの数字は単価なので price には入れない(単価×個数の結果を入れる)
            - 値引き・割引は直前の商品の小計から差し引く
            - 商品名は読みやすい表記にする(略称はそのままでよい)
            """)
                let prompt = "レシートの文字起こし:\n" + lines.joined(separator: "\n")
                let response = try await session.respond(to: prompt)
                return decode(response.content)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    /// モデルの出力(JSON 文字列)を Result に変換する。前後に余計な文字があっても
    /// 最初の { から最後の } までを取り出して読む。純粋関数(テスト用に公開)。
    static func decode(_ text: String) -> ReceiptParser.Result? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        struct Payload: Decodable {
            struct Item: Decodable {
                var name: String?
                var price: Int?
                var quantity: Int?
            }
            var storeName: String?
            var date: String?
            var total: Int?
            var items: [Item]?
        }
        guard let data = String(text[start...end]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }

        var result = ReceiptParser.Result()
        if let store = payload.storeName?.trimmingCharacters(in: .whitespacesAndNewlines), !store.isEmpty {
            result.storeName = store
        }
        // 日付は書式を検証してから採用する(存在しない日付・別書式は捨てる)
        if let date = payload.date {
            result.dateKey = ReceiptParser.dateKey(in: ReceiptParser.normalize(date))
        }
        if let total = payload.total, total > 0 { result.total = total }
        result.items = (payload.items ?? []).compactMap { item in
            guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  let price = item.price, price > 0 else { return nil }
            return .init(name: name, price: price, quantity: max(item.quantity ?? 1, 1))
        }
        return result
    }
}

// MARK: - レシートを撮影するカメラ(VisionKit)

/// レシートの輪郭を自動で検出し、傾きを補正して撮影できる書類スキャナ。
/// 長いレシートは複数枚に分けて撮影でき、すべてのページをまとめて読み取る。
struct DocumentCameraView: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void
    let onCancel: () -> Void

    /// この端末で書類スキャナが使えるか(シミュレータなどでは使えない)
    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentCameraView

        init(parent: DocumentCameraView) {
            self.parent = parent
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.onFinish(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            parent.onCancel()
        }
    }
}
