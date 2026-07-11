import Foundation
import Testing
@testable import KaimonoList

/// 買い物リストの「未購入アイテムをカテゴリ(売り場)順にまとめる」ロジックの検証。
/// ShoppingListViewModel.uncheckedGroups(items:categories:) の純粋関数版を対象にする。
@MainActor
struct ShoppingListGroupingTests {

    // MARK: - テスト用ファクトリ

    private func category(_ id: String, _ name: String, _ emoji: String,
                          sortOrder: Int, matcherKey: String? = nil) -> ItemCategory {
        ItemCategory(id: id, name: name, emoji: emoji,
                     sortOrder: sortOrder, matcherKey: matcherKey, createdAt: nil)
    }

    private func item(_ id: String, _ name: String, categoryId: String?,
                      isChecked: Bool = false, createdAt: Date? = nil) -> ShoppingItem {
        ShoppingItem(id: id, name: name, categoryId: categoryId, quantity: nil,
                     isChecked: isChecked, addedByUid: "u1", addedByName: "テスト",
                     createdAt: createdAt, checkedAt: nil)
    }

    private var sampleCategories: [ItemCategory] {
        [
            category("produce", "野菜・果物", "🥬", sortOrder: 0),
            category("meat", "肉", "🥩", sortOrder: 100),
            category("dairy", "乳製品", "🥚", sortOrder: 200),
        ]
    }

    // MARK: - 基本ケース

    @Test("アイテムが無ければ空")
    func emptyItemsYieldsNoGroups() {
        let groups = ShoppingListViewModel.uncheckedGroups(items: [], categories: sampleCategories)
        #expect(groups.isEmpty)
    }

    @Test("すべて購入済みなら空(未購入だけが対象)")
    func allCheckedYieldsNoGroups() {
        let items = [
            item("1", "にんじん", categoryId: "produce", isChecked: true),
            item("2", "豚肉", categoryId: "meat", isChecked: true),
        ]
        let groups = ShoppingListViewModel.uncheckedGroups(items: items, categories: sampleCategories)
        #expect(groups.isEmpty)
    }

    @Test("購入済みアイテムはグループから除外される")
    func checkedItemsAreExcluded() {
        let items = [
            item("1", "にんじん", categoryId: "produce", isChecked: false),
            item("2", "玉ねぎ", categoryId: "produce", isChecked: true),
        ]
        let groups = ShoppingListViewModel.uncheckedGroups(items: items, categories: sampleCategories)
        #expect(groups.count == 1)
        #expect(groups[0].items.map(\.name) == ["にんじん"])
    }

    // MARK: - 並び順とタイトル

    @Test("グループは categories の sortOrder 順に並ぶ")
    func groupsFollowCategorySortOrder() {
        // 入力の並びは categories と逆でも、出力は sortOrder 順(produce→meat→dairy)になる
        let items = [
            item("1", "牛乳", categoryId: "dairy"),
            item("2", "豚肉", categoryId: "meat"),
            item("3", "にんじん", categoryId: "produce"),
        ]
        let groups = ShoppingListViewModel.uncheckedGroups(items: items, categories: sampleCategories)
        #expect(groups.map(\.id) == ["produce", "meat", "dairy"])
    }

    @Test("グループタイトルは「絵文字 名前」形式")
    func groupTitleFormat() {
        let items = [item("1", "にんじん", categoryId: "produce")]
        let groups = ShoppingListViewModel.uncheckedGroups(items: items, categories: sampleCategories)
        #expect(groups.first?.title == "🥬 野菜・果物")
    }

    @Test("アイテムの無いカテゴリはグループに現れない")
    func emptyCategoriesAreOmitted() {
        let items = [item("1", "豚肉", categoryId: "meat")]
        let groups = ShoppingListViewModel.uncheckedGroups(items: items, categories: sampleCategories)
        #expect(groups.map(\.id) == ["meat"])
    }

    // MARK: - 未分類(uncategorized)

    @Test("categoryId が nil のアイテムは末尾の「未分類」にまとまる")
    func nilCategoryGoesToUncategorized() {
        let items = [
            item("1", "にんじん", categoryId: "produce"),
            item("2", "何か", categoryId: nil),
        ]
        let groups = ShoppingListViewModel.uncheckedGroups(items: items, categories: sampleCategories)
        #expect(groups.count == 2)
        #expect(groups.last?.id == "uncategorized")
        #expect(groups.last?.title == "❓ 未分類")
        #expect(groups.last?.items.map(\.name) == ["何か"])
    }

    @Test("削除済みカテゴリ(参照切れID)のアイテムも未分類に入る")
    func danglingCategoryGoesToUncategorized() {
        let items = [item("1", "謎", categoryId: "deleted-category-id")]
        let groups = ShoppingListViewModel.uncheckedGroups(items: items, categories: sampleCategories)
        #expect(groups.count == 1)
        #expect(groups[0].id == "uncategorized")
    }

    @Test("未分類内のアイテムは createdAt の昇順(追加順)で並ぶ")
    func uncategorizedSortedByCreatedAt() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let items = [
            item("late", "あとで", categoryId: nil, createdAt: base.addingTimeInterval(100)),
            item("early", "さきに", categoryId: nil, createdAt: base),
        ]
        let groups = ShoppingListViewModel.uncheckedGroups(items: items, categories: sampleCategories)
        #expect(groups.count == 1)
        #expect(groups[0].items.map(\.name) == ["さきに", "あとで"])
    }
}
