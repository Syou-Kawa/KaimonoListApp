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

    /// 端末内 AI(Foundation Models)による献立支援の結果。対応端末でのみ使う。
    private(set) var aiAdvice: MealAIAssistant.NutritionAdvice?       // 栄養バランスの定性的アドバイス
    private(set) var aiInventedRecipe: MealAIAssistant.InventedRecipe?  // 旬の食材で創作したレシピ
    private(set) var aiProposal: [MealAIAssistant.ProposedMeal] = []  // 数日分の献立提案
    private(set) var isRunningAI = false
    /// AI 機能のシート内に表示するフィードバック(未生成・失敗の案内)。
    /// 買い物リスト用の infoMessage とはアラートが別(シートの上では背面アラートが出ないため)。
    private(set) var aiMessage: String?
    /// この端末で AI 献立支援が使えるか(iOS 26+ かつ Apple Intelligence 対応時のみ true)
    var isAIAvailable: Bool { MealAIAssistant.isAvailable }

    /// 日付を過ぎた献立を「未処理」として拾い続ける猶予日数。
    /// これより古い未処理の献立は監視対象から外す(際限なく溜まらないようにする)
    static let pastGraceDays = 30

    /// 献立表に表示する日付。今月の1日〜末日を基本にしつつ、
    /// 今月より先(来月以降)の日付に予定が入っていればその日も含める(遠い未来の予定が隠れないように)。
    /// 月が変わると自動でその月の範囲になる。
    var planDates: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let monthInterval = calendar.dateInterval(of: .month, for: today) else { return [] }
        let monthStart = calendar.startOfDay(for: monthInterval.start)

        var keys: Set<String> = []
        var dates: [Date] = []
        // 今月の1日〜末日(monthInterval.end は翌月1日の0時なので、それ未満をループ)
        var date = monthStart
        while date < monthInterval.end {
            keys.insert(Self.dateKey(date))
            dates.append(date)
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        // 今月より先(来月以降)の日付に予定があれば、その日も表示対象に加える。
        // 今月より前の過去日は既定では出さない(「記録」タブで振り返る)。
        for entry in planEntries where !keys.contains(entry.date) {
            guard let entryDate = Self.date(fromKey: entry.date), entryDate >= monthStart else { continue }
            keys.insert(entry.date)
            dates.append(entryDate)
        }
        return dates.sorted()
    }

    func entries(on date: Date) -> [MealPlanEntry] {
        let key = Self.dateKey(date)
        return planEntries.filter { $0.date == key }
    }

    /// 今月より前なのに材料をまだ買い物リストへ追加していない献立(買い忘れ防止に「未処理」として表示)。
    /// 古い順に並べる。監視範囲(pastGraceDays)より前のものは含まれない。
    /// 今月内の過去日はカレンダー(planDates)の各日セクションに出るので、ここには含めず重複を避ける。
    var pastPendingEntries: [MealPlanEntry] {
        let monthStartKey = Self.dateKey(Self.currentMonthDateRange().lowerBound)
        return planEntries.filter { $0.date < monthStartKey && $0.ingredientsAddedAt == nil }
    }

    /// 献立エントリに対応するレシピ。削除済みなら nil(材料確認画面で使用)
    func recipe(for entry: MealPlanEntry) -> Recipe? {
        recipes.first { $0.id == entry.recipeId }
    }

    /// 材料をまだ買い物リストへ展開していない「今日以降の」献立の数(まとめて追加ボタンの表示判定)。
    /// 今月内の過去日は記録なので買い物操作の対象にしない。
    var pendingEntryCount: Int {
        planEntries.filter { $0.date >= Self.todayKey() && $0.ingredientsAddedAt == nil }.count
    }

    /// 今日以降の献立が1件でもあるか(まとめて削除ボタンの活性判定)。
    /// 過去日の記録は一括削除の対象にしないので数えない。
    var hasPlanEntries: Bool {
        planEntries.contains { $0.date >= Self.todayKey() }
    }

    /// 今日以降で材料をすでに買い物リストへ展開した献立があるか(まとめて削除の選択肢切り替えに使用)
    var hasAddedIngredients: Bool {
        planEntries.contains { $0.date >= Self.todayKey() && $0.ingredientsAddedAt != nil }
    }

    // MARK: - 週間まとめ買い(レシピ別に編集して追加)

    /// まとめ買い画面のレシピ単位のグループ。レシピ本来の分量(基準人数)をそのまま
    /// 編集対象にし、確定時にレシピ帳へ反映する。買い物リストへは献立の人数にスケールして追加する。
    struct WeeklyRecipeGroup: Identifiable {
        let recipeId: String
        let recipeName: String
        let recipeEmoji: String
        let baseServings: Int
        let ingredients: [RecipeIngredient]   // 基準人数の分量(未スケール)
        var id: String { recipeId }
    }

    /// まだ材料を展開していない献立を、レシピ単位でまとめて返す(初出順・同じレシピは1件)。
    /// レシピが解決できない(削除済み)エントリは除く。まとめ買いビューで使う。
    func weeklyRecipeGroups() -> [WeeklyRecipeGroup] {
        var order: [String] = []
        var seen: Set<String> = []
        // 今日以降の未展開のみ対象(今月内の過去日は記録なので買い物操作の対象にしない)
        for entry in planEntries where entry.date >= Self.todayKey() && entry.ingredientsAddedAt == nil {
            let id = entry.recipeId
            guard !seen.contains(id), recipes.contains(where: { $0.id == id }) else { continue }
            seen.insert(id)
            order.append(id)
        }
        return order.compactMap { id in
            guard let recipe = recipes.first(where: { $0.id == id }) else { return nil }
            return WeeklyRecipeGroup(
                recipeId: id,
                recipeName: recipe.name,
                recipeEmoji: recipe.emoji,
                baseServings: recipe.baseServingsOrDefault,
                ingredients: recipe.ingredients
            )
        }
    }

    /// 品名から売り場カテゴリの見出し(絵文字 + 名前)を返す。推定できなければ nil。
    /// まとめ買いビューで各材料の売り場ラベルを表示するために使う。
    func categoryLabel(for name: String) -> String? {
        guard let id = categoryId(forMatcherKey: CategoryGuesser.guessKey(from: name)),
              let category = categories.first(where: { $0.id == id }) else { return nil }
        return "\(category.emoji) \(category.name)"
    }

    /// 品名から売り場カテゴリのドキュメントIDを推定する。推定できなければ nil(未分類)。
    /// まとめ買いビューで各材料のカテゴリの初期値に使う。
    func categoryId(for name: String) -> String? {
        categoryId(forMatcherKey: CategoryGuesser.guessKey(from: name))
    }

    // MARK: - 依存

    let householdId: String
    let currentUid: String
    let currentUserName: String

    private let db = Firestore.firestore()
    private var recipesListener: ListenerRegistration?
    private var plansListener: ListenerRegistration?
    private var categoriesListener: ListenerRegistration?
    private var itemsListener: ListenerRegistration?

    /// 買い物リストにある未購入・購入済みを問わないアイテムの品名。
    /// 追加済み献立の「材料がまだリストにあるか」を判定するために保持する。
    private var shoppingItemNames: Set<String> = []

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

    /// 今日(端末タイムゾーンの暦日始まり)の日付キー。
    /// 「今日以降=操作対象」「今日より前=記録」を切り分ける基準に使う。
    static func todayKey() -> String {
        dateKey(Calendar.current.startOfDay(for: Date()))
    }

    /// "yyyy-MM-dd" のキーから端末タイムゾーンの暦日を復元する(dateKey の逆変換)
    static func date(fromKey key: String) -> Date? {
        dateKeyFormatter.date(from: key)
    }

    /// 「日付を選んで献立を追加」で選べる日付の範囲(今月の1日〜末日)。
    /// 献立を追加できる期間を今月に限定するために使う(表示範囲 planDates と揃える)。
    static func currentMonthDateRange(now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
        let today = calendar.startOfDay(for: now)
        guard let interval = calendar.dateInterval(of: .month, for: today) else { return today...today }
        let start = calendar.startOfDay(for: interval.start)
        // interval.end は翌月1日の0時。末日の0時を上限にする
        let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? start
        return start...calendar.startOfDay(for: lastDay)
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

        // 今月以降の献立に加え、直近 pastGraceDays 日分も監視する。
        // 今月内の過去日は処理済みも含めて「記録」として画面に残す。
        // 今月より前は「未処理」だけを買い忘れ防止として残し、処理済みは除外する。
        // それより古い過去分は監視しない。
        let today = Calendar.current.startOfDay(for: Date())
        let pastCutoff = Calendar.current.date(byAdding: .day, value: -Self.pastGraceDays, to: today) ?? today
        plansListener = plansRef
            .whereField("date", isGreaterThanOrEqualTo: Self.dateKey(pastCutoff))
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
                // 今月以降は処理済みも残し(今月内の過去日を記録として表示)、
                // 今月より前は未処理のみ残す(買い忘れ防止の「未処理」用)。
                let monthStartKey = Self.dateKey(Self.currentMonthDateRange().lowerBound)
                let visible = decoded.filter { $0.date >= monthStartKey || $0.ingredientsAddedAt == nil }
                // date + createdAt の複合ソートはローカルで行う(複合インデックス不要にするため)
                self.planEntries = visible.sorted {
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

        // 買い物リストの変化を監視し、追加済み献立の材料が削除されたら追加済みを解除する。
        // 追加直後は材料が存在するので解除されず、材料が全て消えたときだけ再追加できる状態へ戻す。
        itemsListener = itemsRef
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    // 退出・世帯切り替え時の権限エラーは自然に起きるので警告しない
                    if error.isFirestorePermissionDenied { return }
                    self.errorMessage = error.localizedDescription
                    return
                }
                self.shoppingItemNames = Set(
                    snapshot?.documents.compactMap { $0.data()["name"] as? String } ?? []
                )
                self.resetAddedStatusForRemovedIngredients()
            }
    }

    func stopListening() {
        recipesListener?.remove()
        plansListener?.remove()
        categoriesListener?.remove()
        itemsListener?.remove()
        recipesListener = nil
        plansListener = nil
        categoriesListener = nil
        itemsListener = nil
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

    /// 今日以降の献立をすべて削除する。買い物リストの「まとめて削除」に相当。
    /// 今月内の過去日の献立は「記録」なので削除対象にしない(記録を残す)。
    /// - Parameter alsoRemovingIngredients: true のとき、削除する献立の材料のうち
    ///   「未購入」のものを買い物リストからも削除する。購入済み(チェック済み)は残す。
    func removeAllPlans(alsoRemovingIngredients: Bool) async {
        let entries = planEntries.filter { $0.date >= Self.todayKey() }
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
            let preferenceCounts = try await fetchPreferenceCounts()

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

    /// 購入履歴(直近500件)から「正規化した品名 → 購入回数」を集計する。
    /// 献立提案と AI 支援の好み入力で共用する(単一フィールド order なので複合インデックス不要)。
    private func fetchPreferenceCounts() async throws -> [String: Int] {
        let snapshot = try await purchaseHistoryRef
            .order(by: "purchasedAt", descending: true)
            .limit(to: 500)
            .getDocuments()

        var counts: [String: Int] = [:]
        for document in snapshot.documents {
            guard let name = document.data()["name"] as? String else { continue }
            let key = MealSuggester.normalize(name)
            guard !key.isEmpty else { continue }
            counts[key, default: 0] += 1
        }
        return counts
    }

    // MARK: - AI 献立支援(端末内 Foundation Models・対応端末のみ)

    /// 今日以降の献立の料理名(重複なし・最大20件)。AI へ渡す文脈に使う。
    private func upcomingRecipeNames(limit: Int = 20) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for entry in planEntries where entry.date >= Self.todayKey() {
            let key = MealSuggester.normalize(entry.recipeName)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            names.append(entry.recipeName)
            if names.count >= limit { break }
        }
        return names
    }

    /// 好み(購入回数)の上位食材名。AI へ渡す文脈に使う。失敗時は空配列。
    private func topPreferredIngredients(limit: Int) async -> [String] {
        guard let counts = try? await fetchPreferenceCounts() else { return [] }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    /// 直近 `days` 日に作った料理名(重複なし)。AI のマンネリ回避の文脈に使う。失敗時は空配列。
    private func recentCookedRecipeNames(days: Int) async -> [String] {
        let today = Calendar.current.startOfDay(for: Date())
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: today),
              let snapshot = try? await plansRef
                .whereField("date", isGreaterThanOrEqualTo: Self.dateKey(cutoff))
                .whereField("date", isLessThan: Self.dateKey(today))
                .getDocuments() else { return [] }
        var seen: Set<String> = []
        var names: [String] = []
        for document in snapshot.documents {
            guard let name = document.data()["recipeName"] as? String else { continue }
            let key = MealSuggester.normalize(name)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            names.append(name)
        }
        return names
    }

    /// AI シートを開いたときに前回の結果をクリアする(古い献立に対する結果が残らないように)。
    func resetAIResults() {
        aiAdvice = nil
        aiProposal = []
        aiInventedRecipe = nil
        aiMessage = nil
    }

    /// レシピ選択シートを開いたときに、前回の創作レシピだけをクリアする。
    /// 別シート(AIにおまかせ)の栄養アドバイスや数日分提案は消さない。
    func clearInventedRecipe() {
        aiInventedRecipe = nil
        aiMessage = nil
    }

    /// これからの献立全体を見て、栄養バランスの定性的アドバイスを生成する。
    func requestNutritionAdvice() async {
        isRunningAI = true
        defer { isRunningAI = false }
        aiAdvice = nil
        aiMessage = nil
        let names = upcomingRecipeNames()
        guard !names.isEmpty else {
            aiMessage = "これからの献立がありません。先に献立を追加してください。"
            return
        }
        let season = Array(SeasonalIngredients.current())
        aiAdvice = await MealAIAssistant.nutritionAdvice(recipeNames: names, season: season)
        if aiAdvice == nil {
            aiMessage = "アドバイスを生成できませんでした。時間をおいて再度お試しください。"
        }
    }

    /// 旬の食材を使った新しいレシピを1品創作する。既存レシピ/カタログと重複しないものを返す。
    func requestInventedRecipe() async {
        isRunningAI = true
        defer { isRunningAI = false }
        aiInventedRecipe = nil
        aiMessage = nil
        let season = Array(SeasonalIngredients.current())
        guard !season.isEmpty else {
            aiMessage = "旬の食材情報がありません。"
            return
        }
        let avoid = Set((recipes + catalogCandidates).map { MealSuggester.normalize($0.name) })
        let preferred = await topPreferredIngredients(limit: 10)
        aiInventedRecipe = await MealAIAssistant.inventRecipe(
            season: season, avoidNames: avoid, preferred: preferred
        )
        if aiInventedRecipe == nil {
            aiMessage = "レシピを生成できませんでした。時間をおいて再度お試しください。"
        }
    }

    /// 数日分の献立をまとめて提案する(好み・旬・栄養バランスの偏り回避を考慮)。
    func requestMealPlan(days: Int) async {
        isRunningAI = true
        defer { isRunningAI = false }
        aiProposal = []
        aiMessage = nil
        let season = Array(SeasonalIngredients.current())
        let existing = Array(recipes.map(\.name).prefix(20))
        let preferred = await topPreferredIngredients(limit: 10)
        let recent = await recentCookedRecipeNames(days: 30)
        aiProposal = await MealAIAssistant.planMeals(
            days: days, existingRecipes: existing,
            season: season, preferred: preferred, recent: recent
        ) ?? []
        if aiProposal.isEmpty {
            aiMessage = "献立を生成できませんでした。時間をおいて再度お試しください。"
        }
    }

    /// AI が創作/提案したレシピを献立に追加する。
    /// 同名のレシピがすでにレシピ帳にあれば再利用し、無ければレシピ帳へ保存(マテリアライズ)してから追加する
    /// (カタログの `addPlanFromCatalog` と同じ流れ)。
    func acceptInventedRecipe(_ invented: MealAIAssistant.InventedRecipe, on date: Date, servings: Int) {
        let key = MealSuggester.normalize(invented.name)
        if let existing = recipes.first(where: { MealSuggester.normalize($0.name) == key }) {
            addPlan(recipe: existing, on: date, servings: servings)
            return
        }
        let recipe = Recipe(
            id: nil,
            name: invented.name,
            emoji: invented.emoji,
            ingredients: invented.ingredients,
            memo: invented.memo,
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

    /// 1件の提案を献立に追加し、追加済みの提案はリストから外す。
    /// (同じ行を続けて押しても二重追加にならないようにし、追加できたことを視覚的に示す)
    func acceptProposal(_ meal: MealAIAssistant.ProposedMeal, on date: Date, servings: Int) {
        acceptInventedRecipe(meal.recipe, on: date, servings: servings)
        aiProposal.removeAll { $0.id == meal.id }
    }

    /// 数日分の提案をまとめて献立に追加する。各提案の `dayOffset` を基準日からの日数として割り当てる。
    func acceptAllProposals(from baseDate: Date, servings: Int) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: baseDate)
        for meal in aiProposal {
            guard let date = calendar.date(byAdding: .day, value: meal.dayOffset, to: start) else { continue }
            acceptInventedRecipe(meal.recipe, on: date, servings: servings)
        }
        aiProposal = []
    }

    // MARK: - 食材展開(レシピ → 買い物リスト)

    /// 買い物リストへ追加する材料1件と、その出所(献立レシピ)。
    /// 買い物リスト側で「どの料理の材料か」を表示するために出所を持たせる。
    private struct IngredientToAdd {
        let ingredient: RecipeIngredient
        let recipeName: String
        let recipeEmoji: String
        /// 買い物アイテムに付ける売り場カテゴリのID。nil は未分類。
        /// 通常は品名からの推定値、まとめ買い画面では画面で選んだ値。
        var categoryId: String?
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

    /// まとめ買いの確認画面で編集したレシピ1件分。材料の全体(レシピへ保存する内容)と、
    /// そのうち買い物リストへ追加する材料(選択されたもの)を持つ。
    struct WeeklyRecipeEdit {
        let recipeId: String
        var ingredients: [RecipeIngredient]      // 編集後の全材料(レシピ帳へ保存)
        var selectedIngredientIds: Set<String>   // 買い物リストへ追加する材料(RecipeIngredient.id)
        /// 画面で選んだ売り場カテゴリ(RecipeIngredient.id → categoryId)。
        /// 未登録の材料は品名からの推定にフォールバックする。カテゴリはレシピには保存しない。
        var categoryByIngredientId: [String: String]
    }

    /// まとめ買い画面の編集を確定する。追加ボタンの1操作で次を行う。
    /// 1) 材料が変わったレシピをレシピ帳へ保存(基準人数の分量をそのまま反映)、
    /// 2) 選択された材料を各献立の人数にスケールして買い物リストへ追加、
    /// 3) 対象の未展開献立を「追加済み」にする。
    func applyWeeklyEditsAndAdd(_ edits: [WeeklyRecipeEdit]) async {
        guard !edits.isEmpty else { return }

        // レシピが解決できる、今日以降の未展開の献立(まとめ買いの対象)。
        // 今月内の過去日は記録なので対象外。
        let pending = planEntries.filter { entry in
            entry.date >= Self.todayKey() && entry.ingredientsAddedAt == nil
                && recipes.contains { $0.id == entry.recipeId }
        }
        guard !pending.isEmpty else { return }

        let editsById = Dictionary(edits.map { ($0.recipeId, $0) },
                                   uniquingKeysWith: { first, _ in first })

        // 1) 編集内容をレシピ帳へ反映(材料が変わったレシピだけ書き込む)。
        //    以降のスケール計算にも編集後の材料を使うため editedRecipesById に控える。
        var editedRecipesById: [String: Recipe] = [:]
        let recipeBatch = db.batch()
        var recipeWrites = 0
        for edit in edits {
            guard let recipe = recipes.first(where: { $0.id == edit.recipeId }),
                  let id = recipe.id else { continue }
            var updated = recipe
            updated.ingredients = cleanedIngredients(edit.ingredients)
            editedRecipesById[id] = updated
            guard updated.ingredients != recipe.ingredients else { continue }
            do {
                try recipeBatch.setData(from: updated, forDocument: recipesRef.document(id))
                recipeWrites += 1
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        // 2) 選択された材料を、各献立の人数にスケールして追加候補にする。
        //    同じレシピが複数の献立にあるときは addToShoppingList 側で品名重複を除く。
        var additions: [IngredientToAdd] = []
        for entry in pending {
            guard let recipe = editedRecipesById[entry.recipeId],
                  let edit = editsById[entry.recipeId] else { continue }
            for ingredient in recipe.ingredients
            where edit.selectedIngredientIds.contains(ingredient.id) {
                var scaled = ingredient
                scaled.quantity = IngredientScaler.scale(
                    ingredient.quantity,
                    from: recipe.baseServingsOrDefault, to: entry.servingsOrDefault
                )
                // 画面で選んだカテゴリを優先し、無ければ品名から推定する
                let categoryId = edit.categoryByIngredientId[ingredient.id]
                    ?? self.categoryId(for: ingredient.name)
                additions.append(IngredientToAdd(ingredient: scaled,
                                                 recipeName: recipe.name,
                                                 recipeEmoji: recipe.emoji,
                                                 categoryId: categoryId))
            }
        }

        do {
            if recipeWrites > 0 { try await recipeBatch.commit() }
            let addedCount = try await addToShoppingList(additions)
            markIngredientsAdded(pending)
            infoMessage = addedCount == 0
                ? "材料はすべてリストにあります"
                : "\(addedCount)件を買い物リストに追加しました"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 今日以降の未展開の献立すべての材料をまとめて買い物リストへ追加する
    /// (今月内の過去日は記録なので対象外)
    func addAllPendingIngredients() async {
        let pending = planEntries.filter { $0.date >= Self.todayKey() && $0.ingredientsAddedAt == nil }
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
            return IngredientToAdd(ingredient: scaled, recipeName: recipe.name, recipeEmoji: recipe.emoji,
                                   categoryId: categoryId(for: ingredient.name))
        }
    }

    /// 材料を買い物アイテムとして一括追加し、追加した件数を返す。
    /// - 同じ品名が未購入リストに既にある場合はスキップ(数量の合算はしない)
    /// - カテゴリは呼び出し側で解決済み(品名からの推定 or 画面での選択)。nil は未分類のまま追加
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
            if let categoryId = addition.categoryId {
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

    /// 追加済み(材料展開済み)の献立のうち、レシピの材料が買い物リストから
    /// すべて無くなったものは「追加済み」を解除し、再び追加できる状態へ戻す。
    /// 材料が1つでもリストに残っていれば追加済みのままにする。
    /// (レシピが削除済み・材料が空の献立は判定できないので対象外)
    /// 今月内の過去日は「記録」なので、材料が消えても追加済みは解除しない(今日以降のみ対象)。
    private func resetAddedStatusForRemovedIngredients() {
        let todayKey = Self.todayKey()
        let batch = db.batch()
        var writes = 0
        for entry in planEntries where entry.date >= todayKey && entry.ingredientsAddedAt != nil {
            guard let id = entry.id,
                  let recipe = recipes.first(where: { $0.id == entry.recipeId }) else { continue }
            let names = recipe.ingredients.map(\.name).filter { !$0.isEmpty }
            guard !names.isEmpty else { continue }
            // 材料が1つも買い物リストに残っていなければ追加済みを解除する
            guard !names.contains(where: { shoppingItemNames.contains($0) }) else { continue }
            batch.updateData(["ingredientsAddedAt": FieldValue.delete()],
                             forDocument: plansRef.document(id))
            writes += 1
        }
        if writes > 0 { batch.commit() }
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
