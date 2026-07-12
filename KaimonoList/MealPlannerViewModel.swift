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

    /// 購入履歴(好み)から算出した献立の提案。レシピ選択シートを開くたびに再生成する
    private(set) var suggestions: [MealSuggester.Suggestion] = []
    private(set) var isGeneratingSuggestions = false

    /// 献立表の表示範囲(今日から7日分)
    var weekDates: [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
    }

    func entries(on date: Date) -> [MealPlanEntry] {
        let key = Self.dateKey(date)
        return planEntries.filter { $0.date == key }
    }

    /// 献立エントリに対応するレシピ。削除済みなら nil(材料確認画面で使用)
    func recipe(for entry: MealPlanEntry) -> Recipe? {
        recipes.first { $0.id == entry.recipeId }
    }

    /// 材料をまだ買い物リストへ展開していない献立の数(まとめて追加ボタンの表示判定)
    var pendingEntryCount: Int {
        planEntries.filter { $0.ingredientsAddedAt == nil }.count
    }

    /// 表示中(今日以降)の献立が1件でもあるか(まとめて削除ボタンの活性判定)
    var hasPlanEntries: Bool {
        !planEntries.isEmpty
    }

    /// 材料をすでに買い物リストへ展開した献立があるか(まとめて削除の選択肢切り替えに使用)
    var hasAddedIngredients: Bool {
        planEntries.contains { $0.ingredientsAddedAt != nil }
    }

    // MARK: - 週間まとめ買い

    /// 週間まとめ買いビューの、カテゴリ(売り場)ごとにまとめた材料セクション。
    struct WeeklyShoppingSection: Identifiable {
        let category: ItemCategory?   // nil = 未分類
        let items: [WeeklyShoppingAggregator.Item]
        var id: String { category?.id ?? "__uncategorized__" }
        /// セクション見出し(絵文字 + 名前。未分類は既定表記)
        var title: String {
            guard let category else { return "❓ 未分類" }
            return "\(category.emoji) \(category.name)"
        }
    }

    /// まだ材料を展開していない献立の材料を品名で集約し、買い物リストと同じ
    /// カテゴリ順(売り場順・未分類は末尾)にグループ化して返す。週間まとめ買いビューで使う。
    func weeklyShoppingSections() -> [WeeklyShoppingSection] {
        let recipesById = Dictionary(
            recipes.compactMap { recipe in recipe.id.map { ($0, recipe) } },
            uniquingKeysWith: { first, _ in first }
        )
        let pending = planEntries.filter { $0.ingredientsAddedAt == nil }
        let items = WeeklyShoppingAggregator.aggregate(entries: pending, recipesById: recipesById)

        // 品名 → 推定カテゴリID(未分類は nil キー)でまとめる
        var itemsByCategoryId: [String?: [WeeklyShoppingAggregator.Item]] = [:]
        for item in items {
            let id = categoryId(forMatcherKey: CategoryGuesser.guessKey(from: item.name))
            itemsByCategoryId[id, default: []].append(item)
        }

        // categories は sortOrder 昇順で保持しているので、その順でセクション化し、未分類は末尾へ
        var sections: [WeeklyShoppingSection] = []
        for category in categories {
            guard let id = category.id,
                  let items = itemsByCategoryId[id], !items.isEmpty else { continue }
            sections.append(WeeklyShoppingSection(category: category, items: items))
        }
        if let uncategorized = itemsByCategoryId[nil], !uncategorized.isEmpty {
            sections.append(WeeklyShoppingSection(category: nil, items: uncategorized))
        }
        return sections
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
    private var purchaseHistoryRef: CollectionReference { householdRef.collection("purchaseHistory") }

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
                    // 退出・世帯切り替え時の権限エラーは自然に起きるので警告しない
                    if error.isFirestorePermissionDenied { return }
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
                    // 退出・世帯切り替え時の権限エラーは自然に起きるので警告しない
                    if error.isFirestorePermissionDenied { return }
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
                    // 退出・世帯切り替え時の権限エラーは自然に起きるので警告しない
                    if error.isFirestorePermissionDenied { return }
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

    func addRecipe(name: String, emoji: String, ingredients: [RecipeIngredient],
                   memo: String, baseServings: Int) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let recipe = Recipe(
            id: nil,
            name: trimmed,
            emoji: emoji.isEmpty ? "🍽️" : emoji,
            ingredients: cleanedIngredients(ingredients),
            memo: cleanedMemo(memo),
            baseServings: Self.clampedServings(baseServings),
            createdAt: nil   // サーバー時刻
        )
        do {
            _ = try recipesRef.addDocument(from: recipe)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateRecipe(_ recipe: Recipe, name: String, emoji: String,
                      ingredients: [RecipeIngredient], memo: String, baseServings: Int) {
        guard let id = recipe.id else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var updated = recipe
        updated.name = trimmed
        updated.emoji = emoji.isEmpty ? "🍽️" : emoji
        updated.ingredients = cleanedIngredients(ingredients)
        updated.memo = cleanedMemo(memo)
        updated.baseServings = Self.clampedServings(baseServings)
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

    func addPlan(recipe: Recipe, on date: Date, servings: Int) {
        guard let recipeId = recipe.id else { return }
        let entry = MealPlanEntry(
            id: nil,
            date: Self.dateKey(date),
            recipeId: recipeId,
            recipeName: recipe.name,
            recipeEmoji: recipe.emoji,
            addedByUid: currentUid,
            servings: Self.clampedServings(servings),
            createdAt: nil,   // サーバー時刻
            ingredientsAddedAt: nil
        )
        do {
            _ = try plansRef.addDocument(from: entry)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// レシピ選択シートで1件選ばれたときの入口。
    /// カタログ由来(まだ Firestore に無い)なら先にレシピ帳へ保存してから献立に追加し、
    /// レシピ帳のレシピならそのまま献立に追加する。
    func selectRecipe(_ recipe: Recipe, on date: Date, servings: Int) {
        if RecipeCatalog.isCatalog(recipe) {
            addPlanFromCatalog(recipe, on: date, servings: servings)
        } else {
            addPlan(recipe: recipe, on: date, servings: servings)
        }
    }

    /// カタログの定番レシピを献立へ追加する。
    /// 同名のレシピがすでにレシピ帳にあれば再利用し、無ければレシピ帳へ保存(マテリアライズ)して
    /// 採番された Firestore ドキュメントIDで献立エントリを作る。
    private func addPlanFromCatalog(_ catalogRecipe: Recipe, on date: Date, servings: Int) {
        let key = MealSuggester.normalize(catalogRecipe.name)
        if let existing = recipes.first(where: { MealSuggester.normalize($0.name) == key }) {
            addPlan(recipe: existing, on: date, servings: servings)
            return
        }

        // id / createdAt はサーバー採番に任せるため、合成値を外した新規レシピを保存する
        let recipe = Recipe(
            id: nil,
            name: catalogRecipe.name,
            emoji: catalogRecipe.emoji,
            ingredients: catalogRecipe.ingredients,
            memo: catalogRecipe.memo,
            createdAt: nil
        )
        do {
            let ref = try recipesRef.addDocument(from: recipe)
            var saved = recipe
            saved.id = ref.documentID
            addPlan(recipe: saved, on: date, servings: servings)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 追加済みの献立の人数を更新する。
    /// すでに材料を買い物リストへ展開済み(ingredientsAddedAt != nil)なら、
    /// その献立由来の未購入アイテムの数量も新しい人数に合わせて再計算する。
    /// (購入済みアイテムはそのまま残す)
    func updateServings(_ entry: MealPlanEntry, to servings: Int) async {
        guard let id = entry.id else { return }
        let clamped = Self.clampedServings(servings)
        guard clamped != entry.servingsOrDefault else { return }

        do {
            // 材料未展開、またはレシピが削除済みなら人数だけ更新する
            guard entry.ingredientsAddedAt != nil,
                  let recipe = recipes.first(where: { $0.id == entry.recipeId }) else {
                try await plansRef.document(id).updateData(["servings": clamped])
                return
            }

            // 材料名 → 新しい人数にスケールした数量(nil = 数量欄を消す)
            let scaledByName: [String: String?] = Dictionary(
                recipe.ingredients.map { ingredient in
                    (ingredient.name,
                     IngredientScaler.scale(ingredient.quantity,
                                            from: recipe.baseServingsOrDefault, to: clamped))
                },
                uniquingKeysWith: { first, _ in first }
            )

            // このレシピ由来の未購入アイテムだけを対象に数量を更新する
            let snapshot = try await itemsRef
                .whereField("isChecked", isEqualTo: false)
                .whereField("sourceRecipeName", isEqualTo: recipe.name)
                .getDocuments()

            let batch = db.batch()
            batch.updateData(["servings": clamped], forDocument: plansRef.document(id))
            for document in snapshot.documents {
                guard let name = document.data()["name"] as? String,
                      let scaled = scaledByName[name] else { continue }
                if let scaled {
                    batch.updateData(["quantity": scaled], forDocument: document.reference)
                } else {
                    batch.updateData(["quantity": FieldValue.delete()], forDocument: document.reference)
                }
            }
            try await batch.commit()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 人数の選択範囲(1〜12人前)。範囲外の入力をこの範囲に収める
    static let servingsRange = 1...12
    static func clampedServings(_ servings: Int) -> Int {
        min(max(servings, servingsRange.lowerBound), servingsRange.upperBound)
    }

    /// レシピ帳にまだ無い「定番レシピ」。レシピ選択シートの「いろいろな料理」欄と
    /// 提案生成の候補に使う。すでに同名レシピを登録済みのものは重複を避けて除外する。
    var catalogCandidates: [Recipe] {
        let registered = Set(recipes.map { MealSuggester.normalize($0.name) })
        return RecipeCatalog.all.filter { !registered.contains(MealSuggester.normalize($0.name)) }
    }

    /// 献立を削除する。
    /// - Parameter alsoRemovingIngredients: true のとき、そのレシピの材料のうち
    ///   「未購入」かつ「削除後に残る他の献立では使わない」ものを買い物リストからも削除する。
    ///   購入済み(チェック済み)の材料は残す。
    func removePlan(_ entry: MealPlanEntry, alsoRemovingIngredients: Bool) async {
        guard let entryId = entry.id else { return }

        // 材料を消さない、またはレシピが見つからない(削除済み)場合は献立エントリのみ削除
        guard alsoRemovingIngredients,
              let recipe = recipes.first(where: { $0.id == entry.recipeId }) else {
            try? await plansRef.document(entryId).delete()
            return
        }

        // 他の残る献立で使う材料は残すため、削除対象から除外する
        let recipesById = Dictionary(recipes.compactMap { recipe in
            recipe.id.map { ($0, recipe) }
        }, uniquingKeysWith: { first, _ in first })
        let namesToRemove = MealPlanIngredientRemoval.namesToRemove(
            deletedRecipe: recipe,
            remainingEntries: planEntries.filter { $0.id != entry.id },
            recipesById: recipesById
        )
        guard !namesToRemove.isEmpty else {
            try? await plansRef.document(entryId).delete()
            return
        }

        do {
            // 未購入アイテムのみを対象に、品名が一致するものを削除
            let snapshot = try await itemsRef
                .whereField("isChecked", isEqualTo: false)
                .getDocuments()
            let batch = db.batch()
            batch.deleteDocument(plansRef.document(entryId))
            for document in snapshot.documents {
                guard let name = document.data()["name"] as? String,
                      namesToRemove.contains(name) else { continue }
                batch.deleteDocument(document.reference)
            }
            try await batch.commit()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 表示中(今日以降)の献立をすべて削除する。買い物リストの「まとめて削除」に相当。
    /// - Parameter alsoRemovingIngredients: true のとき、削除する献立の材料のうち
    ///   「未購入」のものを買い物リストからも削除する。購入済み(チェック済み)は残す。
    func removeAllPlans(alsoRemovingIngredients: Bool) async {
        let entries = planEntries
        guard !entries.isEmpty else { return }

        // 全献立を消すので「残る献立で使う材料」は無い → 各レシピの全材料が削除候補になる。
        // 材料を消さない場合は空集合のまま(献立エントリの削除だけ行う)。
        var namesToRemove: Set<String> = []
        if alsoRemovingIngredients {
            for entry in entries {
                guard let recipe = recipes.first(where: { $0.id == entry.recipeId }) else { continue }
                namesToRemove.formUnion(recipe.ingredients.map(\.name))
            }
        }

        do {
            let batch = db.batch()
            for entry in entries {
                guard let id = entry.id else { continue }
                batch.deleteDocument(plansRef.document(id))
            }
            if !namesToRemove.isEmpty {
                // 未購入アイテムのみを対象に、品名が一致するものを削除
                let snapshot = try await itemsRef
                    .whereField("isChecked", isEqualTo: false)
                    .getDocuments()
                for document in snapshot.documents {
                    guard let name = document.data()["name"] as? String,
                          namesToRemove.contains(name) else { continue }
                    batch.deleteDocument(document.reference)
                }
            }
            try await batch.commit()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 献立提案(購入履歴からの好みスコアリング)

    /// 購入履歴(好み)・当月の旬食材・直近の献立履歴(マンネリ回避)を総合して、
    /// おすすめレシピを `suggestions` に反映する。レシピ選択シートを開いたときに呼ぶ。
    /// 今週すでに予定に入っているレシピは除外する。
    func generateSuggestions() async {
        isGeneratingSuggestions = true
        defer { isGeneratingSuggestions = false }
        do {
            // 好み: 直近500件のみ集計(複合インデックス不要な単一フィールド order)
            let snapshot = try await purchaseHistoryRef
                .order(by: "purchasedAt", descending: true)
                .limit(to: 500)
                .getDocuments()

            var preferenceCounts: [String: Int] = [:]
            for document in snapshot.documents {
                guard let name = document.data()["name"] as? String else { continue }
                let key = MealSuggester.normalize(name)
                guard !key.isEmpty else { continue }
                preferenceCounts[key, default: 0] += 1
            }

            // マンネリ回避: 直近30日に作った(献立へ入れた)レシピほど提案を控える
            let recentCooks = try await recentCookCounts(days: 30)

            let excluded = Set(planEntries.map(\.recipeId))
            suggestions = MealSuggester.suggest(
                recipes: recipes + catalogCandidates,
                preferenceCounts: preferenceCounts,
                seasonalIngredients: SeasonalIngredients.current(),
                recentCookCounts: recentCooks,
                excludedRecipeIds: excluded,
                limit: 5
            )
        } catch {
            // 提案はあくまで補助機能なので、失敗時はエラー表示せず提案を空にするだけ
            suggestions = []
        }
    }

    /// 直近 `days` 日の過去の献立を集計し、recipeId → 作った回数 を返す。
    /// `date` の範囲クエリのみ(単一フィールド)なので複合インデックスは不要。
    private func recentCookCounts(days: Int) async throws -> [String: Int] {
        let today = Calendar.current.startOfDay(for: Date())
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: today) else {
            return [:]
        }
        let snapshot = try await plansRef
            .whereField("date", isGreaterThanOrEqualTo: Self.dateKey(cutoff))
            .whereField("date", isLessThan: Self.dateKey(today))
            .getDocuments()

        var counts: [String: Int] = [:]
        for document in snapshot.documents {
            guard let recipeId = document.data()["recipeId"] as? String else { continue }
            counts[recipeId, default: 0] += 1
        }
        return counts
    }

    // MARK: - 食材展開(レシピ → 買い物リスト)

    /// 買い物リストへ追加する材料1件と、その出所(献立レシピ)。
    /// 買い物リスト側で「どの料理の材料か」を表示するために出所を持たせる。
    private struct IngredientToAdd {
        let ingredient: RecipeIngredient
        let recipeName: String
        let recipeEmoji: String
    }

    /// 1件の献立の材料を買い物リストへ追加する
    func addIngredients(for entry: MealPlanEntry) async {
        guard let recipe = recipes.first(where: { $0.id == entry.recipeId }) else {
            errorMessage = "レシピが見つかりません(削除された可能性があります)"
            return
        }
        do {
            let addedCount = try await addToShoppingList(additions(from: recipe, servings: entry.servingsOrDefault))
            markIngredientsAdded([entry])
            infoMessage = addedCount == 0
                ? "材料はすべてリストにあります"
                : "\(addedCount)件を買い物リストに追加しました"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 週間まとめ買いの確認画面で選択・編集した材料1件。
    /// 集約結果をユーザーが確認画面で編集(数量の書き換え・不要な材料の除外)した後の値を表す。
    struct EditedIngredient {
        var name: String
        var quantity: String?
        var recipeName: String
        var recipeEmoji: String
    }

    /// 確認画面で選んだ材料だけを買い物リストへ追加し、未展開の献立を「追加済み」にする。
    /// 数量はユーザーが編集した値をそのまま使う(集約時のスケール済みの値を書き換え可能)。
    func addSelectedWeeklyIngredients(_ items: [EditedIngredient]) async {
        guard !items.isEmpty else { return }
        // レシピが解決できる未展開の献立を「追加済み」にする(まとめて追加と同じ扱い)
        let resolvedEntries = planEntries.filter { entry in
            entry.ingredientsAddedAt == nil && recipes.contains { $0.id == entry.recipeId }
        }
        let additions = items.map { item in
            IngredientToAdd(
                ingredient: RecipeIngredient(name: item.name, quantity: item.quantity),
                recipeName: item.recipeName,
                recipeEmoji: item.recipeEmoji
            )
        }
        do {
            let addedCount = try await addToShoppingList(additions)
            markIngredientsAdded(resolvedEntries)
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

        var ingredients: [IngredientToAdd] = []
        var resolvedEntries: [MealPlanEntry] = []
        for entry in pending {
            // レシピが削除された献立はスキップ(未展開のまま残す)
            guard let recipe = recipes.first(where: { $0.id == entry.recipeId }) else { continue }
            ingredients += additions(from: recipe, servings: entry.servingsOrDefault)
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

    /// レシピの各材料に出所(料理名・絵文字)を添えて追加候補にする。
    /// 数量は「献立の人数 / レシピの基準人数」でスケールする。
    private func additions(from recipe: Recipe, servings: Int) -> [IngredientToAdd] {
        recipe.ingredients.map { ingredient in
            var scaled = ingredient
            scaled.quantity = IngredientScaler.scale(
                ingredient.quantity, from: recipe.baseServingsOrDefault, to: servings
            )
            return IngredientToAdd(ingredient: scaled, recipeName: recipe.name, recipeEmoji: recipe.emoji)
        }
    }

    /// 材料を買い物アイテムとして一括追加し、追加した件数を返す。
    /// - 同じ品名が未購入リストに既にある場合はスキップ(数量の合算はしない)
    /// - カテゴリは CategoryGuesser で推定。推定できなければ未分類のまま追加
    /// - どの料理から追加したかを sourceRecipeName / sourceRecipeEmoji に記録する
    private func addToShoppingList(_ additions: [IngredientToAdd]) async throws -> Int {
        let snapshot = try await itemsRef
            .whereField("isChecked", isEqualTo: false)
            .getDocuments()
        var existingNames = Set(snapshot.documents.compactMap { $0.data()["name"] as? String })

        var pendingItems: [[String: Any]] = []
        for addition in additions {
            let ingredient = addition.ingredient
            guard !existingNames.contains(ingredient.name) else { continue }
            existingNames.insert(ingredient.name)   // 同一レシピ・レシピ間の重複も防ぐ

            var data: [String: Any] = [
                "name": ingredient.name,
                "isChecked": false,
                "addedByUid": currentUid,
                "addedByName": currentUserName,
                "sourceRecipeName": addition.recipeName,
                "sourceRecipeEmoji": addition.recipeEmoji,
                "createdAt": FieldValue.serverTimestamp(),
            ]
            if let categoryId = categoryId(forMatcherKey: CategoryGuesser.guessKey(from: ingredient.name)) {
                data["categoryId"] = categoryId
            }
            if let quantity = ingredient.quantity {
                data["quantity"] = quantity
            }
            pendingItems.append(data)
        }

        // まとめ買い(2件以上の一括追加)は通知を1回にまとめる。
        // 通知は items の作成を監視する Cloud Function が送るため、
        // 先頭の1件だけに件数(batchSize)を持たせて「〇件追加」と通知させ、
        // 残りは suppressNotification で個別通知を抑制する。
        if pendingItems.count >= 2 {
            pendingItems[0]["batchSize"] = pendingItems.count
            for index in 1..<pendingItems.count {
                pendingItems[index]["suppressNotification"] = true
            }
        }

        let batch = db.batch()
        for data in pendingItems {
            batch.setData(data, forDocument: itemsRef.document())
        }
        if !pendingItems.isEmpty {
            try await batch.commit()
        }
        return pendingItems.count
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
