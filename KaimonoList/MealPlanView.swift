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
    /// AI 献立アシスタントのシートの表示状態
    @State private var isShowingAI = false
    /// 上部の日付ストリップで選択中の日(ハイライト表示に使用)。"yyyy-MM-dd" キー
    @State private var selectedDateKey: String?
    /// 初回表示で今日の位置までスクロール済みか。
    /// 月初(1日)から表示するため、今日が中旬でも開いた直後に今日が見えるようにする
    @State private var didScrollToToday = false

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
            ScrollViewReader { proxy in
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
                // 日付ストリップを上部に固定する。
                // iOS 26 では safeAreaBar を使うと「スクロール端エフェクトを拡張」するため、
                // 中身がバーの裏を流れるとシステム標準の透ける効果が出て、リスト・共有タブの
                // ヘッダーと同じ見た目になる。iOS 26 未満は safeAreaInset+マテリアルにフォールバック。
                .modifier(CalendarBar { dateStrip(proxy: proxy) })
                // 初回表示で今日のセクションへスクロールする(月初からの過去日で今日が隠れないように)
                .onAppear {
                    guard !didScrollToToday else { return }
                    didScrollToToday = true
                    let todayId = Self.sectionId(
                        forKey: MealPlannerViewModel.dateKey(Calendar.current.startOfDay(for: Date()))
                    )
                    DispatchQueue.main.async {
                        proxy.scrollTo(todayId, anchor: .top)
                    }
                }
            }
            .navigationTitle("献立")
            .navigationBarTitleDisplayMode(.inline)
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
                        // AI 献立支援は対応端末(iOS 26+ / Apple Intelligence)でのみ出す
                        if viewModel.isAIAvailable {
                            Button("AIにおまかせ", systemImage: "sparkles") {
                                isShowingAI = true
                            }
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
            .sheet(isPresented: $isShowingAI) {
                MealAISheet(viewModel: viewModel)
                    .presentationDetents([.large])
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
            .onAppear {
                viewModel.startListening()
                // 日付ストリップの初期選択を今日にする
                if selectedDateKey == nil {
                    selectedDateKey = MealPlannerViewModel.dateKey(Calendar.current.startOfDay(for: Date()))
                }
            }
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
                    Text("今日以降の献立をすべて削除します(過去日の記録は残します)。追加済みの材料も買い物リストから削除しますか？(未購入のみ・購入済みは残します)")
                } else {
                    Text("今日以降の献立をすべて削除します(過去日の記録は残します)。")
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

    // MARK: - 日付ストリップ(横スクロールで日付を選んでジャンプ)

    /// リスト上部に固定する横スクロールの日付ストリップ。
    /// タップでその日のセクションへスクロールし、献立のある日にはドット印を付ける。
    private func dateStrip(proxy: ScrollViewProxy) -> some View {
        ScrollViewReader { stripProxy in
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(viewModel.planDates, id: \.self) { date in
                            let key = MealPlannerViewModel.dateKey(date)
                            Button {
                                selectedDateKey = key
                                // セクション側はチップと id が衝突しないようプレフィックス付き
                                withAnimation { proxy.scrollTo(Self.sectionId(forKey: key), anchor: .top) }
                            } label: {
                                DateChip(date: date,
                                         hasEntries: !viewModel.entries(on: date).isEmpty,
                                         isSelected: selectedDateKey == key)
                            }
                            .buttonStyle(.plain)
                            .id(key)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                // チップ行(カレンダー)だけを角丸パネルで区切る。
                // バー全体(= 半透明ナビバーの裏まで)に敷くとヘッダー全体が塗られてしまうため、
                // チップ行に限定した角丸背景にして左右に余白を取り、カレンダー領域だけを強調する。
                // 背景はシステム適応色にして、ダークモードでも日付の文字(.primary)が
                // 背景と同化せず読めるようにする(純白固定だとダークで白地に白文字になる)。
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                // パネルを少し浮かせる控えめな影(ライト/ダーク両方で自然に見える黒の薄影)。
                .shadow(color: Color.black.opacity(0.12), radius: 5)
                .padding(.horizontal, 12)
                // カレンダー上部にほんの少しだけ余白を足す
                .padding(.top, 4)
                .padding(.bottom, 6)
            }
            // 選択中の日をストリップ内でも見える位置へ寄せる
            .onChange(of: selectedDateKey) { _, newValue in
                guard let newValue else { return }
                withAnimation { stripProxy.scrollTo(newValue, anchor: .center) }
            }
        }
    }

    // MARK: - 日ごとのセクション

    @ViewBuilder
    private func daySection(for date: Date) -> some View {
        let dayEntries = viewModel.entries(on: date)
        // 日付見出しを「別セクションの1行」にする。
        // scrollTo の着地先はセクションの中身になるため、見出しを(同じセクションの)ヘッダーに
        // 置くと上へ押し出されて隠れてしまう。見出しを独立したセクションの行にして id を付けると、
        // ジャンプ時に日付見出しが画面上部に見える位置で必ず止まる。
        // 背景を透明にしてグループ背景を見せ、従来のヘッダー(グレー地のラベル)の見た目を保つ。
        // 献立フォームを別セクションに分けることで、白いカードの角丸がきれいに出る。
        Section {
            HStack {
                Text(Self.dayTitle(for: date))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    pickTarget = PickTarget(date: date)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("\(Self.dayTitle(for: date))に献立を追加")
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 4, trailing: 20))
            // 上部の日付ストリップからのジャンプ先(scrollTo の対象)。
            // ストリップのチップと id が衝突しないようプレフィックスを付ける。
            .id(Self.sectionId(forKey: MealPlannerViewModel.dateKey(date)))
        }
        // 見出しと直下の献立カードを近づける(セクション間の既定の広い余白を詰める)
        .listSectionSpacing(0)

        Section {
            if dayEntries.isEmpty {
                Text("予定なし")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            ForEach(dayEntries) { entry in
                // 今日より前の日(=今月の過去日)の献立は「記録」として読み取り専用で表示する
                planRow(for: entry, isRecord: Self.isPastDay(date))
            }
        }
    }

    /// その日付が今日より前(=今月の過去日)か。過去日の献立は「記録」扱いにする
    private static func isPastDay(_ date: Date) -> Bool {
        Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: Date())
    }

    /// 日付セクションの scrollTo 用 id。ストリップのチップ(日付キーそのまま)と区別する
    private static func sectionId(forKey key: String) -> String { "section-\(key)" }

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
    /// `isRecord` が true のとき「記録」として読み取り専用表示にする(今月の過去日)。
    @ViewBuilder
    private func planRow(for entry: MealPlanEntry, dateLabel: String? = nil,
                         isRecord: Bool = false) -> some View {
        PlanRow(entry: entry, dateLabel: dateLabel, isRecord: isRecord) {
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
            // 記録(過去日)、および材料を追加済みの献立は編集を出さない。
            // 追加済みは編集してもリストへ反映されず、記録は振り返り用途のため混乱を避ける
            // (材料の確認はタップで引き続き可能)
            if !isRecord && entry.ingredientsAddedAt == nil {
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
    /// 「記録」(今月の過去日)として読み取り専用表示にするか。
    /// true のとき人数編集・カート追加は出さず、「記録済み」バッジを表示する。
    var isRecord: Bool = false
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
                // 記録(過去日)は人数を静的表示にする。
                // 追加済み(材料展開済み)も編集不可にして静的表示にする。
                // 未追加のときだけタップで人数編集シートを開く
                if isRecord || entry.ingredientsAddedAt != nil {
                    servingsLabel
                } else {
                    Button(action: onEditServings) {
                        servingsLabel
                    }
                    .buttonStyle(.borderless)   // 行全体へのタップ拡散を防ぐ
                    .accessibilityLabel("\(entry.recipeName)の人数を変更(現在\(entry.servingsOrDefault)人前)")
                }
            }

            Spacer()

            if isRecord {
                // 今月の過去日は「記録」タブに残っていることを示すバッジ
                Label("記録済み", systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("記録に保存済み")
            } else if entry.ingredientsAddedAt != nil {
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

// MARK: - カレンダーバーの取り付け

/// 日付ストリップを上部に固定して取り付けるモディファイア。
/// iOS 26 では safeAreaBar でスクロール端エフェクトを拡張し、中身がバーの裏を流れて
/// システム標準の“透ける”効果になる(他タブのヘッダーと同じ見た目)。
/// iOS 26 未満は safeAreaInset + バー用マテリアルにフォールバックする。
private struct CalendarBar<Bar: View>: ViewModifier {
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .top, spacing: 0, content: bar)
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) {
                bar().background(.bar)
            }
        }
    }
}

// MARK: - 日付チップ

/// 日付ストリップの1日分(カレンダー風)。曜日を上に、日付の数字を丸で表示し、
/// 献立がある日は下にドットを付ける。選択中は数字を塗り丸、今日は淡い丸で示す。
private struct DateChip: View {
    let date: Date
    /// その日に献立があるか(ドット表示の有無)
    let hasEntries: Bool
    /// ストリップ内で選択中か(数字を塗り丸で強調)
    let isSelected: Bool

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    var body: some View {
        VStack(spacing: 4) {
            Text(Self.weekdayFormatter.string(from: date))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(Self.dayFormatter.string(from: date))
                .font(.system(size: 17, weight: isSelected ? .bold : .regular))
                .foregroundStyle(numberForeground)
                .frame(width: 32, height: 32)
                .background {
                    if isSelected {
                        Circle().fill(Color.accentColor)
                    } else if isToday {
                        Circle().fill(Color.accentColor.opacity(0.15))
                    }
                }
            Circle()
                .frame(width: 5, height: 5)
                .foregroundStyle(Color.accentColor)
                .opacity(hasEntries ? 1 : 0)
        }
        .frame(width: 42)
    }

    private var numberForeground: Color {
        if isSelected { return .white }
        return isToday ? .accentColor : .primary
    }

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "E"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "d"
        return formatter
    }()
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

// MARK: - AI 献立アシスタント(端末内 Foundation Models・対応端末のみ)

/// 栄養バランスのアドバイスと、数日分の献立のまとめ提案を AI に依頼できるシート。
/// 端末内で処理するため購入履歴や献立が外部に送られることはない。
private struct MealAISheet: View {
    let viewModel: MealPlannerViewModel

    @Environment(\.dismiss) private var dismiss
    /// まとめ提案の日数
    @State private var days = 3
    /// 提案を献立へ追加するときの人数
    @State private var servings = MealPlanEntry.defaultServings

    /// 提案を割り当てる基準日(今日)
    private var baseDate: Date { Calendar.current.startOfDay(for: Date()) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await viewModel.requestNutritionAdvice() }
                    } label: {
                        Label("これからの献立をチェック", systemImage: "heart.text.square")
                    }
                    .disabled(viewModel.isRunningAI)

                    if let advice = viewModel.aiAdvice {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(advice.summary)
                            ForEach(advice.tips, id: \.self) { tip in
                                Label(tip, systemImage: "leaf")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("栄養バランスのアドバイス")
                } footer: {
                    Text("これからの献立全体を見て、栄養の偏りをやさしく指摘します。カロリー等の数値は出しません。")
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
                    Text("提案を献立に追加するときの人数です。")
                }

                Section {
                    Stepper(value: $days, in: 2...7) {
                        HStack {
                            Text("日数")
                            Spacer()
                            Text("\(days)日分")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        Task { await viewModel.requestMealPlan(days: days) }
                    } label: {
                        Label("\(days)日分の献立を提案してもらう", systemImage: "sparkles")
                    }
                    .disabled(viewModel.isRunningAI)

                    if !viewModel.aiProposal.isEmpty {
                        ForEach(viewModel.aiProposal) { meal in
                            proposalRow(meal)
                        }
                        Button {
                            viewModel.acceptAllProposals(from: baseDate, servings: servings)
                            dismiss()
                        } label: {
                            Label("すべて献立に追加", systemImage: "calendar.badge.plus")
                        }
                    }
                } header: {
                    Text("数日分の献立をAIに提案")
                } footer: {
                    Text("好み・旬・栄養の偏りを考えて、今日から順に提案します。各行の「追加」でその日に入れられます。")
                }

                if viewModel.isRunningAI {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("AIが考えています…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let message = viewModel.aiMessage {
                    Section {
                        Text(message)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("AIにおまかせ")
            .navigationBarTitleDisplayMode(.inline)
            // シートを開くたびに前回の結果をクリアする(古い献立に対する結果が残らないように)
            .onAppear { viewModel.resetAIResults() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    /// まとめ提案1件の行。タップでその日の献立に追加する。
    @ViewBuilder
    private func proposalRow(_ meal: MealAIAssistant.ProposedMeal) -> some View {
        let date = Calendar.current.date(byAdding: .day, value: meal.dayOffset, to: baseDate) ?? baseDate
        Button {
            viewModel.acceptProposal(meal, on: date, servings: servings)
        } label: {
            HStack(spacing: 12) {
                Text(meal.recipe.emoji)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(Self.dayLabel(date))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(meal.recipe.name)
                            .foregroundStyle(.primary)
                    }
                    if let reason = meal.reason {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Image(systemName: "plus.circle")
                    .foregroundStyle(.tint)
            }
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d(E)"
        return formatter
    }()

    private static func dayLabel(_ date: Date) -> String {
        dayFormatter.string(from: date)
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
                                   in: MealPlannerViewModel.currentMonthDateRange(),
                                   displayedComponents: .date)
                            .environment(\.locale, Locale(identifier: "ja_JP"))
                    } footer: {
                        Text("選んだレシピをこの日付で献立に追加します。追加できるのは今月内の日付です。")
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

                // 旬の食材で新しいレシピを創作する(対応端末のみ・検索中は隠す)
                if viewModel.isAIAvailable && !isSearching {
                    Section {
                        Button {
                            Task { await viewModel.requestInventedRecipe() }
                        } label: {
                            Label("旬の食材でAIにレシピを作ってもらう", systemImage: "sparkles")
                        }
                        .disabled(viewModel.isRunningAI)

                        if viewModel.isRunningAI {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("AIが考えています…")
                                    .foregroundStyle(.secondary)
                            }
                        } else if let message = viewModel.aiMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let invented = viewModel.aiInventedRecipe {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(invented.emoji)
                                    Text(invented.name)
                                        .font(.headline)
                                }
                                Text("材料:" + invented.ingredients.map(\.name).joined(separator: "、"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let memo = invented.memo, !memo.isEmpty {
                                    Text(memo)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 2)

                            Button {
                                viewModel.acceptInventedRecipe(invented, on: selectedDate, servings: servings)
                                dismiss()
                            } label: {
                                Label("この料理を献立に追加", systemImage: "plus.circle")
                            }
                        }
                    } header: {
                        Text("AIにレシピを作ってもらう")
                    } footer: {
                        Text("今の旬の食材を使った新しい料理を1品考えます。追加すると自動でマイレシピに登録されます。")
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
            // シートを開くたびに直近の購入履歴から提案を再生成する。
            // 前回の AI 生成結果(創作レシピ)が残らないようクリアもする
            // (栄養アドバイス・数日分提案は別シートのものなので消さない)。
            .task {
                viewModel.clearInventedRecipe()
                await viewModel.generateSuggestions()
            }
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
