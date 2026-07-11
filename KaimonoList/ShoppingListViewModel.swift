import Foundation
import Observation
import SwiftUI
import FirebaseFirestore

@MainActor
@Observable
final class ShoppingListViewModel {

    // MARK: - 状態

    private(set) var items: [ShoppingItem] = []
    private(set) var categories: [ItemCategory] = []   // sortOrder 順で保持
    var errorMessage: String?

    /// 画面表示用: カテゴリごとにまとめた未購入アイテム
    struct CategoryGroup: Identifiable {
        let id: String        // categoryId または "uncategorized"
        let title: String     // "🥬 野菜・果物"
        let items: [ShoppingItem]
    }

    var uncheckedGroups: [CategoryGroup] {
        Self.uncheckedGroups(items: items, categories: categories)
    }

    /// 未購入アイテムをカテゴリ(売り場)順にグループ化する純粋関数。
    /// Firestore に依存しないので、ユニットテストから直接呼べる。
    static func uncheckedGroups(items: [ShoppingItem],
                               categories: [ItemCategory]) -> [CategoryGroup] {
        let unchecked = items.filter { !$0.isChecked }
        guard !unchecked.isEmpty else { return [] }

        var byCategoryId = Dictionary(grouping: unchecked) { $0.categoryId ?? "" }
        var groups: [CategoryGroup] = []

        // categories は sortOrder 順なので、その順に組み立てれば売り場順になる
        for category in categories {
            guard let id = category.id,
                  let members = byCategoryId.removeValue(forKey: id) else { continue }
            groups.append(CategoryGroup(
                id: id,
                title: "\(category.emoji) \(category.name)",
                items: members
            ))
        }

        // カテゴリ未設定、または削除されたカテゴリに属していたアイテム
        let leftovers = byCategoryId.values
            .flatMap { $0 }
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        if !leftovers.isEmpty {
            groups.append(CategoryGroup(id: "uncategorized", title: "❓ 未分類", items: leftovers))
        }
        return groups
    }

    var checkedItems: [ShoppingItem] {
        items.filter(\.isChecked)
    }

    /// 追加シートの初期選択に使うカテゴリ(「その他」→ なければ末尾)
    var defaultCategoryId: String? {
        categories.first(where: { $0.matcherKey == "other" })?.id ?? categories.last?.id
    }

    /// CategoryGuesser が返した matcherKey に対応するカテゴリIDを引く
    func categoryId(forMatcherKey key: String?) -> String? {
        guard let key else { return nil }
        return categories.first(where: { $0.matcherKey == key })?.id
    }

    // MARK: - 依存

    let householdId: String
    let currentUid: String
    let currentUserName: String

    private let db = Firestore.firestore()
    private var itemsListener: ListenerRegistration?
    private var categoriesListener: ListenerRegistration?

    private var householdRef: DocumentReference {
        db.collection("households").document(householdId)
    }
    private var itemsRef: CollectionReference { householdRef.collection("items") }
    private var categoriesRef: CollectionReference { householdRef.collection("categories") }

    init(householdId: String, currentUid: String, currentUserName: String) {
        self.householdId = householdId
        self.currentUid = currentUid
        self.currentUserName = currentUserName
    }

    // MARK: - リアルタイム同期

    /// items と categories の両方を監視。
    /// 共有メンバーによる追加・チェック・カテゴリ編集もすべて即座に反映される。
    /// Firestore のリスナー通知はデフォルトでメインスレッドに届く。
    func startListening() {
        stopListening()

        categoriesListener = categoriesRef
            .order(by: "sortOrder")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    self.errorMessage = error.localizedDescription
                    return
                }
                self.categories = snapshot?.documents.compactMap {
                    try? $0.data(as: ItemCategory.self)
                } ?? []
            }

        itemsListener = itemsRef
            .order(by: "createdAt")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    self.errorMessage = error.localizedDescription
                    return
                }
                self.items = snapshot?.documents.compactMap {
                    try? $0.data(as: ShoppingItem.self)
                } ?? []
            }
    }

    func stopListening() {
        itemsListener?.remove()
        categoriesListener?.remove()
        itemsListener = nil
        categoriesListener = nil
    }

    // MARK: - アイテム操作

    func addItem(name: String, categoryId: String?, quantity: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let trimmedQuantity = quantity.trimmingCharacters(in: .whitespacesAndNewlines)

        let item = ShoppingItem(
            id: nil,
            name: trimmedName,
            categoryId: categoryId,
            quantity: trimmedQuantity.isEmpty ? nil : trimmedQuantity,
            isChecked: false,
            addedByUid: currentUid,
            addedByName: currentUserName,
            createdAt: nil,   // サーバー時刻
            checkedAt: nil
        )
        do {
            _ = try itemsRef.addDocument(from: item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleChecked(_ item: ShoppingItem) {
        guard let id = item.id else { return }
        itemsRef.document(id).updateData([
            "isChecked": !item.isChecked,
            "checkedAt": item.isChecked ? FieldValue.delete() : FieldValue.serverTimestamp(),
        ])
    }

    func delete(_ item: ShoppingItem) {
        guard let id = item.id else { return }
        itemsRef.document(id).delete()
    }

    /// 購入済みをまとめて削除(レジ後のリセット用)。
    /// フェーズ3で「削除前に purchase_history へ記録 → 献立提案の学習データにする」予定
    func clearChecked() {
        let batch = db.batch()
        for item in checkedItems {
            guard let id = item.id else { continue }
            batch.deleteDocument(itemsRef.document(id))
        }
        batch.commit()
    }

    // MARK: - カテゴリ操作

    func addCategory(name: String, emoji: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let nextOrder = (categories.map(\.sortOrder).max() ?? -100) + 100
        categoriesRef.addDocument(data: [
            "name": trimmed,
            "emoji": emoji.isEmpty ? "🛒" : emoji,
            "sortOrder": nextOrder,
            "createdAt": FieldValue.serverTimestamp(),
        ])
    }

    func updateCategory(_ category: ItemCategory, name: String, emoji: String) {
        guard let id = category.id else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        categoriesRef.document(id).updateData([
            "name": trimmed,
            "emoji": emoji.isEmpty ? "🛒" : emoji,
        ])
    }

    /// カテゴリ削除。所属していたアイテムは categoryId を外して「未分類」へ移す
    /// (参照切れのIDを残さないため、削除と付け替えを同一バッチで行う)
    func deleteCategory(_ category: ItemCategory) {
        guard let id = category.id else { return }

        let batch = db.batch()
        batch.deleteDocument(categoriesRef.document(id))
        for item in items where item.categoryId == id {
            guard let itemId = item.id else { continue }
            batch.updateData(
                ["categoryId": FieldValue.delete()],
                forDocument: itemsRef.document(itemId)
            )
        }
        batch.commit()
    }

    /// ドラッグ並び替え。ローカルへ楽観反映してから sortOrder をまとめて書き込む
    func moveCategory(from source: IndexSet, to destination: Int) {
        var reordered = categories
        reordered.move(fromOffsets: source, toOffset: destination)
        categories = reordered   // リスナーの往復を待たずに即時反映

        let batch = db.batch()
        for (index, category) in reordered.enumerated() {
            guard let id = category.id else { continue }
            let newOrder = index * 100
            if category.sortOrder != newOrder {
                batch.updateData(["sortOrder": newOrder], forDocument: categoriesRef.document(id))
            }
        }
        batch.commit()
    }
}
