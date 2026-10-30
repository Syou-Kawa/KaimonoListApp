import Testing
import Foundation
import CoreGraphics
@testable import KaimonoList

/// レシートの読み取り結果(OCR の行)から店名・日付・合計・品目を取り出す処理の検証。
@MainActor
struct ReceiptParserTests {

    // MARK: - 全体の解析

    @Test("スーパーのレシート: 店名・日付・合計・品目(数量行・値引き・半角カナ)を取り出す")
    func parsesSupermarketReceipt() {
        let lines = [
            "スーパーマルエツ 新宿店",
            "東京都新宿区西新宿1-2-3",
            "TEL 03-1234-5678",
            "2026年10月29日(木) 18:42",
            "レジ0003 責No.123",
            "ｷﾞｭｳﾆｭｳ ¥198",
            "食パン 6枚 158※",
            "たまご 10個 ¥238",
            "豚こま切れ",
            "2コX単298 ¥596",
            "値引 -100",
            "バナナ 198",
            "小計 ¥1,288",
            "(8%対象 ¥1,288)",
            "合計 ¥1,391",
            "お預り ¥2,000",
            "お釣り ¥609",
        ]

        let result = ReceiptParser.parse(lines: lines)

        #expect(result.storeName == "スーパーマルエツ 新宿店")
        #expect(result.dateKey == "2026-10-29")
        #expect(result.total == 1391)
        #expect(result.items == [
            .init(name: "ギュウニュウ", price: 198),
            .init(name: "食パン 6枚", price: 158),      // 「6枚」は入数(×印が無いので個数ではない)
            .init(name: "たまご 10個", price: 238),     // 同上
            .init(name: "豚こま切れ", price: 496, quantity: 2),   // 2コX単298=596 - 値引100
            .init(name: "バナナ", price: 198),
        ])
    }

    @Test("同じ商品を複数買った数量行から個数と小計を読み取る(実際のレシート形式)")
    func parsesQuantityLines() {
        let lines = [
            "まるかつ 八千代店",
            "2026年9月14日(月) 18:54",
            "からあげ弁当",
            "2点 x @214 ¥428",          // 個数が前の行、行末に小計
            "ヨーグルト 3コX198 594",    // 品名・個数・単価・小計が1行
            "お茶",
            "2本 x @108",               // 行末に小計が無い → 単価×個数
            "合計 ¥1,238",
        ]

        let result = ReceiptParser.parse(lines: lines)

        #expect(result.items == [
            .init(name: "からあげ弁当", price: 428, quantity: 2),
            .init(name: "ヨーグルト", price: 594, quantity: 3),
            .init(name: "お茶", price: 216, quantity: 2),
        ])
    }

    @Test("数量・単価の行を個数・単価・小計に分解する")
    func parsesQuantityLineParts() {
        // 行末の小計がある場合はそれを小計、@/単 の金額は単価として扱う
        #expect(ReceiptParser.parseQuantityLine("2点 x @214 ¥428")
            == .init(namePrefix: "", quantity: 2, unitPrice: 214, lineTotal: 428))
        // 行末に小計が無ければ単価×個数で小計を求める
        let onlyUnit = ReceiptParser.parseQuantityLine("2本 x @108")
        #expect(onlyUnit?.resolvedTotal == 216)
        #expect(onlyUnit?.resolvedQuantity == 2)
        // 「6枚」のように × 印を伴わない入数表記は数量行ではない
        #expect(ReceiptParser.parseQuantityLine("食パン 6枚 158") == nil)
    }

    @Test("品名と金額が別の行に分かれていても1品にまとめ、合計は次の行から読む")
    func parsesSplitRows() {
        let lines = [
            "ローソン",
            "26/10/30 01:15",
            "おにぎり 鮭",
            "¥160",
            "お茶 500ml ¥108軽",
            "合計",
            "¥268",
        ]

        let result = ReceiptParser.parse(lines: lines)

        #expect(result.storeName == "ローソン")
        #expect(result.dateKey == "2026-10-30")
        #expect(result.total == 268)
        #expect(result.items == [
            .init(name: "おにぎり 鮭", price: 160),
            .init(name: "お茶 500ml", price: 108),
        ])
    }

    @Test("先頭の商品コードや記号は品名から取り除く")
    func stripsItemCodes() {
        let lines = [
            "イオン",
            "令和8年10月29日",
            "4901234567890 牛乳 ¥215",
            "*ﾖｰｸﾞﾙﾄ ¥128",
            "合計 3点 ¥343",
        ]

        let result = ReceiptParser.parse(lines: lines)

        #expect(result.dateKey == "2026-10-29")
        #expect(result.total == 343)
        #expect(result.items.map(\.name) == ["牛乳", "ヨーグルト"])
    }

    @Test("何も読み取れない行だけなら空の結果")
    func emptyResult() {
        let result = ReceiptParser.parse(lines: ["", "  "])
        #expect(result == ReceiptParser.Result())
    }

    @Test("品名が特定できない断片(1文字の英字・数字だけ)は品目に載せない")
    func dropsUnidentifiableItems() {
        let lines = [
            "スーパー",
            "2026年10月29日",
            "牛乳 ¥198",
            "W 197",            // OCR ノイズ(1文字) → 載せない
            "卵 ¥238",          // 漢字1文字でも品名として残す
            "合計 ¥436",
        ]

        let result = ReceiptParser.parse(lines: lines)

        #expect(result.items == [
            .init(name: "牛乳", price: 198),
            .init(name: "卵", price: 238),
        ])
    }

    @Test("品名として妥当か判定する(数字や記号だけ・1文字英字は不可)")
    func judgesLikelyItemName() {
        #expect(ReceiptParser.isLikelyItemName("牛乳"))
        #expect(ReceiptParser.isLikelyItemName("卵"))       // 漢字1文字はOK
        #expect(ReceiptParser.isLikelyItemName("C1000"))    // 英字を含む商品名
        #expect(!ReceiptParser.isLikelyItemName("W"))       // 1文字の英字
        #expect(!ReceiptParser.isLikelyItemName("197"))     // 数字だけ
        #expect(!ReceiptParser.isLikelyItemName("8%"))      // 数字+記号
        #expect(!ReceiptParser.isLikelyItemName(""))
    }

    // MARK: - 金額

    @Test("行末の金額を読む(円記号・カンマ・税区分マーク)")
    func readsTrailingPrice() {
        #expect(ReceiptParser.trailingPrice(in: "牛乳 1,980")?.amount == 1980)
        #expect(ReceiptParser.trailingPrice(in: "ポテト ¥98外")?.amount == 98)
        #expect(ReceiptParser.trailingPrice(in: "値引 -50")?.amount == -50)
        #expect(ReceiptParser.trailingPrice(in: "¥160") == .init(name: "", amount: 160))
    }

    @Test("時刻・日付・電話番号・品名にくっついた数字は金額とみなさない")
    func ignoresNonPrices() {
        #expect(ReceiptParser.trailingPrice(in: "18:42") == nil)
        #expect(ReceiptParser.trailingPrice(in: "03-1234-5678") == nil)
        #expect(ReceiptParser.trailingPrice(in: "2026/10/29") == nil)
        #expect(ReceiptParser.trailingPrice(in: "カップ麺2") == nil)
    }

    // MARK: - 日付

    @Test("西暦・令和・2桁年の日付を読む")
    func readsDates() {
        #expect(ReceiptParser.dateKey(in: "2026年10月29日 18:42") == "2026-10-29")
        #expect(ReceiptParser.dateKey(in: "2026/1/5(月)") == "2026-01-05")
        #expect(ReceiptParser.dateKey(in: "令和元年5月1日") == "2019-05-01")
        #expect(ReceiptParser.dateKey(in: "26.10.30") == "2026-10-30")
    }

    @Test("存在しない日付は読まない")
    func rejectsInvalidDates() {
        #expect(ReceiptParser.dateKey(in: "2026/02/30") == nil)
        #expect(ReceiptParser.dateKey(in: "2026/13/01") == nil)
    }

    // MARK: - 正規化

    @Test("半角カナは全角に、全角英数は半角にそろえる")
    func normalizesWidth() {
        #expect(ReceiptParser.normalize("ｷﾞｭｳﾆｭｳ　￥１９８") == "ギュウニュウ ¥198")
    }

    // MARK: - 合計行

    @Test("小計・税額・点数の行は合計とみなさない")
    func detectsTotalLine() {
        #expect(ReceiptParser.isTotalLine("合計 ¥1,391"))
        #expect(ReceiptParser.isTotalLine("お買上計 ¥500"))
        #expect(!ReceiptParser.isTotalLine("小計 ¥1,288"))
        #expect(!ReceiptParser.isTotalLine("内消費税合計 ¥103"))
        #expect(!ReceiptParser.isTotalLine("合計点数 5点"))
    }

    // MARK: - 行のまとめ

    @Test("縦位置が近い断片は同じ行として左から連結する")
    func groupsFragmentsIntoRows() {
        let fragments = [
            ReceiptRowGrouper.Fragment(text: "¥198", box: CGRect(x: 0.7, y: 0.802, width: 0.2, height: 0.02)),
            ReceiptRowGrouper.Fragment(text: "牛乳", box: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.02)),
            ReceiptRowGrouper.Fragment(text: "卵", box: CGRect(x: 0.1, y: 0.75, width: 0.1, height: 0.02)),
            ReceiptRowGrouper.Fragment(text: "¥238", box: CGRect(x: 0.7, y: 0.749, width: 0.2, height: 0.02)),
            ReceiptRowGrouper.Fragment(text: "スーパー", box: CGRect(x: 0.3, y: 0.9, width: 0.4, height: 0.03)),
        ]

        #expect(ReceiptRowGrouper.rows(from: fragments) == ["スーパー", "牛乳 ¥198", "卵 ¥238"])
    }

    // MARK: - AI の結果との統合

    @Test("日付・合計はルールを優先し、店名・品目は AI を優先する")
    func mergesWithAIResult() {
        let rule = ReceiptParser.Result(
            storeName: "ﾏﾙｴﾂ", dateKey: "2026-10-29", total: 500,
            items: [.init(name: "ｷﾞｭｳﾆｭｳ", price: 198)]
        )
        let ai = ReceiptParser.Result(
            storeName: "マルエツ", dateKey: "2026-10-01", total: 999,
            items: [.init(name: "牛乳", price: 198), .init(name: "", price: 10)]
        )

        let merged = ReceiptParser.merge(rule: rule, ai: ai)

        #expect(merged.storeName == "マルエツ")
        #expect(merged.dateKey == "2026-10-29")
        #expect(merged.total == 500)
        #expect(merged.items == [.init(name: "牛乳", price: 198)])
    }

    @Test("ルールで読めなかった項目は AI の結果で補う")
    func fillsMissingFromAI() {
        let ai = ReceiptParser.Result(storeName: nil, dateKey: "2026-10-01", total: 999, items: [])
        let merged = ReceiptParser.merge(rule: ReceiptParser.Result(), ai: ai)
        #expect(merged.dateKey == "2026-10-01")
        #expect(merged.total == 999)
    }

    @Test("AI の出力はコードブロックや前置きがあっても JSON 部分を読む")
    func decodesAIOutput() {
        let text = """
        はい、読み取りました。
        ```json
        {"storeName": "ローソン", "date": "2026-10-30", "total": 268,
         "items": [{"name": "おにぎり 鮭", "price": 160}, {"name": "お茶", "price": 108}, {"name": "", "price": 5}]}
        ```
        """

        let result = ReceiptAIExtractor.decode(text)

        #expect(result?.storeName == "ローソン")
        #expect(result?.dateKey == "2026-10-30")
        #expect(result?.total == 268)
        #expect(result?.items.map(\.name) == ["おにぎり 鮭", "お茶"])
    }

    @Test("AI の出力が JSON でなければ nil")
    func rejectsBrokenAIOutput() {
        #expect(ReceiptAIExtractor.decode("読み取れませんでした") == nil)
    }

    @Test("AI の出力から個数(quantity)を読み取る。省略時は1")
    func decodesAIQuantity() {
        let text = #"{"storeName":"店","total":644,"items":[{"name":"卵","price":428,"quantity":2},{"name":"パン","price":216}]}"#
        let result = ReceiptAIExtractor.decode(text)
        #expect(result?.items == [
            .init(name: "卵", price: 428, quantity: 2),
            .init(name: "パン", price: 216, quantity: 1),
        ])
    }
}

/// 家計簿のカテゴリ別集計・金額表示の検証。
@MainActor
struct ReceiptSummaryTests {

    private func receipt(_ items: [ReceiptItem]) -> Receipt {
        Receipt(
            id: nil, storeName: "店", date: "2026-10-29",
            total: items.reduce(0) { $0 + $1.price }, items: items,
            memo: nil, addedByUid: "u1", addedByName: "A",
            purchaseHistoryIds: nil, createdAt: nil
        )
    }

    private let categories = [
        ItemCategory(id: "produce", name: "野菜・果物", emoji: "🥬", sortOrder: 0, matcherKey: "produce", createdAt: nil),
        ItemCategory(id: "dairy", name: "乳製品・卵", emoji: "🥚", sortOrder: 100, matcherKey: "dairyEgg", createdAt: nil),
    ]

    @Test("カテゴリごとに合計し、金額の大きい順。不明なカテゴリは未分類にまとめる")
    func totalsByCategory() {
        let receipts = [
            receipt([
                ReceiptItem(name: "牛乳", price: 198, categoryId: "dairy"),
                ReceiptItem(name: "バナナ", price: 98, categoryId: "produce"),
            ]),
            receipt([
                ReceiptItem(name: "卵", price: 238, categoryId: "dairy"),
                ReceiptItem(name: "謎", price: 50, categoryId: "deleted"),
                ReceiptItem(name: "不明", price: 30, categoryId: nil),
            ]),
        ]

        let totals = ReceiptSummary.categoryTotals(receipts: receipts, categories: categories)

        #expect(totals.map(\.id) == ["dairy", "produce", "uncategorized"])
        #expect(totals.map(\.amount) == [436, 98, 80])
        #expect(totals.first?.title == "🥚 乳製品・卵")
    }

    @Test("金額は端末の言語設定によらず ¥ とカンマで表示する")
    func formatsYen() {
        #expect(Yen.format(1234) == "¥1,234")
        #expect(Yen.format(0) == "¥0")
        #expect(Yen.format(-500) == "-¥500")
    }
}
