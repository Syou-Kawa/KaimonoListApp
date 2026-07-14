import SwiftUI

struct ShoppingListView: View {
    @State private var viewModel: ShoppingListViewModel
    @State private var isShowingAddSheet = false
    @State private var isConfirmingClearUnchecked = false
    @State private var editingItem: ShoppingItem?
    @State private var searchText = ""
    /// チェック(購入)時に触覚フィードバックを鳴らすためのトリガ。値が変わると再生される
    @State private var checkFeedbackTrigger = 0

    init(householdId: String, currentUid: String, currentUserName: String) {
        _viewModel = State(initialValue: ShoppingListViewModel(
            householdId: householdId,
            currentUid: currentUid,
            currentUserName: currentUserName
        ))
    }

    var body: some View {
        NavigationStack {
            listContent
                .navigationTitle("買い物リスト")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink {
                            CategoryManageView(viewModel: viewModel)
                        } label: {
                            Image(systemName: "tag")
                        }
                        .accessibilityLabel("カテゴリを編集")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isShowingAddSheet = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("アイテムを追加")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("未購入をすべて削除", systemImage: "trash", role: .destructive) {
                                isConfirmingClearUnchecked = true
                            }
                            .disabled(!hasUncheckedItems)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("その他の操作")
                    }
                }
                .sheet(isPresented: $isShowingAddSheet) {
                    AddItemSheet(viewModel: viewModel)
                        .presentationDetents([.medium, .large])
                }
                .sheet(item: $editingItem) { item in
                    EditItemSheet(viewModel: viewModel, item: item)
                        .presentationDetents([.medium, .large])
                }
                // 注意: onDisappear で stopListening しない。
                // NavigationStack でカテゴリ管理画面へ push すると
                // この画面の onDisappear が呼ばれ、同期が止まってしまうため。
                .onAppear { viewModel.startListening() }
                .alert("エラー", isPresented: errorBinding) {
                    Button("OK") { viewModel.errorMessage = nil }
                } message: {
                    Text(viewModel.errorMessage ?? "")
                }
                .confirmationDialog(
                    "未購入をすべて削除",
                    isPresented: $isConfirmingClearUnchecked,
                    titleVisibility: .visible
                ) {
                    Button("すべて削除", role: .destructive) {
                        viewModel.clearUnchecked()
                    }
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("未購入のアイテムをすべて削除します。購入済みは残ります。")
                }
                // 品名でリストを絞り込む(アイテムが増えても探しやすくする)
                .searchable(text: $searchText, prompt: "品名で検索")
                // 購入(チェックON)時に成功の触覚を鳴らす
                .sensoryFeedback(.success, trigger: checkFeedbackTrigger)
                // 一括削除の直後に表示する「元に戻す」トースト
                .overlay(alignment: .bottom) { undoToast }
                .animation(.default, value: viewModel.undoToast?.id)
        }
    }

    /// 一括削除を取り消すトースト。数秒後に自動で消える。
    @ViewBuilder
    private var undoToast: some View {
        if let toast = viewModel.undoToast {
            HStack(spacing: 12) {
                Text(toast.message)
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Button("元に戻す") {
                    viewModel.undoLastClear()
                }
                .fontWeight(.semibold)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.thinMaterial, in: Capsule())
            .background(Capsule().fill(Color.black.opacity(0.75)))
            .padding(.horizontal)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
            // 一定時間で自動的に閉じる(この toast.id が生きている間だけ待つ)
            .task(id: toast.id) {
                try? await Task.sleep(for: .seconds(5))
                if viewModel.undoToast?.id == toast.id {
                    viewModel.dismissUndoToast()
                }
            }
        }
    }

    /// 未購入アイテムが1件でもあるか(一括削除ボタンの活性判定)
    private var hasUncheckedItems: Bool {
        viewModel.items.contains { !$0.isChecked }
    }

    /// 検索中か(トリム後の検索文字列が空でない)
    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 検索文字列で絞り込んだ未購入グループ。空検索ならそのまま返す。
    private var filteredUncheckedGroups: [ShoppingListViewModel.CategoryGroup] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return viewModel.uncheckedGroups }
        return viewModel.uncheckedGroups.compactMap { group in
            let matched = group.items.filter { $0.name.localizedCaseInsensitiveContains(query) }
            guard !matched.isEmpty else { return nil }
            return ShoppingListViewModel.CategoryGroup(id: group.id, title: group.title, items: matched)
        }
    }

    /// 検索文字列で絞り込んだ購入済みアイテム。空検索ならそのまま返す。
    private var filteredCheckedItems: [ShoppingItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return viewModel.checkedItems }
        return viewModel.checkedItems.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// チェックの切り替え。購入(未チェック→チェック)のときだけ触覚を鳴らす。
    private func toggle(_ item: ShoppingItem) {
        if !item.isChecked { checkFeedbackTrigger += 1 }
        viewModel.toggleChecked(item)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    @ViewBuilder
    private var listContent: some View {
        if viewModel.items.isEmpty {
            ContentUnavailableView(
                "リストは空です",
                systemImage: "cart",
                description: Text("右上の + から買うものを追加しましょう")
            )
        } else if isSearching && filteredUncheckedGroups.isEmpty && filteredCheckedItems.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                // 未購入(カテゴリ = 売り場順)
                ForEach(filteredUncheckedGroups) { group in
                    Section {
                        ForEach(group.items) { item in
                            ItemRow(item: item) {
                                toggle(item)
                            } onEdit: {
                                editingItem = item
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    viewModel.delete(item)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                                Button {
                                    editingItem = item
                                } label: {
                                    Label("編集", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                    } header: {
                        Text(group.title)
                    }
                }

                // 購入済み
                if !filteredCheckedItems.isEmpty {
                    Section("購入済み") {
                        ForEach(filteredCheckedItems) { item in
                            ItemRow(item: item) {
                                toggle(item)
                            } onEdit: {
                                editingItem = item
                            }
                        }
                        // 検索中は表示中のものだけが対象と誤解されないよう、全件削除ボタンは隠す
                        if !isSearching {
                            Button("購入済みをまとめて削除", role: .destructive) {
                                viewModel.clearChecked()
                            }
                        }
                    }
                }
            }
            .animation(.default, value: viewModel.items)
        }
    }
}

// MARK: - 行

private struct ItemRow: View {
    let item: ShoppingItem
    let onToggle: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // チェックの位置を押したときだけ購入済み/未購入を切り替える
            Button(action: onToggle) {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isChecked ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isChecked ? "未購入に戻す" : "購入済みにする")

            // 項目部分を押したときは編集シートを開く
            Button(action: onEdit) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .strikethrough(item.isChecked)
                            .foregroundStyle(item.isChecked ? .secondary : .primary)
                        if let recipeName = item.sourceRecipeName {
                            Label {
                                Text(recipeName)
                            } icon: {
                                Text(item.sourceRecipeEmoji ?? "🍽️")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Text(item.addedByName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    if let quantity = item.quantity {
                        Text(quantity)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 追加シート

private struct AddItemSheet: View {
    let viewModel: ShoppingListViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var quantity = ""
    @State private var selectedCategoryId: String?
    /// 直近の自動推定結果。「手動選択したかどうか」の判定に使う
    @State private var lastAutoCategoryId: String?
    /// 同名の未購入アイテムが既にある場合に確認ダイアログへ渡す品名。nil = 非表示
    @State private var duplicateWarningName: String?
    /// 「よく買うもの」チップでの追加時に触覚を鳴らすためのトリガ。値が変わると再生される
    @State private var quickAddFeedbackTrigger = 0
    @FocusState private var isNameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("品名(例:にんじん)", text: $name)
                    .focused($isNameFocused)
                    .submitLabel(.done)
                    .onSubmit(add)
                    .onChange(of: name) { _, newName in
                        applyGuess(for: newName)
                    }

                TextField("数量・メモ(例:2本)", text: $quantity)

                Picker("カテゴリ", selection: $selectedCategoryId) {
                    ForEach(viewModel.categories) { category in
                        Text("\(category.emoji) \(category.name)")
                            .tag(category.id)
                    }
                }

                // よく買うもの: 購入履歴からのワンタップ追加候補。
                // チップを左から詰めて折り返し、全候補を見渡せるようにする
                if !viewModel.frequentItems.isEmpty {
                    Section("よく買うもの") {
                        WrappingChips(items: viewModel.frequentItems, spacing: 8) { item in
                            Button {
                                viewModel.addFromFrequent(item)
                                quickAddFeedbackTrigger += 1
                            } label: {
                                Label(item.name, systemImage: "plus")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                        }
                    }
                }
            }
            .navigationTitle("アイテムを追加")
            .navigationBarTitleDisplayMode(.inline)
            // よく買うものからのワンタップ追加時に成功の触覚を鳴らす
            .sensoryFeedback(.success, trigger: quickAddFeedbackTrigger)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加", action: add)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if selectedCategoryId == nil {
                    selectedCategoryId = viewModel.defaultCategoryId
                    lastAutoCategoryId = viewModel.defaultCategoryId
                }
                isNameFocused = true
            }
            .confirmationDialog(
                "すでにリストにあります",
                isPresented: duplicateDialogBinding,
                titleVisibility: .visible
            ) {
                Button("それでも追加") {
                    if let dup = duplicateWarningName { commitAdd(dup) }
                }
                Button("キャンセル", role: .cancel) {
                    isNameFocused = true
                }
            } message: {
                Text("「\(duplicateWarningName ?? "")」は未購入のリストにあります。重複して追加しますか?")
            }
        }
    }

    private var duplicateDialogBinding: Binding<Bool> {
        Binding(
            get: { duplicateWarningName != nil },
            set: { if !$0 { duplicateWarningName = nil } }
        )
    }

    /// 手動でカテゴリを選んでいない間だけ、品名からの推定結果を反映する
    /// (現在の選択が「前回の自動設定値」と同じ = ユーザーは触っていない)
    private func applyGuess(for newName: String) {
        let guessId = viewModel.categoryId(forMatcherKey: CategoryGuesser.guessKey(from: newName))
            ?? viewModel.defaultCategoryId
        if selectedCategoryId == lastAutoCategoryId {
            selectedCategoryId = guessId
        }
        lastAutoCategoryId = guessId
    }

    /// 追加ボタン/確定時の入口。同名の未購入アイテムがあれば確認を挟み、
    /// なければそのまま追加する。
    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if viewModel.hasUncheckedItem(named: trimmed) {
            duplicateWarningName = trimmed
            return
        }
        commitAdd(trimmed)
    }

    /// 実際にアイテムを追加してフォームをリセットする。
    /// シートは閉じずに連続入力できるようにする(一度に複数追加するケースが多いため)。
    private func commitAdd(_ trimmed: String) {
        viewModel.addItem(name: trimmed, categoryId: selectedCategoryId, quantity: quantity)
        name = ""
        quantity = ""
        duplicateWarningName = nil
        selectedCategoryId = viewModel.defaultCategoryId
        lastAutoCategoryId = viewModel.defaultCategoryId
        isNameFocused = true
    }
}

// MARK: - 編集シート

/// 既にリストにあるアイテムの品名・数量・カテゴリをまとめて編集するシート。
private struct EditItemSheet: View {
    let viewModel: ShoppingListViewModel
    let item: ShoppingItem

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var quantity: String
    @State private var selectedCategoryId: String?
    /// 紐づける料理のレシピID。nil = 料理なし。
    @State private var selectedRecipeId: String?
    @FocusState private var isNameFocused: Bool

    init(viewModel: ShoppingListViewModel, item: ShoppingItem) {
        self.viewModel = viewModel
        self.item = item
        _name = State(initialValue: item.name)
        _quantity = State(initialValue: item.quantity ?? "")
        _selectedCategoryId = State(initialValue: item.categoryId)
        // アイテムには料理名しか持たないので、同名のレシピを選択の初期値にする
        // (該当レシピが無い/削除済みなら「なし」始まり)
        _selectedRecipeId = State(initialValue: viewModel.recipes
            .first(where: { $0.name == item.sourceRecipeName })?.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("品名(例:にんじん)", text: $name)
                    .focused($isNameFocused)
                    .submitLabel(.done)
                    .onSubmit(save)

                TextField("数量・メモ(例:2本)", text: $quantity)

                Picker("カテゴリ", selection: $selectedCategoryId) {
                    // どのカテゴリにも属さない選択肢
                    Text("❓ 未分類").tag(String?.none)
                    ForEach(viewModel.categories) { category in
                        Text("\(category.emoji) \(category.name)")
                            .tag(category.id)
                    }
                }

                // このアイテムがどの料理の材料かを紐づける(任意)
                if !viewModel.recipes.isEmpty {
                    Picker("料理", selection: $selectedRecipeId) {
                        Text("なし").tag(String?.none)
                        ForEach(viewModel.recipes) { recipe in
                            Text("\(recipe.emoji) \(recipe.name)")
                                .tag(recipe.id)
                        }
                    }
                }
            }
            .navigationTitle("アイテムを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let recipe = viewModel.recipes.first { $0.id == selectedRecipeId }
        viewModel.updateItem(item,
                             name: trimmed,
                             quantity: quantity,
                             categoryId: selectedCategoryId,
                             recipe: recipe)
        dismiss()
    }
}

// MARK: - チップの折り返し表示

/// 子要素を左から詰めて並べ、行の幅が足りなくなったら次の行へ折り返す表示。
/// Form / List の行内でも崩れないよう、実際の利用可能幅(GeometryReader)を読み、
/// 各要素の位置を alignmentGuide で計算する方式にしている。
/// 「よく買うもの」チップを画面幅に合わせて詰めて表示するために使う。
private struct WrappingChips<Item: Identifiable, Content: View>: View {
    let items: [Item]
    var spacing: CGFloat = 8
    @ViewBuilder let content: (Item) -> Content

    /// 折り返した結果の総高さ。測定して行の高さを確定させる(初期0 → 測定後に反映)。
    @State private var totalHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            generate(in: geo)
        }
        .frame(height: totalHeight)
    }

    private func generate(in geo: GeometryProxy) -> some View {
        var x: CGFloat = 0   // 現在行の使用済み幅(負値で累積)
        var y: CGFloat = 0   // 現在行の縦位置(負値で累積)
        return ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                content(item)
                    .padding(.trailing, spacing)
                    .padding(.bottom, spacing)
                    .alignmentGuide(.leading) { dimension in
                        // 残り幅に収まらなければ次の行へ折り返す
                        if abs(x - dimension.width) > geo.size.width {
                            x = 0
                            y -= dimension.height
                        }
                        let result = x
                        if item.id == items.last?.id {
                            x = 0   // 最後の要素の後は次回の描画に備えてリセット
                        } else {
                            x -= dimension.width
                        }
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = y
                        if item.id == items.last?.id {
                            y = 0
                        }
                        return result
                    }
            }
        }
        .background(heightReader)
    }

    /// ZStack の実高さを測って totalHeight に書き戻す(レイアウト後に反映)。
    private var heightReader: some View {
        GeometryReader { geo -> Color in
            let height = geo.size.height
            DispatchQueue.main.async { totalHeight = height }
            return Color.clear
        }
    }
}
