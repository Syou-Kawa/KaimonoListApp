import SwiftUI
import Observation
import FirebaseFirestore

/// 食べた記録(献立の振り返り)の状態管理。
/// 献立プランナー(MealPlannerViewModel)が今日以降＋直近しか保持しないのに対し、
/// こちらは「日付が過ぎた過去の献立」を月単位で取得して振り返れるようにする。
/// ◀▶・年月ピッカーで任意の月へジャンプでき、遠い過去も素早く辿れる。
/// 読み取り専用(記録の閲覧のみ)なので、リアルタイム監視はせず都度取得する。
@MainActor
@Observable
final class MealHistoryViewModel {

    // MARK: - 状態

    /// 選択中の月(月初の Date)。◀▶ や年月ピッカーで切り替える
    private(set) var selectedMonth: Date
    /// 選択中の月の記録(date 降順)
    private(set) var entries: [MealPlanEntry] = []
    /// 材料確認用のレシピ表(recipeId → Recipe)。初回に一度だけ取得する
    private(set) var recipesById: [String: Recipe] = [:]
    /// レシピ帳のレシピ(createdAt 順)。記録追加シートのレシピ選択に使う
    private(set) var recipes: [Recipe] = []
    /// 選択中の月の読み込み中
    private(set) var isLoading = false
    /// レシピ表を取得済みか(.task の多重実行を防ぐ)
    private(set) var hasLoadedRecipes = false
    var errorMessage: String?
    /// 「○/○に記録しました」などの操作フィードバック
    var infoMessage: String?

    // MARK: - 依存

    let householdId: String
    let currentUid: String
    let currentUserName: String
    private let db = Firestore.firestore()

    private var householdRef: DocumentReference {
        db.collection("households").document(householdId)
    }
    private var recipesRef: CollectionReference { householdRef.collection("recipes") }
    private var plansRef: CollectionReference { householdRef.collection("mealPlans") }

    init(householdId: String, currentUid: String, currentUserName: String) {
        self.householdId = householdId
        self.currentUid = currentUid
        self.currentUserName = currentUserName
        self.selectedMonth = Self.startOfMonth(Date())
    }

    // MARK: - 読み込み

    /// 初回表示時に呼ぶ。レシピ表を一度だけ取得し、選択中の月(既定は今月)の記録を読み込む。
    func loadInitial() async {
        if !hasLoadedRecipes {
            hasLoadedRecipes = true
            await loadRecipes()
        }
        await loadSelectedMonth()
    }

    /// 引き下げ更新。レシピ表と選択中の月を取り直す。
    func reload() async {
        await loadRecipes()
        await loadSelectedMonth()
    }

    /// 材料確認に使うレシピ表を取得する。失敗しても致命的ではない(材料が見られないだけ)。
    private func loadRecipes() async {
        do {
            let snapshot = try await recipesRef.order(by: "createdAt").getDocuments()
            let loaded = snapshot.documents.compactMap { try? $0.data(as: Recipe.self) }
            recipes = loaded
            recipesById = Dictionary(
                loaded.compactMap { recipe in recipe.id.map { ($0, recipe) } },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            // 退出・世帯切り替え時の権限エラーは自然に起きるので警告しない
            if !error.isFirestorePermissionDenied {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 選択中の月の記録を新しい順(date 降順)に取得する。
    /// 「記録」は今日より前のみ扱うため、今月を見ているときは今日以降(まだ食べていない予定)を除く。
    /// `date` 単一フィールドの範囲＋並び替えなので複合インデックスは不要。
    func loadSelectedMonth() async {
        isLoading = true
        defer { isLoading = false }

        let calendar = Calendar.current
        let monthStart = selectedMonth
        let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        let todayStart = calendar.startOfDay(for: Date())
        // 今月を見ているときは今日以降を除く(記録は今日より前のみ)
        let upperBound = min(nextMonthStart, todayStart)
        guard monthStart < upperBound else {
            // 未来の月など、記録がありえない範囲は空にする
            entries = []
            return
        }

        do {
            let snapshot = try await plansRef
                .whereField("date", isGreaterThanOrEqualTo: MealPlannerViewModel.dateKey(monthStart))
                .whereField("date", isLessThan: MealPlannerViewModel.dateKey(upperBound))
                .order(by: "date", descending: true)
                .getDocuments()
            entries = snapshot.documents.compactMap { try? $0.data(as: MealPlanEntry.self) }
        } catch {
            if !error.isFirestorePermissionDenied {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - 月の移動

    /// これ以上新しい月(今月より先)へは進めない(未来は記録がないため)
    var canGoToNextMonth: Bool {
        selectedMonth < Self.startOfMonth(Date())
    }

    func goToPreviousMonth() async {
        selectedMonth = Calendar.current.date(byAdding: .month, value: -1, to: selectedMonth) ?? selectedMonth
        await loadSelectedMonth()
    }

    func goToNextMonth() async {
        guard canGoToNextMonth else { return }
        selectedMonth = Calendar.current.date(byAdding: .month, value: 1, to: selectedMonth) ?? selectedMonth
        await loadSelectedMonth()
    }

    /// 指定した日付が属する月へジャンプする(未来の月は今月に丸める)
    func jump(to date: Date) async {
        let target = Self.startOfMonth(date)
        selectedMonth = min(target, Self.startOfMonth(Date()))
        await loadSelectedMonth()
    }

    /// その日付が属する月の1日(月初)を返す
    static func startOfMonth(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// 履歴エントリに対応するレシピ。削除済みなら nil(材料確認シートで使用)
    func recipe(for entry: MealPlanEntry) -> Recipe? {
        recipesById[entry.recipeId]
    }

    // MARK: - 事後記録(食べたものをあとから記録する)

    /// レシピ帳にまだ無い「定番レシピ」。記録追加シートの「いろいろな料理」欄に使う。
    /// すでに同名レシピを登録済みのものは重複を避けて除外する。
    var catalogCandidates: [Recipe] {
        let registered = Set(recipes.map { MealSuggester.normalize($0.name) })
        return RecipeCatalog.all.filter { !registered.contains(MealSuggester.normalize($0.name)) }
    }

    /// 選んだレシピを指定日の献立(記録)として保存する。
    /// カタログ由来(まだ Firestore に無い)なら先にレシピ帳へ保存してから記録する。
    /// 保存後は一覧を取り直し、記録した日を操作フィードバックとして知らせる。
    func addRecord(recipe: Recipe, on date: Date, servings: Int) async {
        let clamped = MealPlannerViewModel.clampedServings(servings)
        do {
            // 記録に使う recipeId を決める(カタログはレシピ帳へマテリアライズ)
            let recipeId = try await resolvedRecipeId(for: recipe)
            let entry = MealPlanEntry(
                id: nil,
                date: MealPlannerViewModel.dateKey(date),
                recipeId: recipeId,
                recipeName: recipe.name,
                recipeEmoji: recipe.emoji,
                addedByUid: currentUid,
                servings: clamped,
                createdAt: nil,          // サーバー時刻
                ingredientsAddedAt: nil
            )
            _ = try plansRef.addDocument(from: entry)
            // マテリアライズした新規レシピも材料確認できるようレシピ表を取り直し、
            // 記録した日の月へ移動して一覧を更新する(その記録が見えるように)
            await loadRecipes()
            await jump(to: date)
            // 今日の分は「記録(過去)」ではなく献立タブの今日に入るので、その旨を伝える
            infoMessage = Calendar.current.isDateInToday(date)
                ? "今日の献立に追加しました(「献立」タブに表示されます)"
                : "\(Self.recordedDateLabel(for: date))に記録しました"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 記録に使うレシピの Firestore ドキュメントIDを返す。
    /// レシピ帳のレシピはそのID、カタログ由来は同名があれば再利用し、無ければ保存して採番する。
    private func resolvedRecipeId(for recipe: Recipe) async throws -> String {
        guard RecipeCatalog.isCatalog(recipe) else {
            if let id = recipe.id { return id }
            throw NSError(domain: "MealHistory", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "レシピを特定できませんでした"])
        }
        let key = MealSuggester.normalize(recipe.name)
        if let existing = recipes.first(where: { MealSuggester.normalize($0.name) == key }),
           let id = existing.id {
            return id
        }
        // id / createdAt はサーバー採番に任せるため、合成値を外した新規レシピを保存する
        let newRecipe = Recipe(
            id: nil,
            name: recipe.name,
            emoji: recipe.emoji,
            ingredients: recipe.ingredients,
            memo: recipe.memo,
            createdAt: nil
        )
        let ref = try recipesRef.addDocument(from: newRecipe)
        return ref.documentID
    }

    /// 記録完了メッセージ用の日付ラベル("今日" / "昨日" / "M/d(E)")
    private static func recordedDateLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今日" }
        if calendar.isDateInYesterday(date) { return "昨日" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d(E)"
        return formatter.string(from: date)
    }
}

// MARK: - 食べた記録の画面

/// 過去の献立(食べたもの)を新しい順に振り返る画面。日付ごとにまとめて表示し、
/// タップで材料を確認できる。読み取り専用で、献立の追加・削除は行わない。
struct MealHistoryView: View {
    @State private var viewModel: MealHistoryViewModel
    /// 材料確認シートの対象。nil = 非表示
    @State private var detailTarget: MealPlanEntry?
    /// 記録追加シートの表示状態
    @State private var isAddingRecord = false
    /// 年月ピッカー(任意の月へジャンプ)の表示状態
    @State private var isPickingMonth = false
    /// カレンダーで選択中の日("yyyy-MM-dd")。nil のときはその月の最新記録日を既定選択にする
    @State private var selectedDateKey: String?

    init(householdId: String, currentUid: String, currentUserName: String) {
        _viewModel = State(initialValue: MealHistoryViewModel(
            householdId: householdId,
            currentUid: currentUid,
            currentUserName: currentUserName
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.entries.isEmpty {
                    ProgressView()
                } else {
                    calendarContent
                }
            }
            // 月が変わったら選択日をリセットし、その月の最新記録日を既定選択に戻す
            .onChange(of: viewModel.selectedMonth) { _, _ in selectedDateKey = nil }
            // 月ナビ(◀ 年月 ▶)を上部に固定して、任意の月へ素早く移動できるようにする
            .safeAreaInset(edge: .top, spacing: 0) { monthNavigator }
            .navigationTitle("食べた記録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingRecord = true
                    } label: {
                        Label("記録する", systemImage: "plus")
                    }
                    .accessibilityLabel("食べたものを記録する")
                }
            }
            .task { await viewModel.loadInitial() }
            .refreshable { await viewModel.reload() }
            .sheet(isPresented: $isAddingRecord) {
                RecordAddSheet(viewModel: viewModel)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $isPickingMonth) {
                MonthPickerSheet(selectedMonth: viewModel.selectedMonth) { month in
                    Task { await viewModel.jump(to: month) }
                }
                .presentationDetents([.medium])
            }
            .sheet(item: $detailTarget) { entry in
                MealHistoryDetailSheet(viewModel: viewModel, entry: entry)
                    .presentationDetents([.medium, .large])
            }
            .alert("エラー", isPresented: errorBinding) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .alert("記録", isPresented: infoBinding) {
                Button("OK") { viewModel.infoMessage = nil }
            } message: {
                Text(viewModel.infoMessage ?? "")
            }
        }
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

    // MARK: - カレンダー表示

    /// 月のカレンダーと、選択した日の記録を縦に並べたスクロール本体。
    private var calendarContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                MonthCalendarGrid(
                    month: viewModel.selectedMonth,
                    entriesByDay: entriesByDay,
                    selectedKey: displayKey
                ) { key in
                    selectedDateKey = key
                }
                Divider()
                selectedDaySection
            }
            .padding()
        }
    }

    /// 選択中の日(displayKey)の記録一覧。記録が無い日は「記録なし」を示す。
    @ViewBuilder
    private var selectedDaySection: some View {
        if let key = displayKey {
            let dayEntries = entriesByDay[key] ?? []
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.sectionTitle(for: key))
                    .font(.headline)
                if dayEntries.isEmpty {
                    Text("この日は記録がありません")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(dayEntries) { entry in
                        Button {
                            detailTarget = entry
                        } label: {
                            HistoryRow(entry: entry)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("材料を確認")
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // その月に記録が1件も無い
            VStack(spacing: 8) {
                Text("この月は記録がありません")
                    .foregroundStyle(.secondary)
                Button("記録する") { isAddingRecord = true }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        }
    }

    /// 選択中の日("yyyy-MM-dd")。ユーザーが日をタップしていればその日、
    /// 未選択ならその月の最新記録日(記録が無ければ nil)。
    private var displayKey: String? {
        selectedDateKey ?? viewModel.entries.first?.date
    }

    /// 取得済みの記録を日付キーごとにまとめる(その日の複数品をまとめて持つ)
    private var entriesByDay: [String: [MealPlanEntry]] {
        Dictionary(grouping: viewModel.entries, by: { $0.date })
    }

    // MARK: - 月ナビ(◀ 年月 ▶)

    /// 上部に固定する月の移動バー。◀▶で前後の月へ、中央の年月をタップで年月ピッカーを開く。
    private var monthNavigator: some View {
        HStack {
            Button {
                Task { await viewModel.goToPreviousMonth() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("前の月")

            Spacer()

            Button {
                isPickingMonth = true
            } label: {
                HStack(spacing: 6) {
                    Text(Self.monthTitle(viewModel.selectedMonth))
                        .font(.headline)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.primary)
            }
            .accessibilityLabel("月を選ぶ(現在 \(Self.monthTitle(viewModel.selectedMonth)))")

            Spacer()

            Button {
                Task { await viewModel.goToNextMonth() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .disabled(!viewModel.canGoToNextMonth)
            .accessibilityLabel("次の月")
        }
        .padding(.horizontal, 8)
        .background(.bar)
    }

    private static func monthTitle(_ date: Date) -> String {
        monthFormatter.string(from: date)
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月"
        return formatter
    }()

    // MARK: - 日付見出し

    /// セクション見出し("yyyy-MM-dd" キー → 「昨日 M/d(E)」/「M/d(E)」/古い年は「yyyy/M/d(E)」)
    private static func sectionTitle(for key: String) -> String {
        guard let date = MealPlannerViewModel.date(fromKey: key) else { return key }
        let calendar = Calendar.current
        if calendar.isDateInYesterday(date) {
            return "昨日 \(dayFormatter.string(from: date))"
        }
        // 今年と違う年は年も添える(何年前の記録か分かるように)
        let isSameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        return (isSameYear ? dayFormatter : dayWithYearFormatter).string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d(E)"
        return formatter
    }()

    private static let dayWithYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/M/d(E)"
        return formatter
    }()
}

// MARK: - 月カレンダーグリッド

/// 月のカレンダー(7列)。記録のある日は薄い塗り＋その日の料理の絵文字を表示し、
/// 同じ日に複数品あれば件数バッジを付ける。選択中の日は枠で強調。
/// 日をタップすると onSelect(日付キー) を呼ぶ。
private struct MonthCalendarGrid: View {
    /// 表示する月(月初の Date)
    let month: Date
    /// 日付キー("yyyy-MM-dd")→ その日の記録
    let entriesByDay: [String: [MealPlanEntry]]
    /// 選択中の日付キー(枠で強調)
    let selectedKey: String?
    let onSelect: (String) -> Void

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    /// 曜日記号(index 0 = 日曜)。ロケールに依存せず日本語表記にする
    private static let baseWeekdaySymbols = ["日", "月", "火", "水", "木", "金", "土"]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(orderedWeekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(cells.indices, id: \.self) { index in
                    if let day = cells[index] {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 46)
                    }
                }
            }
        }
    }

    /// 先頭の空白(月初の曜日オフセット)＋ 1〜末日 を並べた配列(空白は nil)
    private var cells: [Int?] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: month)   // 1=日〜7=土
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + range.map { Optional($0) }
    }

    /// 週の開始曜日(firstWeekday)に合わせて並べ替えた曜日記号
    private var orderedWeekdaySymbols: [String] {
        let start = calendar.firstWeekday - 1
        return (0..<7).map { Self.baseWeekdaySymbols[($0 + start) % 7] }
    }

    @ViewBuilder
    private func dayCell(_ day: Int) -> some View {
        let key = dayKey(day)
        let dayEntries = entriesByDay[key] ?? []
        let hasRecords = !dayEntries.isEmpty
        let isSelected = key == selectedKey

        Button {
            onSelect(key)
        } label: {
            VStack(spacing: 2) {
                Text("\(day)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(dayEntries.first?.recipeEmoji ?? " ")
                    .font(.body)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.18)
                          : (hasRecords ? Color.accentColor.opacity(0.08) : Color.clear))
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if dayEntries.count > 1 {
                    Text("\(dayEntries.count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Circle().fill(Color.accentColor))
                        .padding(2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(day)日\(hasRecords ? "、記録\(dayEntries.count)件" : "、記録なし")")
    }

    /// その月の day 日の日付キー("yyyy-MM-dd")
    private func dayKey(_ day: Int) -> String {
        var components = calendar.dateComponents([.year, .month], from: month)
        components.day = day
        let date = calendar.date(from: components) ?? month
        return MealPlannerViewModel.dateKey(date)
    }
}

// MARK: - 記録の行

/// 食べた記録1件の行。料理の絵文字・名前・人数を表示する(日付はセクション見出し側)。
private struct HistoryRow: View {
    let entry: MealPlanEntry

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.recipeEmoji)
                .font(.title3)
            Text(entry.recipeName)
            Spacer()
            Label("\(entry.servingsOrDefault)人前", systemImage: "person.2.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 記録の材料確認シート

/// 過去の献立に入れた料理の材料を確認する読み取り専用シート。
/// 数量は買い物リストへ展開したときと同じ比率(レシピの基準人数 → 献立の人数)でスケールする。
/// レシピが削除済みのときは確認できない旨を表示する。
private struct MealHistoryDetailSheet: View {
    let viewModel: MealHistoryViewModel
    let entry: MealPlanEntry

    @Environment(\.dismiss) private var dismiss

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
                        description: Text("このレシピは削除されたため、材料を表示できません。")
                    )
                }
            }
            .navigationTitle("\(recipe?.emoji ?? entry.recipeEmoji) \(recipe?.name ?? entry.recipeName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
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
                if recipe.baseServingsOrDefault != entry.servingsOrDefault {
                    Text("数量はレシピの基準(\(recipe.baseServingsOrDefault)人前)から\(entry.servingsOrDefault)人前に合わせて調整して表示しています。")
                }
            }

            if let memo = recipe.memo, !memo.isEmpty {
                Section("メモ") {
                    Text(memo)
                }
            }
        }
    }

    /// 材料の数量を献立の人数に合わせてスケールする(買い物リストへの展開時と同じ計算)
    private func scaledQuantity(_ ingredient: RecipeIngredient, in recipe: Recipe) -> String? {
        IngredientScaler.scale(ingredient.quantity,
                               from: recipe.baseServingsOrDefault,
                               to: entry.servingsOrDefault)
    }
}

// MARK: - 記録追加シート(食べたものをあとから記録する)

/// 食べたものをあとから記録するシート。まず「いつ食べたか」を今日/昨日/一昨日の
/// クイックチップ(またはそれ以前の日付を DatePicker)で選び、次にレシピを選ぶと
/// その日の記録として保存する。事後記録は今日・昨日が大半なので最短で選べるようにする。
private struct RecordAddSheet: View {
    let viewModel: MealHistoryViewModel

    @Environment(\.dismiss) private var dismiss
    /// 記録する日(既定は今日)
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    /// 記録する人数
    @State private var servings = MealPlanEntry.defaultServings
    @State private var searchText = ""

    /// レシピ帳のレシピ(検索で絞り込み)
    private var myRecipes: [Recipe] { filtered(viewModel.recipes) }
    /// アプリ内蔵の定番レシピ(登録済みの同名は除外・検索で絞り込み)
    private var catalog: [Recipe] { filtered(viewModel.catalogCandidates) }
    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    quickDateChips
                    DatePicker("それ以前の日", selection: $selectedDate,
                               in: ...Calendar.current.startOfDay(for: Date()),
                               displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "ja_JP"))
                } header: {
                    Text("いつ食べた？")
                } footer: {
                    Text("食べた日を選んでからレシピを選ぶと、その日に記録します。")
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
                    Text("選んだレシピをこの人数で記録します。")
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
                        Text("選ぶと自動でマイレシピに登録されます。")
                    }
                }

                if isSearching && myRecipes.isEmpty && catalog.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .searchable(text: $searchText, prompt: "料理名・食材で検索")
            .navigationTitle("食べたものを記録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    /// 今日・昨日・一昨日のクイック日付チップ。タップでその日を選ぶ
    private var quickDateChips: some View {
        HStack(spacing: 8) {
            ForEach(Self.quickDates, id: \.label) { item in
                let isSelected = Calendar.current.isDate(selectedDate, inSameDayAs: item.date)
                Button {
                    selectedDate = item.date
                } label: {
                    Text(item.label)
                        .font(.subheadline)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                        .background(isSelected ? Color.accentColor : Color(.secondarySystemBackground),
                                    in: Capsule())
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
    }

    /// クイックチップの候補(今日・昨日・一昨日)
    private static var quickDates: [(label: String, date: Date)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return [
            ("今日", today),
            ("昨日", calendar.date(byAdding: .day, value: -1, to: today) ?? today),
            ("一昨日", calendar.date(byAdding: .day, value: -2, to: today) ?? today),
        ]
    }

    /// レシピ1件のボタン行。選ぶと記録して閉じる
    @ViewBuilder
    private func recipeButton(_ recipe: Recipe, subtitle: String) -> some View {
        Button {
            Task { await viewModel.addRecord(recipe: recipe, on: selectedDate, servings: servings) }
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

// MARK: - 年月ピッカーシート(任意の月へジャンプ)

/// 年と月をホイールで選んで、その月へジャンプするシート。
/// 遠い過去の月へも一気に移動できるようにする。未来の月は表示側で今月に丸める。
private struct MonthPickerSheet: View {
    let selectedMonth: Date
    let onSelect: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var year: Int
    @State private var month: Int

    init(selectedMonth: Date, onSelect: @escaping (Date) -> Void) {
        self.selectedMonth = selectedMonth
        self.onSelect = onSelect
        let calendar = Calendar.current
        _year = State(initialValue: calendar.component(.year, from: selectedMonth))
        _month = State(initialValue: calendar.component(.month, from: selectedMonth))
    }

    /// 選べる年の範囲(過去5年〜今年)
    private var years: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((current - 5)...current)
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                Picker("年", selection: $year) {
                    ForEach(years, id: \.self) { Text("\(String($0))年").tag($0) }
                }
                .pickerStyle(.wheel)
                Picker("月", selection: $month) {
                    ForEach(1...12, id: \.self) { Text("\($0)月").tag($0) }
                }
                .pickerStyle(.wheel)
            }
            .navigationTitle("月を選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("表示") {
                        var components = DateComponents()
                        components.year = year
                        components.month = month
                        components.day = 1
                        if let date = Calendar.current.date(from: components) {
                            onSelect(date)
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}
