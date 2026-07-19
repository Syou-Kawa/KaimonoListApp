import Foundation

// MARK: - ウィジェットと共有する買い物リストのスナップショット

/// アプリとウィジェット拡張で共有する、未購入リストの軽量スナップショット。
/// ウィジェットは別プロセスで動き Firebase に触れないため、アプリが Firestore で
/// 受け取った内容を App Group 共有領域にファイルとして書き出し、ウィジェットはそれを読む。
struct SharedShoppingSnapshot: Codable {
    /// ウィジェット表示に必要な最小限のアイテム情報。
    struct Item: Codable, Identifiable {
        var id: String
        var name: String
        var quantity: String?
        /// カテゴリ(売り場)の絵文字。未分類は "❓"。
        var categoryEmoji: String
    }

    /// 未購入アイテム(売り場=カテゴリ順)。表示件数はウィジェット側で絞る。
    var uncheckedItems: [Item]
    /// 未購入の総数。ウィジェットの残数表示や「他N件」表示に使う。
    var uncheckedCount: Int
    /// スナップショットを書き出した時刻。
    var updatedAt: Date

    /// 未書き込み・読み込み失敗時に使う空スナップショット。
    static let empty = SharedShoppingSnapshot(uncheckedItems: [], uncheckedCount: 0, updatedAt: .distantPast)
}

// MARK: - App Group 経由の読み書き

/// スナップショットを App Group 共有領域のファイルへ読み書きするヘルパー。
/// アプリ・ウィジェット双方のターゲットに所属させて共有する。
enum SharedShoppingStore {
    /// App Groups Capability で作成する識別子。両ターゲットで一致させること。
    static let appGroupId = "group.com.kawasoe.KaimonoList"
    private static let fileName = "shopping-snapshot.json"

    /// 共有領域内のファイルURL。App Group 未設定の環境では nil。
    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?
            .appendingPathComponent(fileName)
    }

    /// スナップショットを共有領域へ書き出す(アプリ側から呼ぶ)。
    /// 共有領域が無い・書き込み失敗は致命的でないため握りつぶす。
    static func save(_ snapshot: SharedShoppingSnapshot) {
        guard let url = fileURL else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            // 書き込み失敗は表示が古くなるだけなので無視する
        }
    }

    /// 共有領域からスナップショットを読み込む(ウィジェット側から呼ぶ)。
    /// 未書き込み・読み込み失敗時は空スナップショットを返す。
    static func load() -> SharedShoppingSnapshot {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(SharedShoppingSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }
}
