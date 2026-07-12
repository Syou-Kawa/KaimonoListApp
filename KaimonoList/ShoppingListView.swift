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
            }
            .navigationTitle("アイテムを追加")
            .navigationBarTitleDisplayMode(.inline)
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
    @FocusState private var isNameFocused: Bool

    init(viewModel: ShoppingListViewModel, item: ShoppingItem) {
        self.viewModel = viewModel
        self.item = item
        _name = State(initialValue: item.name)
        _quantity = State(initialValue: item.quantity ?? "")
        _selectedCategoryId = State(initialValue: item.categoryId)
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
        viewModel.updateItem(item, name: trimmed, quantity: quantity, categoryId: selectedCategoryId)
        dismiss()
    }
}
