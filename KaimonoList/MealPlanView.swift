import SwiftUI

/// 献立プランナーのメイン画面。今日から7日分の献立表を表示し、
/// 各日にレシピを割り当てて材料を買い物リストへ展開できる
struct MealPlanView: View {
    @State private var viewModel: MealPlannerViewModel
    @State private var pickTarget: PickTarget?
    /// 削除確認ダイアログの対象。nil = 非表示
    @State private var deleteTarget: MealPlanEntry?
    /// 人数編集シートの対象。nil = 非表示
    @State private var editServingsTarget: MealPlanEntry?
    /// 材料確認シートの対象。nil = 非表示
    @State private var detailTarget: MealPlanEntry?
    /// 材料(レシピ)編集シートの対象。nil = 非表示
    @State private var editRecipeTarget: MealPlanEntry?
    /// 「献立をすべて削除」の確認ダイアログの表示状態
    @State private var isConfirmingClearAll = false
    /// 週間まとめ買いシートの表示状態
    @State private var isShowingWeeklyShopping = false

    /// sheet(item:) に渡すためのラッパー(Date は Identifiable ではないので)。
    /// `allowsDateSelection` が true のときはシート内で日付を選び直せる(「日付を選んで追加」用)。
    private struct PickTarget: Identifiable {
        let date: Date
        var allowsDateSelection: Bool = false
        var id: String { "\(MealPlannerViewModel.dateKey(date))-\(allowsDateSelection)" }
    }

    init(householdId: String, currentUid: String, currentUserName: String) {
        _viewModel = State(initialValue: MealPlannerViewModel(
            householdId: householdId,
            currentUid: currentUid,
            currentUserName: currentUserName
        ))
    }

    var body: some View {
        NavigationStack {
            List {
                if viewModel.pendingEntryCount > 0 {
                    Section {
                        Button {
                            isShowingWeeklyShopping = true
                        } label: {
                            Label("まとめてリストに追加", systemImage: "cart.badge.plus")
                        }
                    } footer: {
                        Text("献立の材料をまとめて見て、選んで買い物リストへ追加できます。")
                    }
                }

                if !viewModel.pastPendingEntries.isEmpty {
                    pastPendingSection
                }

                ForEach(viewModel.planDates, id: \.self) { date in
                    daySection(for: date)
                }
            }
            .navigationTitle("献立")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        RecipeListView(viewModel: viewModel)
                    } label: {
                        Image(systemName: "book")
                    }
                    .accessibilityLabel("レシピ帳を開く")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("日付を選んで献立を追加", systemImage: "calendar.badge.plus") {
                            pickTarget = PickTarget(date: Calendar.current.startOfDay(for: Date()),
                                                    allowsDateSelection: true)
                        }
                        Divider()
                        Button("献立をすべて削除", systemImage: "trash", role: .destructive) {
                            isConfirmingClearAll = true
                        }
                        .disabled(!viewModel.hasPlanEntries)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("その他の操作")
                }
            }
            .sheet(isPresented: $isShowingWeeklyShopping) {
                WeeklyShoppingView(viewModel: viewModel)
            }
            .sheet(item: $pickTarget) { target in
                RecipePickerSheet(viewModel: viewModel, date: target.date,
                                  allowsDateSelection: target.allowsDateSelection)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $editServingsTarget) { entry in
                ServingsEditSheet(entry: entry) { newServings in
                    Task { await viewModel.updateServings(entry, to: newServings) }
                }
                .presentationDetents([.height(220)])
            }
            .sheet(item: $detailTarget) { entry in
                MealPlanDetailSheet(viewModel: viewModel, entry: entry)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $editRecipeTarget) { entry in
                if let recipe = viewModel.recipe(for: entry) {
                    RecipeEditSheet(title: "材料を編集", recipe: recipe) { name, emoji, ingredients, memo, baseServings in
                        viewModel.updateRecipe(recipe, name: name, emoji: emoji,
                                               ingredients: ingredients, memo: memo, baseServings: baseServings)
                    }
                } else {
                    // レシピが削除済みの献立は編集できない旨を案内する
                    RecipeUnavailableSheet()
                }
            }
            // 注意: onDisappear で stopListening しない(レシピ帳へ push すると同期が止まるため)
            .onAppear { viewModel.startListening() }
            .alert("エラー", isPresented: errorBinding) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .alert("買い物リスト", isPresented: infoBinding) {
                Button("OK") { viewModel.infoMessage = nil }
            } message: {
                Text(viewModel.infoMessage ?? "")
            }
            .confirmationDialog(
                "献立を削除",
                isPresented: deleteTargetBinding,
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { entry in
                if entry.ingredientsAddedAt != nil {
                    Button("材料も買い物リストから削除", role: .destructive) {
                        Task { await viewModel.removePlan(entry, alsoRemovingIngredients: true) }
                    }
                    Button("献立だけ削除", role: .destructive) {
                        Task { await viewModel.removePlan(entry, alsoRemovingIngredients: false) }
                    }
                } else {
                    Button("削除", role: .destructive) {
                        Task { await viewModel.removePlan(entry, alsoRemovingIngredients: false) }
                    }
                }
                Button("キャンセル", role: .cancel) {}
            } message: { entry in
                if entry.ingredientsAddedAt != nil {
                    Text("「\(entry.recipeName)」を削除します。追加済みの材料も買い物リストから削除しますか？(未購入のみ・他の献立で使う材料は残します)")
                } else {
                    Text("「\(entry.recipeName)」を削除しますか？")
                }
            }
            .confirmationDialog(
                "献立をすべて削除",
                isPresented: $isConfirmingClearAll,
                titleVisibility: .visible
            ) {
                if viewModel.hasAddedIngredients {
                    Button("材料も買い物リストから削除", role: .destructive) {
                        Task { await viewModel.removeAllPlans(alsoRemovingIngredients: true) }
                    }
                    Button("献立だけ削除", role: .destructive) {
                        Task { await viewModel.removeAllPlans(alsoRemovingIngredients: false) }
                    }
                } else {
                    Button("すべて削除", role: .destructive) {
                        Task { await viewModel.removeAllPlans(alsoRemovingIngredients: false) }
                    }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                if viewModel.hasAddedIngredients {
                    Text("表示中の献立をすべて削除します。追加済みの材料も買い物リストから削除しますか？(未購入のみ・購入済みは残します)")
                } else {
                    Text("表示中の献立をすべて削除します。")
                }
            }
        }
    }

    /// 削除確認ダイアログの表示状態。閉じたら対象をクリアする
    private var deleteTargetBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private var infoBinding: Binding<Bool> {
        Binding(
            get: { viewModel.infoMessage != nil },
            set: { if !$0 { viewModel.infoMessage = nil } }
        )
    }

    // MARK: - 日ごとのセクション

    @ViewBuilder
    private func daySection(for date: Date) -> some View {
        let dayEntries = viewModel.entries(on: date)
        Section {
            if dayEntries.isEmpty {
                Text("予定なし")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            ForEach(dayEntries) { entry in
                planRow(for: entry)
            }
        } header: {
            HStack {
                Text(Self.dayTitle(for: date))
                Spacer()
                Button {
                    pickTarget = PickTarget(date: date)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("\(Self.dayTitle(for: date))に献立を追加")
            }
        }
    }

    /// 日付が過ぎたのに材料を追加していない献立をまとめて表示するセクション。
    /// 各行には過ぎた日付を添えて、いつの予定だったか分かるようにする。
    @ViewBuilder
    private var pastPendingSection: some View {
        Section {
            ForEach(viewModel.pastPendingEntries) { entry in
                planRow(for: entry, dateLabel: Self.pastDayLabel(for: entry.date))
            }
        } header: {
            Text("未処理")
        } footer: {
            Text("日付が過ぎたのに材料を買い物リストへ追加していない献立です。追加するか削除してください。")
        }
    }

    /// 献立1件の行(日ごとのセクション・未処理セクション共用)。
    /// `dateLabel` を渡すと過ぎた日付を行に表示する。
    @ViewBuilder
    private func planRow(for entry: MealPlanEntry, dateLabel: String? = nil) -> some View {
        PlanRow(entry: entry, dateLabel: dateLabel) {
            Task { await viewModel.addIngredients(for: entry) }
        } onEditServings: {
            editServingsTarget = entry
        } onShowDetail: {
            detailTarget = entry
        }
        .swipeActions {
            Button(role: .destructive) {
                deleteTarget = entry
            } label: {
                Label("削除", systemImage: "trash")
            }
            // 材料を買い物リストへ追加済みの献立は、編集してもリストへ反映されないため
            // 混乱を避けて編集を出さない(材料の確認はタップで引き続き可能)
            if entry.ingredientsAddedAt == nil {
                Button {
                    editRecipeTarget = entry
                } label: {
                    Label("編集", systemImage: "square.and.pencil")
                }
                .tint(.blue)
            }
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d(E)"
        return formatter
    }()

    private static func dayTitle(for date: Date) -> String {
        let label = dayFormatter.string(from: date)
        if Calendar.current.isDateInToday(date) { return "今日 \(label)" }
        if Calendar.current.isDateInTomorrow(date) { return "明日 \(label)" }
        return label
    }

    /// 未処理セクションの行に添える、過ぎた日付のラベル("yyyy-MM-dd" キー → "M/d(E)")
    private static func pastDayLabel(for dateKey: String) -> String? {
        guard let date = MealPlannerViewModel.date(fromKey: dateKey) else { return nil }
        return dayFormatter.string(from: date)
    }
}

// MARK: - 献立の行

private struct PlanRow: View {
    let entry: MealPlanEntry
    /// 過ぎた日付のラベル(未処理セクションで表示)。nil のときは表示しない
    var dateLabel: String? = nil
    let onAddIngredients: () -> Void
    let onEditServings: () -> Void
    let onShowDetail: () -> Void

    /// 人数表示。編集可否で見た目を変えないよう、ボタン内でも静的表示でも共用する
    private var servingsLabel: some View {
        Label("\(entry.servingsOrDefault)人前", systemImage: "person.2.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.recipeEmoji)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                if let dateLabel {
                    Text(dateLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(entry.recipeName)
                // 追加済み(材料展開済み)の献立は人数も編集不可にして静的表示にする。
                // 未追加のときだけタップで人数編集シートを開く
                if entry.ingredientsAddedAt == nil {
                    Button(action: onEditServings) {
                        servingsLabel
                    }
                    .buttonStyle(.borderless)   // 行全体へのタップ拡散を防ぐ
                    .accessibilityLabel("\(entry.recipeName)の人数を変更(現在\(entry.servingsOrDefault)人前)")
                } else {
                    servingsLabel
                }
            }

            Spacer()

            if entry.ingredientsAddedAt != nil {
                Label("追加済み", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button(action: onAddIngredients) {
                    Image(systemName: "cart.badge.plus")
                }
                .buttonStyle(.borderless)   // 行全体へのタップ拡散を防ぐ
                .accessibilityLabel("\(entry.recipeName)の材料を買い物リストへ追加")
            }
        }
        // 行(内側の borderless ボタン以外)をタップで材料確認シートを開く
        .contentShape(Rectangle())
        .onTapGesture(perform: onShowDetail)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("材料を確認")
    }
}

// MARK: - おすすめの行

/// 提案レシピ1件。旬の食材やよく買う食材を理由として添える
private struct SuggestionRow: View {
    let suggestion: MealSuggester.Suggestion

    var body: some View {
        HStack(spacing: 12) {
            Text(suggestion.recipe.emoji)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.recipe.name)
                    .foregroundStyle(.primary)
                if let reason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            // 旬の食材が理由なら葉アイコン、好みだけなら sparkles
            if suggestion.seasonalMatches.isEmpty {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            } else {
                Image(systemName: "leaf.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    /// 提案理由。旬を優先して表示し、無ければよく買う食材を添える
    private var reason: String? {
        if !suggestion.seasonalMatches.isEmpty {
            return "旬の \(Self.names(suggestion.seasonalMatches)) を使う"
        }
        if !suggestion.matchedIngredients.isEmpty {
            return "よく買う \(Self.names(suggestion.matchedIngredients)) を使う"
        }
        return nil
    }

    /// 理由に載せる食材名(最大3件、以降は「ほか」)
    private static func names(_ names: [String]) -> String {
        let shown = names.prefix(3).joined(separator: "・")
        return names.count > 3 ? "\(shown) ほか" : shown
    }
}

// MARK: - 人数編集シート

/// 追加済みの献立の人数を変更する小さなシート
private struct ServingsEditSheet: View {
    let entry: MealPlanEntry
    let onSave: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var servings: Int

    init(entry: MealPlanEntry, onSave: @escaping (Int) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _servings = State(initialValue: entry.servingsOrDefault)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $servings, in: MealPlannerViewModel.servingsRange) {
                        HStack {
                            Text("人数")
                            Spacer()
                            Text("\(servings)人前")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("\(entry.recipeEmoji) \(entry.recipeName)")
                } footer: {
                    if entry.ingredientsAddedAt != nil {
                        Text("追加済みの材料(未購入)の数量も、新しい人数に合わせて自動調整します。")
                    }
                }
            }
            .navigationTitle("人数を変更")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(servings)
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 材料確認シート

/// 献立に入れたレシピの材料を確認するシート。
/// 数量は買い物リストへ展開するときと同じ比率(レシピの基準人数 → 献立の人数)で
/// スケールして表示する。レシピが削除済みのときは確認できない旨を表示する。
private struct MealPlanDetailSheet: View {
    let viewModel: MealPlannerViewModel
    let entry: MealPlanEntry

    @Environment(\.dismiss) private var dismiss
    /// 材料編集シート(レシピ編集)の表示状態
    @State private var isEditing = false

    /// 献立エントリに対応する最新のレシピ。編集後は同期で自動的に反映される
    private var recipe: Recipe? { viewModel.recipe(for: entry) }

    var body: some View {
        NavigationStack {
            Group {
                if let recipe {
                    ingredientsList(for: recipe)
                } else {
                    ContentUnavailableView(
                        "レシピが見つかりません",
                        systemImage: "book.closed",
                        description: Text("このレシピは削除されたため、材料を表示・編集できません。")
                    )
                }
            }
            .navigationTitle("\(recipe?.emoji ?? entry.recipeEmoji) \(recipe?.name ?? entry.recipeName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 追加済みの献立は編集を出さない(編集してもリストへ反映されないため)
                if recipe != nil, entry.ingredientsAddedAt == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("編集") { isEditing = true }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(isPresented: $isEditing) {
                if let recipe {
                    RecipeEditSheet(title: "材料を編集", recipe: recipe) { name, emoji, ingredients, memo, baseServings in
                        viewModel.updateRecipe(recipe, name: name, emoji: emoji,
                                               ingredients: ingredients, memo: memo, baseServings: baseServings)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func ingredientsList(for recipe: Recipe) -> some View {
        List {
            Section {
                if recipe.ingredients.isEmpty {
                    Text("材料が登録されていません")
                        .foregroundStyle(.secondary)
                }
                ForEach(recipe.ingredients) { ingredient in
                    HStack {
                        Text(ingredient.name)
                        Spacer()
                        if let quantity = scaledQuantity(ingredient, in: recipe) {
                            Text(quantity)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("\(entry.servingsOrDefault)人前の材料")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if recipe.baseServingsOrDefault != entry.servingsOrDefault {
                        Text("数量はレシピの基準(\(recipe.baseServingsOrDefault)人前)から\(entry.servingsOrDefault)人前に合わせて調整して表示しています。")
                    }
                    if entry.ingredientsAddedAt != nil {
                        Text("この献立は材料を買い物リストへ追加済みのため、材料は編集できません。")
                    }
                }
            }

            if let memo = recipe.memo, !memo.isEmpty {
                Section("メモ") {
                    Text(memo)
                }
            }
        }
    }

    /// 材料の数量を献立の人数に合わせてスケールする(展開時と同じ計算)
    private func scaledQuantity(_ ingredient: RecipeIngredient, in recipe: Recipe) -> String? {
        IngredientScaler.scale(ingredient.quantity,
                               from: recipe.baseServingsOrDefault,
                               to: entry.servingsOrDefault)
    }
}

/// レシピが削除済みの献立で編集を試みたときに表示する案内シート
private struct RecipeUnavailableSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "レシピが見つかりません",
                systemImage: "book.closed",
                description: Text("このレシピは削除されたため、材料を編集できません。")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

// MARK: - レシピ選択シート

private struct RecipePickerSheet: View {
    let viewModel: MealPlannerViewModel
    /// 日付を選び直せるか(「日付を選んで追加」から開いたとき true)
    let allowsDateSelection: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var isShowingNewRecipe = false
    @State private var searchText = ""
    /// 追加する献立の人数(選んだレシピすべてに適用する)
    @State private var servings = MealPlanEntry.defaultServings
    /// 追加先の日付。allowsDateSelection のときはシート内の DatePicker で変更できる
    @State private var selectedDate: Date

    init(viewModel: MealPlannerViewModel, date: Date, allowsDateSelection: Bool = false) {
        self.viewModel = viewModel
        self.allowsDateSelection = allowsDateSelection
        _selectedDate = State(initialValue: date)
    }

    /// レシピ帳のレシピ(検索で絞り込み)
    private var myRecipes: [Recipe] { filtered(viewModel.recipes) }
    /// アプリ内蔵の定番レシピ(すでに登録済みの同名は除外・検索で絞り込み)
    private var catalog: [Recipe] { filtered(viewModel.catalogCandidates) }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if allowsDateSelection {
                    Section {
                        DatePicker("日付", selection: $selectedDate,
                                   in: Calendar.current.startOfDay(for: Date())...,
                                   displayedComponents: .date)
                            .environment(\.locale, Locale(identifier: "ja_JP"))
                    } footer: {
                        Text("選んだレシピをこの日付で献立に追加します。")
                    }
                }

                Section {
                    Stepper(value: $servings, in: MealPlannerViewModel.servingsRange) {
                        HStack {
                            Text("人数")
                            Spacer()
                            Text("\(servings)人前")
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("選んだレシピをこの人数で献立に追加します。追加後も変更できます。")
                }

                // 提案は好み・旬に基づくので、検索中は隠して検索結果に集中させる
                if !isSearching && !viewModel.suggestions.isEmpty {
                    Section("おすすめ") {
                        ForEach(viewModel.suggestions) { suggestion in
                            Button {
                                viewModel.selectRecipe(suggestion.recipe, on: selectedDate, servings: servings)
                                dismiss()
                            } label: {
                                SuggestionRow(suggestion: suggestion)
                            }
                        }
                    }
                }

                if !myRecipes.isEmpty {
                    Section("マイレシピ") {
                        ForEach(myRecipes) { recipe in
                            recipeButton(recipe, subtitle: "材料 \(recipe.ingredients.count)品")
                        }
                    }
                }

                if !catalog.isEmpty {
                    Section {
                        ForEach(catalog) { recipe in
                            recipeButton(recipe, subtitle: ingredientSummary(recipe))
                        }
                    } header: {
                        Text("いろいろな料理から選ぶ")
                    } footer: {
                        Text("選ぶと自動でマイレシピに登録され、材料を買い物リストへ追加できます。")
                    }
                }

                if isSearching && myRecipes.isEmpty && catalog.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .searchable(text: $searchText, prompt: "料理名・食材で検索")
            // シートを開くたびに直近の購入履歴から提案を再生成する
            .task { await viewModel.generateSuggestions() }
            .navigationTitle("レシピを選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingNewRecipe = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("レシピを追加")
                }
            }
            .sheet(isPresented: $isShowingNewRecipe) {
                RecipeEditSheet(title: "レシピを追加", recipe: nil) { name, emoji, ingredients, memo, baseServings in
                    viewModel.addRecipe(name: name, emoji: emoji, ingredients: ingredients,
                                        memo: memo, baseServings: baseServings)
                }
            }
        }
    }

    /// レシピ1件のボタン行(マイレシピ・定番レシピ共用)。選ぶと献立に追加して閉じる
    @ViewBuilder
    private func recipeButton(_ recipe: Recipe, subtitle: String) -> some View {
        Button {
            viewModel.selectRecipe(recipe, on: selectedDate, servings: servings)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(recipe.emoji)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recipe.name)
                        .foregroundStyle(.primary)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// 料理名または材料名で絞り込む(検索語が空ならそのまま返す)
    private func filtered(_ recipes: [Recipe]) -> [Recipe] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return recipes }
        return recipes.filter { recipe in
            recipe.name.localizedCaseInsensitiveContains(query)
                || recipe.ingredients.contains { $0.name.localizedCaseInsensitiveContains(query) }
        }
    }

    /// 定番レシピの補足行(主な材料を先頭3件まで)
    private func ingredientSummary(_ recipe: Recipe) -> String {
        let names = recipe.ingredients.prefix(3).map(\.name).joined(separator: "・")
        return recipe.ingredients.count > 3 ? "\(names) ほか" : names
    }
}
