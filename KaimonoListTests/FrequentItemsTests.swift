import Testing
import Foundation
@testable import KaimonoList

/// FrequentItems の「購入履歴からよく買う品を頻度順に集計する」処理の検証。
/// 表記ゆれのまとめ、除外、代表カテゴリ・表記の選び方、並び順・上限を確認する。
@MainActor
struct FrequentItemsTests {

    // MARK: - テスト用の生成ヘルパー

    /// purchasedAt は基準日からの相対秒で並び順を制御する(大きいほど新しい)。
    private func record(_ name: String, categoryId: String? = nil, at offset: TimeInterval = 0) -> PurchaseRecord {
        PurchaseRecord(
            id: nil,
            name: name,
            categoryId: categoryId,
            purchasedByUid: "u1",
            purchasedAt: Date(timeIntervalSince1970: offset)
        )
    }

    // MARK: - 集計・並び順

    @Test("購入回数の多い順に並ぶ")
    func ranksByCount() {
        let history = [
            record("牛乳"), record("牛乳"), record("牛乳"),
            record("卵"), record("卵"),
            record("パン"),
        ]

        let result = FrequentItems.topItems(from: history, limit: 10)

        #expect(result.map(\.name) == ["牛乳", "卵", "パン"])
        #expect(result.first?.count == 3)
    }

    @Test("表記ゆれ(前後空白・大小文字)は1件にまとめる")
    func mergesNormalizedNames() {
        let history = [record("Milk"), record("  milk "), record("MILK")]

        let result = FrequentItems.topItems(from: history, limit: 10)

        #expect(result.count == 1)
        #expect(result.first?.count == 3)
    }

    @Test("同数のときは最近購入した順に並ぶ")
    func tieBreaksByRecency() {
        let history = [
            record("卵", at: 100),
            record("牛乳", at: 200),   // 牛乳のほうが新しい
        ]

        let result = FrequentItems.topItems(from: history, limit: 10)

        #expect(result.map(\.name) == ["牛乳", "卵"])
    }

    // MARK: - 代表の表記・カテゴリ

    @Test("代表の表記とカテゴリは最も最近の購入を採用する")
    func usesLatestNameAndCategory() {
        let history = [
            record("牛乳", categoryId: "old", at: 100),
            record("牛乳", categoryId: "dairy", at: 300),   // 最新
            record("牛乳", categoryId: "mid", at: 200),
        ]

        let result = FrequentItems.topItems(from: history, limit: 10)

        #expect(result.first?.name == "牛乳")
        #expect(result.first?.categoryId == "dairy")
        #expect(result.first?.count == 3)
    }

    // MARK: - 除外・上限・空入力

    @Test("除外指定した品名は候補に含めない(正規化して比較)")
    func excludesGivenNames() {
        let history = [record("Milk"), record("Milk"), record("卵")]

        // " MILK " は正規化すると "milk" になり、履歴の "Milk" と一致して除外される
        let result = FrequentItems.topItems(from: history, excludingNames: [" MILK "], limit: 10)

        #expect(result.map(\.name) == ["卵"])
    }

    @Test("空の品名は無視する")
    func ignoresBlankNames() {
        let history = [record("   "), record("卵")]

        let result = FrequentItems.topItems(from: history, limit: 10)

        #expect(result.map(\.name) == ["卵"])
    }

    @Test("limit を超えて返さない")
    func respectsLimit() {
        let history = (1...10).map { record("品\($0)") }

        let result = FrequentItems.topItems(from: history, limit: 3)

        #expect(result.count == 3)
    }

    @Test("履歴が空・limit が0以下なら空を返す")
    func returnsEmptyForNoInput() {
        #expect(FrequentItems.topItems(from: [], limit: 10).isEmpty)
        #expect(FrequentItems.topItems(from: [record("牛乳")], limit: 0).isEmpty)
    }
}
