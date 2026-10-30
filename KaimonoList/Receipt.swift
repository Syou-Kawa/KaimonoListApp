import Foundation
import CoreGraphics
import FirebaseFirestore

// MARK: - レシート(家計簿)

/// households/{id}/receipts/{id} に保存。世帯で共有する家計簿の1枚分。
/// 品目は配列としてドキュメントに埋め込む(品目単位で検索・共有する要件がないため)。
struct Receipt: Identifiable, Codable, Equatable {
    @DocumentID var id: String?
    var storeName: String
    /// 購入日。端末タイムゾーンの暦日 "yyyy-MM-dd"(献立と同じキー形式)。
    /// 文字列の辞書順 = 日付順なので、月単位の範囲クエリがそのまま使える
    var date: String
    /// 支払った合計金額(円・税込)
    var total: Int
    var items: [ReceiptItem]
    var memo: String?
    var addedByUid: String
    var addedByName: String
    /// このレシートから追加した購入履歴(purchaseHistory)のドキュメントID。
    /// レシートの編集・削除時に、対応する購入履歴も差し替え/削除するために持つ。
    /// nil / 空 = 購入履歴へは追加していない
    var purchaseHistoryIds: [String]?
    @ServerTimestamp var createdAt: Date?
}

/// レシート内の品目1件
struct ReceiptItem: Identifiable, Codable, Equatable, Hashable {
    var id: String = UUID().uuidString   // 編集画面の ForEach 用に安定したIDを持つ
    var name: String
    /// 金額(円)。同じ商品を複数買った場合は個数分の小計。値引きは反映済みの額
    var price: Int
    /// 購入個数。同じ商品をまとめ買いしたときの数。nil / 1 = 単品。
    /// 既存のレシートには無いプロパティなので Optional(キー欠落でデコードが壊れない)
    var quantity: Int?
    /// ItemCategory のドキュメントID。カテゴリ別の集計・購入履歴に使う。nil = 未分類
    var categoryId: String?

    /// 表示・計算に使う個数(未設定は 1)
    var resolvedQuantity: Int { max(quantity ?? 1, 1) }
}

/// 確認・編集画面で使う、保存前のレシート。
/// 読み取り結果や既存レシートから作り、ユーザーが修正してから保存する。
struct ReceiptDraft: Equatable {
    var storeName: String = ""
    var date: Date = Date()
    /// 合計金額。nil = 未入力(保存時は品目の合計を使う)
    var total: Int?
    var items: [ReceiptItem] = []
    var memo: String = ""

    /// 品目の金額の合計
    var itemsTotal: Int { items.reduce(0) { $0 + $1.price } }

    /// 保存する合計金額(未入力なら品目の合計)
    var resolvedTotal: Int { total ?? itemsTotal }

    /// 何も入力されていない(保存する意味がない)状態か
    var isEmpty: Bool {
        storeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && items.isEmpty
            && (total ?? 0) == 0
    }
}

// MARK: - 金額表示

enum Yen {
    /// 1234 → "¥1,234"(端末の言語設定に左右されない表記)
    static func format(_ amount: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "ja_JP")
        let body = formatter.string(from: NSNumber(value: abs(amount))) ?? String(abs(amount))
        return (amount < 0 ? "-¥" : "¥") + body
    }
}

// MARK: - 家計簿の集計

/// 月のレシートからカテゴリ別の支出を集計する純粋関数。
/// Firestore に依存しないのでユニットテストから直接呼べる。
enum ReceiptSummary {

    struct CategoryTotal: Identifiable, Equatable {
        let id: String        // categoryId または "uncategorized"
        let title: String     // "🥬 野菜・果物"
        let amount: Int
    }

    /// 品目の金額をカテゴリごとに合計し、金額の大きい順(同額はカテゴリの並び順)に返す。
    /// カテゴリ未設定・削除済みカテゴリの品目は「未分類」にまとめる。
    static func categoryTotals(receipts: [Receipt], categories: [ItemCategory]) -> [CategoryTotal] {
        var amounts: [String: Int] = [:]
        let knownIds = Set(categories.compactMap(\.id))
        for receipt in receipts {
            for item in receipt.items {
                let key = item.categoryId.flatMap { knownIds.contains($0) ? $0 : nil } ?? "uncategorized"
                amounts[key, default: 0] += item.price
            }
        }

        var result: [CategoryTotal] = []
        for category in categories {
            guard let id = category.id, let amount = amounts[id], amount != 0 else { continue }
            result.append(CategoryTotal(id: id, title: "\(category.emoji) \(category.name)", amount: amount))
        }
        if let amount = amounts["uncategorized"], amount != 0 {
            result.append(CategoryTotal(id: "uncategorized", title: "❓ 未分類", amount: amount))
        }
        // categories の並び順を保ったまま、金額の大きい順に安定ソートする
        return result.enumerated()
            .sorted { lhs, rhs in
                lhs.element.amount != rhs.element.amount
                    ? lhs.element.amount > rhs.element.amount
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

// MARK: - OCR 結果を行にまとめる

/// Vision の文字認識結果(断片 + 位置)を、レシートの「行」単位の文字列にまとめる純粋関数。
/// レシートは品名(左)と金額(右)が離れているため、Vision では別々の断片として
/// 返ってくることが多い。縦位置が近い断片を同じ行とみなして左から順に連結する。
enum ReceiptRowGrouper {

    /// 認識した文字列の断片。box は Vision の正規化座標(原点は左下、y は上向き)
    struct Fragment: Equatable {
        var text: String
        var box: CGRect
    }

    static func rows(from fragments: [Fragment]) -> [String] {
        struct Row {
            var fragments: [Fragment]
            var midY: CGFloat
            var height: CGFloat
        }

        // 上(midY が大きい)から順に処理する
        let sorted = fragments
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.box.midY > $1.box.midY }

        var rows: [Row] = []
        for fragment in sorted {
            let height = max(fragment.box.height, 0.0001)
            // 縦の中心のずれが、行と断片の低いほうの高さの半分未満なら同じ行
            if let index = rows.firstIndex(where: {
                abs($0.midY - fragment.box.midY) < min($0.height, height) * 0.5
            }) {
                rows[index].fragments.append(fragment)
                let count = CGFloat(rows[index].fragments.count)
                rows[index].midY += (fragment.box.midY - rows[index].midY) / count
                rows[index].height = max(rows[index].height, height)
            } else {
                rows.append(Row(fragments: [fragment], midY: fragment.box.midY, height: height))
            }
        }

        return rows
            .sorted { $0.midY > $1.midY }
            .map { row in
                row.fragments
                    .sorted { $0.box.minX < $1.box.minX }
                    .map { $0.text.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: " ")
            }
    }
}

// MARK: - レシートの文字列解析(ルールベース)

/// OCR で読み取った行から、店名・日付・合計・品目を取り出す純粋関数。
/// 端末内 AI(Apple Intelligence)が使えない端末でも動く基本の解析で、
/// AI が使える場合も日付・合計はこちらの結果を優先する(決まった書式なので確実)。
/// 状態を持たない純粋関数の集まりなので、どのスレッドからでも呼べるよう nonisolated にする。
/// (既定の MainActor 隔離のままだと、map/firstIndex に関数参照を渡す箇所で隔離の警告が出る)
nonisolated enum ReceiptParser {

    struct Result: Equatable {
        struct Line: Equatable {
            var name: String
            /// 個数分の小計(値引き反映済み)
            var price: Int
            /// 購入個数(既定は1)
            var quantity: Int = 1
        }
        var storeName: String?
        /// 購入日 "yyyy-MM-dd"
        var dateKey: String?
        var total: Int?
        var items: [Line] = []
    }

    // MARK: 正規化

    /// 半角カナ → 全角カナ、全角英数・記号 → 半角、全角スペース → 半角、
    /// 円記号・マイナス記号の表記ゆれをそろえ、連続する空白を1つにする。
    static func normalize(_ text: String) -> String {
        // NFKC 正規化: 半角カナ → 全角カナ(濁点も合成)、全角英数・全角スペース → 半角
        let compat = text.precomposedStringWithCompatibilityMapping
        var scalars = String.UnicodeScalarView()
        for scalar in compat.unicodeScalars {
            switch scalar.value {
            case 0xFF01...0xFF5E:                       // 全角 ASCII
                scalars.append(Unicode.Scalar(scalar.value - 0xFEE0) ?? scalar)
            case 0x3000:                                // 全角スペース
                scalars.append(" ")
            case 0xFFE5, 0x00A5:                        // ￥ ¥
                scalars.append("¥")
            case 0x2212, 0x2010, 0x2011, 0x2013, 0x2014, 0xFF0D: // − ‐ ‑ – — －
                scalars.append("-")
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: 解析

    static func parse(lines rawLines: [String]) -> Result {
        let lines = rawLines.map(normalize).filter { !$0.isEmpty }
        var result = Result()

        // 日付(最初に見つかったもの)
        var dateIndex: Int?
        for (index, line) in lines.enumerated() {
            if let key = dateKey(in: line) {
                result.dateKey = key
                dateIndex = index
                break
            }
        }

        // 合計 / 小計の位置(品目の範囲の終わり)
        let totalIndex = lines.firstIndex(where: isTotalLine)
        let itemsEnd = lines.firstIndex(where: isSectionEndLine) ?? lines.count

        // 合計金額: 合計行の末尾の金額。無ければ次の行の金額だけの行
        if let totalIndex {
            if let price = trailingPrice(in: lines[totalIndex]) {
                result.total = price.amount
            } else if totalIndex + 1 < lines.count,
                      let price = trailingPrice(in: lines[totalIndex + 1]),
                      price.name.isEmpty {
                result.total = price.amount
            }
        }

        // 店名: 先頭付近(日付より上)で、それらしい最初の行
        let headerEnd = min(dateIndex ?? 5, 5, lines.count, itemsEnd)
        if headerEnd > 0 {
            result.storeName = lines[0..<headerEnd].first(where: isStoreNameCandidate)
        }

        // 品目の範囲: 日付行が品目より上にあればその次の行から、なければ先頭から
        var start = 0
        if let dateIndex, dateIndex < itemsEnd { start = dateIndex + 1 }
        if start < itemsEnd {
            result.items = parseItems(Array(lines[start..<itemsEnd]))
        }
        return result
    }

    /// 品目の範囲の行から品名・金額・個数を取り出す。
    /// - 「品名 ¥198」の行 → 品目(個数1)
    /// - 品名だけの行の次に「金額だけ」の行 → 前の品名の品目
    /// - 「2点x@214 ¥428」「3コX198 594」のような数量・単価の行 → 個数と小計を取り出す
    ///   (品名がその行の前半にあればそれを、無ければ直前の品名だけの行を使う)
    /// - 「値引 -50」の行 → 直前の品目の金額から差し引く
    private static func parseItems(_ lines: [String]) -> [Result.Line] {
        var items: [Result.Line] = []
        var pendingName: String?

        for line in lines {
            if isDiscountLine(line) {
                if let price = trailingPrice(in: line), !items.isEmpty {
                    items[items.count - 1].price = max(0, items[items.count - 1].price - abs(price.amount))
                }
                pendingName = nil
                continue
            }
            if let quantityLine = parseQuantityLine(line) {
                // 品名はこの行の前半、なければ直前の品名だけの行を使う
                let name = quantityLine.namePrefix.isEmpty ? (pendingName ?? "") : quantityLine.namePrefix
                if !name.isEmpty, let total = quantityLine.resolvedTotal, total > 0 {
                    items.append(.init(name: name, price: total, quantity: quantityLine.resolvedQuantity))
                }
                pendingName = nil
                continue
            }
            if isNonItemLine(line) {
                pendingName = nil
                continue
            }

            if let price = trailingPrice(in: line) {
                if price.amount <= 0 { pendingName = nil; continue }
                if hasLetters(price.name) {
                    items.append(.init(name: cleanItemName(price.name), price: price.amount))
                    pendingName = nil
                } else if price.name.isEmpty, let name = pendingName {
                    // 品名と金額が別の行に分かれていた
                    items.append(.init(name: name, price: price.amount))
                    pendingName = nil
                }
            } else if hasLetters(line) {
                pendingName = cleanItemName(line)
            }
        }
        // 品名が特定できないもの(断片・記号だけ等)は載せない
        return items.filter { isLikelyItemName($0.name) }
    }

    // MARK: 数量・単価の行

    /// 数量・単価の行を解釈した結果
    struct QuantityLine: Equatable {
        /// 数量より前にある品名部分(品名が別の行にある場合は空)
        var namePrefix: String
        /// 購入個数(読み取れなければ nil)
        var quantity: Int?
        /// 単価(@ や 単 の金額。読み取れなければ nil)
        var unitPrice: Int?
        /// 行末の小計(単価と区別できたときのみ)
        var lineTotal: Int?

        /// この行から確定できる品目の小計。行末の小計を優先し、無ければ 単価×個数
        var resolvedTotal: Int? {
            if let lineTotal { return lineTotal }
            if let unitPrice, let quantity { return unitPrice * quantity }
            return unitPrice
        }

        /// 表示用の個数。読み取れなければ、小計 ÷ 単価 で割り切れる場合はその商(それ以外は1)
        var resolvedQuantity: Int {
            if let quantity { return max(quantity, 1) }
            if let lineTotal, let unitPrice, unitPrice > 0, lineTotal % unitPrice == 0 {
                return max(lineTotal / unitPrice, 1)
            }
            return 1
        }
    }

    /// 行中の「個数」を拾う(2個 / 3コ / 2点 …)。× や @ を伴う行だけが対象(parseQuantityLine 経由)
    private static let quantityCountRegex = try! NSRegularExpression(
        pattern: #"(\d+)\s*(?:個|コ|点|本|袋|パック|枚|ヶ|ケ)"#
    )

    /// 行中の「単価」を拾う(@214 / 単199 / X198 …)
    private static let unitPriceRegex = try! NSRegularExpression(
        pattern: #"(?:@|単|[xX×])\s*¥?\s*(\d{1,3}(?:,\d{3})+|\d+)"#
    )

    /// 「2点 x @214 ¥428」「3コX198 594」のような数量・単価の行を解釈する。
    /// 数量行でなければ nil。品名・個数・単価・小計を取り出す。
    static func parseQuantityLine(_ line: String) -> QuantityLine? {
        guard isQuantityLine(line) else { return nil }
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)

        var quantity: Int?
        var namePrefix = ""
        if let match = quantityCountRegex.firstMatch(in: line, range: full) {
            quantity = Int(ns.substring(with: match.range(at: 1)))
            namePrefix = ns.substring(to: match.range.location)
        }

        var unitPrice: Int?
        if let match = unitPriceRegex.firstMatch(in: line, range: full) {
            let digits = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")
            unitPrice = Int(digits)
        }

        // 行末に単価と異なる金額があれば、それを小計とみなす(「@214 ¥428」の 428)
        var lineTotal: Int?
        if let amount = trailingPrice(in: line)?.amount, amount > 0, amount != unitPrice {
            lineTotal = amount
        }

        return QuantityLine(
            namePrefix: cleanItemName(namePrefix),
            quantity: quantity,
            unitPrice: unitPrice,
            lineTotal: lineTotal
        )
    }

    // MARK: 金額

    struct TrailingPrice: Equatable {
        /// 金額より前の部分(品名)
        var name: String
        /// 金額(マイナス記号・▲ があれば負)
        var amount: Int
    }

    private static let priceRegex = try! NSRegularExpression(
        pattern: #"(-|▲|△)?\s*([¥\\])?\s*(\d{1,3}(?:,\d{3})+|\d+)\s*円?\s*(?:\(?[※*軽外内税]\)?)?\s*$"#
    )

    /// 行末の金額を取り出す。時刻(12:34)・日付(10/29)・電話番号(03-1234-5678)のように
    /// 数字の直前が数字や区切り記号のものは金額とみなさない。
    static func trailingPrice(in line: String) -> TrailingPrice? {
        let ns = line as NSString
        guard let match = priceRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let numberRange = match.range(at: 3)
        let signRange = match.range(at: 1)
        let yenRange = match.range(at: 2)
        let hasSign = signRange.location != NSNotFound
        let hasYen = yenRange.location != NSNotFound

        // 金額表記(符号・円記号・数字のうち最初のもの)の直前の文字を確認する。
        // 空白で区切られていれば金額、「1234-5678」「18:42」のように直接続いていれば金額ではない
        let tokenStart = [signRange, yenRange, numberRange]
            .filter { $0.location != NSNotFound }
            .map(\.location)
            .min() ?? numberRange.location
        if tokenStart > 0 {
            let before = ns.substring(with: NSRange(location: tokenStart - 1, length: 1))
            if before.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789:/.-,")) != nil {
                return nil
            }
        }

        let digits = ns.substring(with: numberRange).replacingOccurrences(of: ",", with: "")
        guard digits.count <= 7, let value = Int(digits) else { return nil }

        let name = ns.substring(to: match.range.location).trimmingCharacters(in: .whitespaces)
        // ¥ もカンマもなく、品名に数字が直接くっついた短い数(「麺2」など)は金額とみなさない
        let raw = ns.substring(with: match.range)
        let isSeparated = hasYen || hasSign || raw.hasPrefix(" ") || name.isEmpty
            || digits.count >= 3 || ns.substring(with: numberRange).contains(",")
        guard isSeparated else { return nil }

        return TrailingPrice(name: name, amount: hasSign ? -value : value)
    }

    // MARK: 日付

    private static let dateRegexes: [(NSRegularExpression, YearStyle)] = [
        (try! NSRegularExpression(pattern: #"(20\d{2})\s*[年/.\-]\s*(\d{1,2})\s*[月/.\-]\s*(\d{1,2})"#), .western),
        (try! NSRegularExpression(pattern: #"令和\s*(\d{1,2}|元)\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})"#), .reiwa),
        (try! NSRegularExpression(pattern: #"(?<![\d/])(\d{2})[/.](\d{1,2})[/.](\d{1,2})(?![\d/])"#), .twoDigit),
    ]

    private enum YearStyle { case western, reiwa, twoDigit }

    /// 行に含まれる日付を "yyyy-MM-dd" で返す(西暦4桁・令和・西暦2桁に対応)
    static func dateKey(in line: String) -> String? {
        let ns = line as NSString
        for (regex, style) in dateRegexes {
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
                continue
            }
            let yearText = ns.substring(with: match.range(at: 1))
            guard let month = Int(ns.substring(with: match.range(at: 2))),
                  let day = Int(ns.substring(with: match.range(at: 3))) else { continue }
            let year: Int
            switch style {
            case .western:  year = Int(yearText) ?? 0
            case .reiwa:    year = 2018 + (yearText == "元" ? 1 : (Int(yearText) ?? 0))
            case .twoDigit: year = 2000 + (Int(yearText) ?? 0)
            }
            if let key = validDateKey(year: year, month: month, day: day) { return key }
        }
        return nil
    }

    /// 存在する日付なら "yyyy-MM-dd"、そうでなければ nil
    static func validDateKey(year: Int, month: Int, day: Int) -> String? {
        guard (2000...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day else { return nil }   // 2/30 などを除外
        return String(format: "%04ld-%02ld-%02ld", year, month, day)
    }

    // MARK: 行の種類の判定

    /// 合計金額の行(小計・点数・税額の行は除く)
    static func isTotalLine(_ line: String) -> Bool {
        let keywords = ["合計", "総計", "お買上計", "お買上げ計", "お買い上げ計", "お会計", "ご請求額"]
        guard keywords.contains(where: { line.contains($0) }) else { return false }
        let excludes = ["小計", "対象", "消費税", "税額", "点数", "内税", "外税"]
        return !excludes.contains(where: { line.contains($0) })
    }

    /// 品目の並びが終わる行(小計・合計など)
    private static func isSectionEndLine(_ line: String) -> Bool {
        line.contains("小計") || isTotalLine(line)
    }

    /// 値引き・割引の行
    private static func isDiscountLine(_ line: String) -> Bool {
        ["値引", "割引", "値下", "クーポン"].contains(where: { line.contains($0) })
    }

    private static let quantityRegex = try! NSRegularExpression(
        pattern: #"(\d+\s*(個|コ|点|本|袋|パック|枚|ヶ|ケ|P)\s*[xX×*])|@\s*\d|単\s*\d|[xX×]\s*単"#
    )

    /// 「2コ×単198」のような数量・単価の行
    private static func isQuantityLine(_ line: String) -> Bool {
        quantityRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// 品目ではない行(支払い・税・お店の情報など)
    private static func isNonItemLine(_ line: String) -> Bool {
        let keywords = [
            "合計", "小計", "総計", "税", "対象", "釣", "預", "現金", "クレジット", "カード",
            "ポイント", "支払", "点数", "買上", "領収", "電話", "TEL", "Tel", "tel", "登録番号",
            "レジ", "責", "No.", "NO.", "会員", "お買", "内訳", "電子マネー", "PayPay", "Suica",
            "残高", "〒", "http", "www", "ありがとう", "ご来店", "またお越し", "返品", "交換",
        ]
        return keywords.contains(where: { line.contains($0) })
    }

    /// 文字(数字・記号以外)を含むか
    private static func hasLetters(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    /// 品名として意味がありそうか。OCR の断片や 1 文字の英字・記号だけのような
    /// 「商品名が特定できない」ものを品目に無理やり載せないための判定。
    /// 日本語(かな・漢字)を含む、または 2 文字以上つながった英数字を含めば品名とみなす。
    static func isLikelyItemName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // ひらがな・カタカナ・漢字を1つでも含めば品名とみなす(「卵」「塩」など1文字もOK)
        for scalar in trimmed.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF,   // ひらがな・カタカナ
                 0x3400...0x4DBF,   // 漢字(拡張A)
                 0x4E00...0x9FFF,   // 漢字
                 0xF900...0xFAFF:   // 互換漢字
                return true
            default:
                continue
            }
        }
        // 日本語が無い場合は、英字を含み かつ 英数字が2文字以上あるものだけ品名とみなす。
        // (「197」「2026」「8%」のような数字・記号だけの断片は品名にしない)
        let hasLatinLetter = trimmed.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
        let alphanumericCount = trimmed.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        return hasLatinLetter && alphanumericCount >= 2
    }

    /// 品名の先頭の商品コード・記号、末尾の税区分マークを取り除く
    private static func cleanItemName(_ name: String) -> String {
        var text = name
        // 先頭の商品コード(4桁以上の数字。例: "0123 牛乳")や記号
        text = text.replacingOccurrences(of: #"^(?:\d{4,}|[*※#・])[\s*※#・.\-]*"#, with: "", options: .regularExpression)
        // 末尾の税区分マーク
        text = text.replacingOccurrences(of: #"\s*[\(（]?[※*軽外内][\)）]?\s*$"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// 店名らしい行か(日付・電話・住所・定型文や数字だけの行は除く)
    private static func isStoreNameCandidate(_ line: String) -> Bool {
        guard line.count >= 2, hasLetters(line), dateKey(in: line) == nil,
              trailingPrice(in: line) == nil else { return false }
        let excludes = [
            "領収", "レシート", "TEL", "Tel", "tel", "電話", "〒", "http", "www", "登録番号",
            "ありがとう", "いらっしゃいませ", "ご来店", "毎度", "お買上", "お買い上げ",
        ]
        if excludes.contains(where: { line.contains($0) }) { return false }
        // 数字が半分以上の行(番号・日時など)は除く
        let digitCount = line.filter(\.isNumber).count
        return digitCount * 2 < line.count
    }

    // MARK: AI の結果との統合

    /// ルールベースの結果(rule)と端末内 AI の結果(ai)を統合する。
    /// 日付と合計は書式が決まっていて確実なルールベースを優先し、
    /// 店名と品目は表記ゆれ・レイアウト差に強い AI を優先する(空なら他方で補う)。
    static func merge(rule: Result, ai: Result) -> Result {
        var merged = rule
        if let store = ai.storeName, !store.trimmingCharacters(in: .whitespaces).isEmpty {
            merged.storeName = store
        }
        if merged.dateKey == nil { merged.dateKey = ai.dateKey }
        if merged.total == nil, let total = ai.total, total > 0 { merged.total = total }
        let aiItems = ai.items.filter { isLikelyItemName($0.name) && $0.price > 0 }
        if !aiItems.isEmpty { merged.items = aiItems }
        return merged
    }
}
