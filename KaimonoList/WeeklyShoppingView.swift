import SwiftUI

/// まとめてリストに追加するビュー。今週(今日から7日分)の献立のうち、まだ買い物リストへ
/// 展開していない材料を品名で集約し、売り場(カテゴリ)順に一覧する。
/// 確認画面で材料の選択(チェック)・数量の書き換え・スワイプ除外を行い、
/// 下部の「まとめてリストに追加」で、選んだ材料だけを買い物リストへ追加できる。
struct WeeklyShoppingView: View {
    let viewModel: MealPlannerViewModel
    @Environment(\.dismiss) private var dismiss

    /// 画面表示中に編集できるよう、集約結果を一度だけローカル状態へ取り込む
    @State private var sections: [EditableSection] = []
    @State private var didLoad = false

    /// チェックの付いた(追加対象の)材料の総数
    private var selectedCount: Int {
        sections.reduce(0) { $0 + $1.items.filter(\.isSelected).count }
    }

    /// 表示中の材料の総品数(除外していない分)
    private var itemCount: Int {
        sections.reduce(0) { $0 + $1.items.count }
    }

    var body: some View {
        NavigationStack {
            Group {
                if itemCount == 0 {
                    ContentUnavailableView(
                        "追加できる材料はありません",
                        systemImage: "cart",
                        description: Text("今週の献立の材料はすべてリストへ追加済みか、まだ献立が登録されていません。")
                    )
                } else {
                    list
                }
            }
            .navigationTitle("まとめてリストに追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { addBar }
        }
        .task {
            // 表示のたびにリセットしないよう初回のみ集約結果を取り込む
            guard !didLoad else { return }
            sections = makeEditableSections()
            didLoad = true
        }
    }

    private var list: some View {
        List {
            Section {
                LabeledContent("料理", value: "\(viewModel.pendingEntryCount)品")
                LabeledContent("材料", value: "\(selectedCount)/\(itemCount)品目")
            } header: {
                Text("リストに追加する材料")
            } footer: {
                Text("チェックを外すと追加しません。数量は直接書き換えられます。左スワイプで材料を除外できます。")
            }

            ForEach($sections) { $section in
                if !section.items.isEmpty {
                    Section(section.title) {
                        ForEach($section.items) { $item in
                            EditableShoppingRow(item: $item)
                        }
                        .onDelete { offsets in
                            $section.items.wrappedValue.remove(atOffsets: offsets)
                        }
                    }
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text("同じ品名がすでに未購入リストにある材料は追加されません(数量の合算はしません)。数量は献立の人数に合わせて調整しています。")
            }
        }
    }

    /// 下部固定の一括追加ボタン。追加対象(チェック済み)が1件でもあるときだけ有効にする
    @ViewBuilder
    private var addBar: some View {
        if itemCount > 0 {
            Button {
                Task {
                    await addSelected()
                    dismiss()
                }
            } label: {
                Label("まとめてリストに追加", systemImage: "cart.badge.plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedCount == 0)
            .padding()
            .background(.bar)
        }
    }

    /// 集約結果(ViewModel)を、編集可能なローカルモデルへ変換する
    private func makeEditableSections() -> [EditableSection] {
        viewModel.weeklyShoppingSections().map { section in
            EditableSection(
                id: section.id,
                title: section.title,
                items: section.items.map { item in
                    // 出所の絵文字は先頭の料理から引く(買い物リストの由来表示に使う)
                    let emoji = viewModel.recipes.first { $0.name == item.recipeNames.first }?.emoji ?? "🍽️"
                    return EditableItem(
                        name: item.name,
                        quantity: item.quantities.joined(separator: "・"),
                        recipeNames: item.recipeNames,
                        recipeEmoji: emoji
                    )
                }
            )
        }
    }

    /// チェック済みの材料だけを、編集後の数量で買い物リストへ追加する
    private func addSelected() async {
        let selected = sections.flatMap(\.items).filter(\.isSelected)
        let edited = selected.map { item -> MealPlannerViewModel.EditedIngredient in
            let quantity = item.quantity.trimmingCharacters(in: .whitespaces)
            return MealPlannerViewModel.EditedIngredient(
                name: item.name,
                quantity: quantity.isEmpty ? nil : quantity,
                recipeName: item.recipeNames.first ?? "",
                recipeEmoji: item.recipeEmoji
            )
        }
        await viewModel.addSelectedWeeklyIngredients(edited)
    }
}

// MARK: - 編集可能なローカルモデル

/// 確認画面で編集できる材料のセクション(売り場カテゴリごと)
private struct EditableSection: Identifiable {
    let id: String
    let title: String
    var items: [EditableItem]
}

/// 確認画面で編集できる材料1件。チェックの有無と数量を変更できる
private struct EditableItem: Identifiable {
    let name: String
    var quantity: String
    let recipeNames: [String]
    let recipeEmoji: String
    var isSelected: Bool = true
    var id: String { name }
}

// MARK: - 材料の行

/// 集約した材料1件。チェック・品名・由来の料理名・編集可能な数量を表示する
private struct EditableShoppingRow: View {
    @Binding var item: EditableItem

    var body: some View {
        HStack(spacing: 12) {
            Button {
                item.isSelected.toggle()
            } label: {
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isSelected ? Color.accentColor : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(item.isSelected ? "\(item.name)を追加しない" : "\(item.name)を追加する")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .foregroundStyle(item.isSelected ? .primary : .secondary)
                if !item.recipeNames.isEmpty {
                    Text(item.recipeNames.joined(separator: "・"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            TextField("数量", text: $item.quantity)
                .multilineTextAlignment(.trailing)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 110)
                .disabled(!item.isSelected)
        }
    }
}
