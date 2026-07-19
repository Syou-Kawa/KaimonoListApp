import Foundation
import Observation
import SwiftUI
import FirebaseFirestore
import WidgetKit

@MainActor
@Observable
final class ShoppingListViewModel {

    // MARK: - 状態

    private(set) var items: [ShoppingItem] = []
    private(set) var categories: [ItemCategory] = []   // sortOrder 順で保持
    private(set) var recipes: [Recipe] = []            // 編集シートでアイテムに紐づける料理の選択肢
    private(set) var purchaseHistory: [PurchaseRecord] = []   // 「よく買うもの」候補の集計元
    var errorMessage: String?

    /// 一括削除の直後に表示する「元に戻す」トースト。nil = 非表示。
    /// 一定時間後に自動で消えるまで、undo() で削除を取り消せる。
    var undoToast: UndoToast?

    /// 「元に戻す」用に保持する、直前の一括削除の内容。
    struct UndoToast: Identifiable {
        let id = UUID()
        let message: String
        /// 復元するアイテム(ドキュメントIDごとそのまま書き戻す)
        let removedItems: [ShoppingItem]
        /// clearChecked で追加した購入履歴のドキュメントID(取り消し時に消す)
        let addedHistoryIds: [String]
    }

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

    /// 購入済みアイテム。チェックした時刻(checkedAt)の新しい順に並べ、
    /// 「今チェックしたもの」が上に来るようにする。checkedAt 未設定(旧データ)は末尾へ。
    var checkedItems: [ShoppingItem] {
        items.filter(\.isChecked)
            .sorted { ($0.checkedAt ?? .distantPast) > ($1.checkedAt ?? .distantPast) }
    }

    /// 同名(前後空白を無視)の未購入アイテムがすでにリストにあるか。
    /// 追加シートでの重複警告に使う。
    func hasUncheckedItem(named name: String) -> Bool {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        return items.contains {
            !$0.isChecked &&
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(target) == .orderedSame
        }
    }

    /// 追加シートのワンタップ候補。購入回数が多い順に並ぶ。
    /// すでに未購入リストにある品は重複防止のため除外する(追加すると自然に候補から消える)。
    var frequentItems: [FrequentItems.Item] {
        let excluded = Set(items.filter { !$0.isChecked }.map(\.name))
        return FrequentItems.topItems(from: purchaseHistory, excludingNames: excluded, limit: 12)
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

    // MARK: - ウィジェット連携

    /// 現在の未購入リストを App Group 共有領域へ書き出し、ホーム画面ウィジェットを更新する。
    /// items / categories が変わるたびに呼ぶ(ウィジェットは Firebase に触れないため、
    /// アプリが受け取った最新の内容をここでスナップショットとして渡す)。
    private func publishWidgetSnapshot() {
        let groups = Self.uncheckedGroups(items: items, categories: categories)
        var sharedItems: [SharedShoppingSnapshot.Item] = []
        for group in groups {
            // group.title は "🥬 野菜・果物" 形式。先頭の1文字(絵文字)だけ取り出す
            let emoji = group.title.first.map(String.init) ?? "🛒"
            for item in group.items {
                sharedItems.append(SharedShoppingSnapshot.Item(
                    id: item.id ?? UUID().uuidString,
                    name: item.name,
                    quantity: item.quantity,
                    categoryEmoji: emoji
                ))
            }
        }
        let snapshot = SharedShoppingSnapshot(
            uncheckedItems: sharedItems,
            uncheckedCount: sharedItems.count,
            updatedAt: Date()
        )
        SharedShoppingStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - 依存

    let householdId: String
    let currentUid: String
    let currentUserName: String

    private let db = Firestore.firestore()
    private var itemsListener: ListenerRegistration?
    private var categoriesListener: ListenerRegistration?
    private var recipesListener: ListenerRegistration?
    private var purchaseHistoryListener: ListenerRegistration?

    private var householdRef: DocumentReference {
        db.collection("households").document(householdId)
    }
    private var itemsRef: CollectionReference { householdRef.collection("items") }
    private var categoriesRef: CollectionReference { householdRef.collection("categories") }
    private var recipesRef: CollectionReference { householdRef.collection("recipes") }
    private var purchaseHistoryRef: CollectionReference { householdRef.collection("purchaseHistory") }

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
                    // 退出・世帯切り替え時の権限エラーは自然に起きるので警告しない
                    if error.isFirestorePermissionDenied { return }
                    self.errorMessage = error.localizedDescription
                    return
                }
                self.categories = snapshot?.documents.compactMap {
                    try? $0.data(as: ItemCategory.self)
                } ?? []
                // カテゴリの絵文字・並び順もウィジェット表示に反映する
                self.publishWidgetSnapshot()
            }

        itemsListener = itemsRef
            .order(by: "createdAt")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    // 退出・世帯切り替え時の権限エラーは自然に起きるので警告しない
                    if error.isFirestorePermissionDenied { return }
                    self.errorMessage = error.localizedDescription
                    return
                }
                self.items = snapshot?.documents.compactMap {
                    try? $0.data(as: ShoppingItem.self)
                } ?? []
                // 未購入リストが変わったのでウィジェットを更新する
                self.publishWidgetSnapshot()
            }

        recipesListener = recipesRef
            .order(by: "createdAt")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    // 退出・世帯切り替え時の権限エラーは自然に起きるので警告しない
                    if error.isFirestorePermissionDenied { return }
                    self.errorMessage = error.localizedDescription
                    return
                }
                self.recipes = snapshot?.documents.compactMap {
                    try? $0.data(as: Recipe.self)
                } ?? []
            }

        // 「よく買うもの」候補のために、最近の購入履歴を新しい順で購読する。
        // 全件は不要なので上限を設けて読み取りコストを抑える。
        purchaseHistoryListener = purchaseHistoryRef
            .order(by: "purchasedAt", descending: true)
            .limit(to: 300)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    // 退出・世帯切り替え時の権限エラーは自然に起きるので警告しない
                    if error.isFirestorePermissionDenied { return }
                    self.errorMessage = error.localizedDescription
                    return
                }
                self.purchaseHistory = snapshot?.documents.compactMap {
                    try? $0.data(as: PurchaseRecord.self)
                } ?? []
            }
    }

    func stopListening() {
        itemsListener?.remove()
        categoriesListener?.remove()
        recipesListener?.remove()
        purchaseHistoryListener?.remove()
        itemsListener = nil
        categoriesListener = nil
        recipesListener = nil
        purchaseHistoryListener = nil
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

    /// 「よく買うもの」チップからワンタップで追加する。
    /// 履歴のカテゴリが削除済みなら、品名からカテゴリを推定し直す。
    func addFromFrequent(_ item: FrequentItems.Item) {
        let resolvedCategoryId: String?
        if let id = item.categoryId, categories.contains(where: { $0.id == id }) {
            resolvedCategoryId = id
        } else {
            resolvedCategoryId = categoryId(forMatcherKey: CategoryGuesser.guessKey(from: item.name))
                ?? defaultCategoryId
        }
        addItem(name: item.name, categoryId: resolvedCategoryId, quantity: "")
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

    /// 既存アイテムの品名・数量・カテゴリ・紐づく料理をまとめて更新する。
    /// 数量が空、カテゴリが nil、レシピ未選択のときは該当フィールドを削除して
    /// 「未設定/未分類/料理なし」に戻す。
    func updateItem(_ item: ShoppingItem,
                    name: String,
                    quantity: String,
                    categoryId: String?,
                    recipe: Recipe?) {
        guard let id = item.id else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let trimmedQuantity = quantity.trimmingCharacters(in: .whitespacesAndNewlines)

        var data: [String: Any] = ["name": trimmedName]
        data["quantity"] = trimmedQuantity.isEmpty ? FieldValue.delete() : trimmedQuantity
        data["categoryId"] = categoryId ?? FieldValue.delete()
        // 料理を選んだらその名前・絵文字を非正規化して持たせ、「なし」なら関連を外す
        data["sourceRecipeName"] = recipe?.name ?? FieldValue.delete()
        data["sourceRecipeEmoji"] = recipe.map { $0.emoji } ?? FieldValue.delete()
        itemsRef.document(id).updateData(data)
    }

    /// 未購入をまとめて削除(買わないと決めたものの一括クリア用)。
    /// 購入していないので purchaseHistory には記録しない。購入済みは残す。
    /// 直後に「元に戻す」で復元できるよう、削除内容をトーストに保持する。
    func clearUnchecked() {
        let removed = items.filter { !$0.isChecked }
        guard !removed.isEmpty else { return }

        let batch = db.batch()
        for item in removed {
            guard let id = item.id else { continue }
            batch.deleteDocument(itemsRef.document(id))
        }
        batch.commit()

        undoToast = UndoToast(
            message: "\(removed.count)件を削除しました",
            removedItems: removed,
            addedHistoryIds: []
        )
    }

    /// 購入済みをまとめて削除(レジ後のリセット用)。
    /// 削除の前に purchaseHistory へ記録し、献立提案(MealSuggester)の学習データにする。
    /// 直後に「元に戻す」で、アイテムの復元と購入履歴の取り消しの両方を行えるようにする。
    func clearChecked() {
        let removed = checkedItems
        guard !removed.isEmpty else { return }

        let batch = db.batch()
        var historyIds: [String] = []
        for item in removed {
            guard let id = item.id else { continue }
            // 購入履歴に記録(好みの学習データ)。categoryId は存在するときのみ持たせる
            var record: [String: Any] = [
                "name": item.name,
                "purchasedByUid": currentUid,
                "purchasedAt": FieldValue.serverTimestamp(),
            ]
            if let categoryId = item.categoryId {
                record["categoryId"] = categoryId
            }
            let historyDoc = purchaseHistoryRef.document()
            historyIds.append(historyDoc.documentID)
            batch.setData(record, forDocument: historyDoc)
            batch.deleteDocument(itemsRef.document(id))
        }
        batch.commit()

        undoToast = UndoToast(
            message: "\(removed.count)件を削除しました",
            removedItems: removed,
            addedHistoryIds: historyIds
        )
    }

    /// 直前の一括削除を取り消す。削除したアイテムを元のドキュメントIDのまま書き戻し、
    /// (購入済み削除の場合は)追加した購入履歴も消す。
    func undoLastClear() {
        guard let toast = undoToast else { return }
        undoToast = nil

        let batch = db.batch()
        for item in toast.removedItems {
            guard let id = item.id else { continue }
            // ドキュメントIDごと書き戻すので createdAt / checkedAt も含めて元通りになる
            try? batch.setData(from: item, forDocument: itemsRef.document(id))
        }
        for historyId in toast.addedHistoryIds {
            batch.deleteDocument(purchaseHistoryRef.document(historyId))
        }
        batch.commit()
    }

    /// トーストを閉じる(自動消滅・手動クローズ用)。復元はしない。
    func dismissUndoToast() {
        undoToast = nil
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
