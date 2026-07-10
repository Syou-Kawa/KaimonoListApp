import SwiftUI

/// カテゴリの追加・編集・並び替え・削除。
/// 変更は Firestore 経由で共有メンバー全員に即時同期される
struct CategoryManageView: View {
    let viewModel: ShoppingListViewModel

    @State private var isShowingAddSheet = false
    @State private var editingCategory: ItemCategory?

    var body: some View {
        List {
            Section {
                ForEach(viewModel.categories) { category in
                    Button {
                        editingCategory = category
                    } label: {
                        HStack(spacing: 12) {
                            Text(category.emoji)
                                .font(.title3)
                            Text(category.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .onMove { source, destination in
                    viewModel.moveCategory(from: source, to: destination)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        viewModel.deleteCategory(viewModel.categories[index])
                    }
                }
            } footer: {
                Text("「編集」から、よく行くお店の売り場順にドラッグで並び替えられます。タップで名前とアイコンを変更。削除したカテゴリのアイテムは「未分類」に移動します。")
            }
        }
        .navigationTitle("カテゴリ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("カテゴリを追加")
            }
        }
        .sheet(isPresented: $isShowingAddSheet) {
            CategoryEditSheet(title: "カテゴリを追加", name: "", emoji: "🛒") { name, emoji in
                viewModel.addCategory(name: name, emoji: emoji)
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $editingCategory) { category in
            CategoryEditSheet(title: "カテゴリを編集", name: category.name, emoji: category.emoji) { name, emoji in
                viewModel.updateCategory(category, name: name, emoji: emoji)
            }
            .presentationDetents([.medium])
        }
    }
}

// MARK: - 追加・編集シート(共用)

private struct CategoryEditSheet: View {
    let title: String
    let onSave: (_ name: String, _ emoji: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var emoji: String

    init(title: String, name: String, emoji: String,
         onSave: @escaping (_ name: String, _ emoji: String) -> Void) {
        self.title = title
        self.onSave = onSave
        _name = State(initialValue: name)
        _emoji = State(initialValue: emoji)
    }

    private static let presetEmojis = [
        "🥬", "🥩", "🐟", "🥚", "🍞", "🍚", "🧂", "🥫",
        "🧊", "🥤", "🍪", "🧻", "🍱", "🍰", "🌶️", "🧀",
        "🍜", "🧴", "🐶", "👶", "💊", "🍺", "☕️", "🛒",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("名前") {
                    TextField("例:ペット用品", text: $name)
                }

                Section("アイコン") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 8) {
                        ForEach(Self.presetEmojis, id: \.self) { preset in
                            Button {
                                emoji = preset
                            } label: {
                                Text(preset)
                                    .font(.title2)
                                    .padding(6)
                                    .background(
                                        emoji == preset ? Color.accentColor.opacity(0.2) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    TextField("絵文字キーボードから直接入力もOK", text: $emoji)
                        .onChange(of: emoji) { _, newValue in
                            // 最後の1文字(絵文字1つ)だけを保持
                            if newValue.count > 1 {
                                emoji = String(newValue.suffix(1))
                            }
                        }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(name, emoji)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
