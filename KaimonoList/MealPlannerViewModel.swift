import Foundation
import Observation
import FirebaseFirestore

/// 献立プランナーの状態管理。
/// レシピ帳(recipes)と日付ごとの献立(mealPlans)を監視し、
/// 「レシピ → 買い物リストへの食材展開」を担当する
@MainActor
@Observable
final class MealPlannerViewModel {

    // MARK: - 状態

    private(set) var recipes: [Recipe] = []              // createdAt 順で保持
    private(set) var planEntries: [MealPlanEntry] = []   // (日付, 追加順) で保持
    private(set) var categories: [ItemCategory] = []     // 食材展開時のカテゴリ推定に使用
    var errorMessage: String?
    /// 「◯件をリストに追加しました」などの操作フィードバック
    var infoMessage: String?

    /// 献立表の表示範囲(今日から7日分)
    var weekDates: [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
    }

    func entries(on date: Date) -> [MealPlanEntry] {
        let key = Self.dateKey(date)
        return planEntries.filter { $0.date == key }
    }

    /// 材料をまだ買い物リストへ展開していない献立の数(まとめて追加ボタンの表示判定)
    var pendingEntryCount: Int {
        planEntries.filter { $0.ingredientsAddedAt == nil }.count
    }

    // MARK: - 依存

    let householdId: String
    let currentUid: String
    let currentUserName: String

    private let db = Firestore.firestore()
    private var recipesListener: ListenerRegistration?
    private var plansListener: ListenerRegistration?
    private var categoriesListener: ListenerRegistration?

    private var householdRef: DocumentReference {
        db.collection("households").document(householdId)
    }
    private var recipesRef: CollectionReference { householdRef.collection("recipes") }
    private var plansRef: CollectionReference { householdRef.collection("mealPlans") }
    private var categoriesRef: CollectionReference { householdRef.collection("categories") }
    private var itemsRef: CollectionReference { householdRef.collection("items") }

    init(householdId: String, currentUid: String, currentUserName: String) {
        self.householdId = householdId
        self.currentUid = currentUid
        self.currentUserName = currentUserName
    }

    // MARK: - 日付キー

    /// MealPlanEntry.date に保存する "yyyy-MM-dd"(端末タイムゾーンの暦日)
    private static let dateKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dateKey(_ date: Date) -> String {
        dateKeyFormatter.string(from: date)
    }

    // MARK: - リアルタイム同期

    func startListening() {
        stopListening()

        recipesListener = recipesRef
            .order(by: "createdAt")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    self.errorMessage = error.localizedDescription
                    return
                }
                self.recipes = snapshot?.documents.compactMap {
                    try? $0.data(as: Recipe.self)
                } ?? []
            }

        // 今日以降の献立のみ監視(過去分はDBに残るが画面には出さない)
        plansListener = plansRef
            .whereField("date", isGreaterThanOrEqualTo: Self.dateKey(Date()))
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    self.errorMessage = error.localizedDescription
                    return
                }
                let decoded = snapshot?.documents.compactMap {
                    try? $0.data(as: MealPlanEntry.self)
                } ?? []
                // date + createdAt の複合ソートはローカルで行う(複合インデックス不要にするため)
                self.planEntries = decoded.sorted {
                    ($0.date, $0.createdAt ?? .distantPast) < ($1.date, $1.createdAt ?? .distantPast)
                }
            }

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
    }

    func stopListening() {
        recipesListener?.remove()
        plansListener?.remove()
        categoriesListener?.remove()
        recipesListener = nil
        plansListener = nil
        categoriesListener = nil
    }

    // MARK: - レシピ操作

    func addRecipe(name: String, emoji: String, ingredients: [RecipeIngredient], memo: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let recipe = Recipe(
            id: nil,
            name: trimmed,
            emoji: emoji.isEmpty ? "🍽️" : emoji,
            ingredients: cleanedIngredients(ingredients),
            memo: cleanedMemo(memo),
            createdAt: nil   // サーバー時刻
        )
        do {
            _ = try recipesRef.addDocument(from: recipe)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateRecipe(_ recipe: Recipe, name: String, emoji: String,
                      ingredients: [RecipeIngredient], memo: String) {
        guard let id = recipe.id else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var updated = recipe
        updated.name = trimmed
        updated.emoji = emoji.isEmpty ? "🍽️" : emoji
        updated.ingredients = cleanedIngredients(ingredients)
        updated.memo = cleanedMemo(memo)
        do {
            try recipesRef.document(id).setData(from: updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// レシピ削除。献立側は recipeName を非正規化して持っているので表示は残る
    /// (ただし材料の展開はできなくなる)
    func deleteRecipe(_ recipe: Recipe) {
        guard let id = recipe.id else { return }
        recipesRef.document(id).delete()
    }

    /// 名前が空の行を除外し、前後の空白を落とす
    private func cleanedIngredients(_ ingredients: [RecipeIngredient]) -> [RecipeIngredient] {
        ingredients.compactMap { ingredient in
            let name = ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let quantity = ingredient.quantity?.trimmingCharacters(in: .whitespacesAndNewlines)
            return RecipeIngredient(
                id: ingredient.id,
                name: name,
                quantity: (quantity?.isEmpty ?? true) ? nil : quantity
            )
        }
    }

    private func cleanedMemo(_ memo: String) -> String? {
        let trimmed = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 献立操作

    func addPlan(recipe: Recipe, on date: Date) {
        guard let recipeId = recipe.id else { return }
        let entry = MealPlanEntry(
            id: nil,
            date: Self.dateKey(date),
            recipeId: recipeId,
            recipeName: recipe.name,
            recipeEmoji: recipe.emoji,
            addedByUid: currentUid,
            createdAt: nil,   // サーバー時刻
            ingredientsAddedAt: nil
        )
        do {
            _ = try plansRef.addDocument(from: entry)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removePlan(_ entry: MealPlanEntry) {
        guard let id = entry.id else { return }
        plansRef.document(id).delete()
    }

    // MARK: - 食材展開(レシピ → 買い物リスト)

    /// 1件の献立の材料を買い物リストへ追加する
    func addIngredients(for entry: MealPlanEntry) async {
        guard let recipe = recipes.first(where: { $0.id == entry.recipeId }) else {
            errorMessage = "レシピが見つかりません(削除された可能性があります)"
            return
        }
        do {
            let addedCount = try await addToShoppingList(recipe.ingredients)
            markIngredientsAdded([entry])
            infoMessage = addedCount == 0
                ? "材料はすべてリストにあります"
                : "\(addedCount)件を買い物リストに追加しました"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 未展開の献立すべての材料をまとめて買い物リストへ追加する
    func addAllPendingIngredients() async {
        let pending = planEntries.filter { $0.ingredientsAddedAt == nil }
        guard !pending.isEmpty else { return }

        var ingredients: [RecipeIngredient] = []
        var resolvedEntries: [MealPlanEntry] = []
        for entry in pending {
            // レシピが削除された献立はスキップ(未展開のまま残す)
            guard let recipe = recipes.first(where: { $0.id == entry.recipeId }) else { continue }
            ingredients += recipe.ingredients
            resolvedEntries.append(entry)
        }
        guard !resolvedEntries.isEmpty else {
            errorMessage = "レシピが見つかりません(削除された可能性があります)"
            return
        }

        do {
            let addedCount = try await addToShoppingList(ingredients)
            markIngredientsAdded(resolvedEntries)
            infoMessage = addedCount == 0
                ? "材料はすべてリストにあります"
                : "\(addedCount)件を買い物リストに追加しました"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 材料を買い物アイテムとして一括追加し、追加した件数を返す。
    /// - 同じ品名が未購入リストに既にある場合はスキップ(数量の合算はしない)
    /// - カテゴリは CategoryGuesser で推定。推定できなければ未分類のまま追加
    private func addToShoppingList(_ ingredients: [RecipeIngredient]) async throws -> Int {
        let snapshot = try await itemsRef
            .whereField("isChecked", isEqualTo: false)
            .getDocuments()
        var existingNames = Set(snapshot.documents.compactMap { $0.data()["name"] as? String })

        let batch = db.batch()
        var addedCount = 0
        for ingredient in ingredients {
            guard !existingNames.contains(ingredient.name) else { continue }
            existingNames.insert(ingredient.name)   // 同一レシピ・レシピ間の重複も防ぐ

            var data: [String: Any] = [
                "name": ingredient.name,
                "isChecked": false,
                "addedByUid": currentUid,
                "addedByName": currentUserName,
                "createdAt": FieldValue.serverTimestamp(),
            ]
            if let categoryId = categoryId(forMatcherKey: CategoryGuesser.guessKey(from: ingredient.name)) {
                data["categoryId"] = categoryId
            }
            if let quantity = ingredient.quantity {
                data["quantity"] = quantity
            }
            batch.setData(data, forDocument: itemsRef.document())
            addedCount += 1
        }
        if addedCount > 0 {
            try await batch.commit()
        }
        return addedCount
    }

    private func markIngredientsAdded(_ entries: [MealPlanEntry]) {
        let batch = db.batch()
        for entry in entries {
            guard let id = entry.id else { continue }
            batch.updateData(
                ["ingredientsAddedAt": FieldValue.serverTimestamp()],
                forDocument: plansRef.document(id)
            )
        }
        batch.commit()
    }

    private func categoryId(forMatcherKey key: String?) -> String? {
        guard let key else { return nil }
        return categories.first(where: { $0.matcherKey == key })?.id
    }
}
