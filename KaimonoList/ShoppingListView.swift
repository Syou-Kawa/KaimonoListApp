import SwiftUI

struct ShoppingListView: View {
    @State private var viewModel: ShoppingListViewModel
    @State private var isShowingAddSheet = false

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
                }
                .sheet(isPresented: $isShowingAddSheet) {
                    AddItemSheet(viewModel: viewModel)
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
        }
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
        } else {
            List {
                // 未購入(カテゴリ = 売り場順)
                ForEach(viewModel.uncheckedGroups) { group in
                    Section {
                        ForEach(group.items) { item in
                            ItemRow(item: item) {
                                viewModel.toggleChecked(item)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    viewModel.delete(item)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text(group.title)
                    }
                }

                // 購入済み
                if !viewModel.checkedItems.isEmpty {
                    Section("購入済み") {
                        ForEach(viewModel.checkedItems) { item in
                            ItemRow(item: item) {
                                viewModel.toggleChecked(item)
                            }
                        }
                        Button("購入済みをまとめて削除", role: .destructive) {
                            viewModel.clearChecked()
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

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isChecked ? Color.green : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .strikethrough(item.isChecked)
                        .foregroundStyle(item.isChecked ? .secondary : .primary)
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
        }
        .buttonStyle(.plain)
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
        }
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

    /// 追加後はシートを閉じずにフォームをリセットして連続入力できるようにする
    /// (買い物リストは一度に複数追加するケースが多いため)
    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        viewModel.addItem(name: trimmed, categoryId: selectedCategoryId, quantity: quantity)
        name = ""
        quantity = ""
        selectedCategoryId = viewModel.defaultCategoryId
        lastAutoCategoryId = viewModel.defaultCategoryId
        isNameFocused = true
    }
}
