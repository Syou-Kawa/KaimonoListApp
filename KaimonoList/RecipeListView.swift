import SwiftUI

/// レシピ帳。追加・編集・削除は Firestore 経由で共有メンバー全員に即時同期される
struct RecipeListView: View {
    let viewModel: MealPlannerViewModel

    @State private var isShowingAddSheet = false
    @State private var editingRecipe: Recipe?

    var body: some View {
        Group {
            if viewModel.recipes.isEmpty {
                ContentUnavailableView(
                    "レシピがありません",
                    systemImage: "book",
                    description: Text("右上の + から定番メニューを登録しましょう")
                )
            } else {
                List {
                    Section {
                        ForEach(viewModel.recipes) { recipe in
                            Button {
                                editingRecipe = recipe
                            } label: {
                                RecipeRow(recipe: recipe)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    viewModel.deleteRecipe(recipe)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                        }
                    } footer: {
                        Text("タップで編集。レシピを削除しても、すでに献立表に入っている分の表示は残ります。")
                    }
                }
            }
        }
        .navigationTitle("レシピ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("レシピを追加")
            }
        }
        .sheet(isPresented: $isShowingAddSheet) {
            RecipeEditSheet(title: "レシピを追加", recipe: nil) { name, emoji, ingredients, memo in
                viewModel.addRecipe(name: name, emoji: emoji, ingredients: ingredients, memo: memo)
            }
        }
        .sheet(item: $editingRecipe) { recipe in
            RecipeEditSheet(title: "レシピを編集", recipe: recipe) { name, emoji, ingredients, memo in
                viewModel.updateRecipe(recipe, name: name, emoji: emoji,
                                       ingredients: ingredients, memo: memo)
            }
        }
    }
}

// MARK: - 行

private struct RecipeRow: View {
    let recipe: Recipe

    var body: some View {
        HStack(spacing: 12) {
            Text(recipe.emoji)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.name)
                    .foregroundStyle(.primary)
                Text("材料 \(recipe.ingredients.count)品")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "pencil")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 追加・編集シート(共用。RecipePickerSheet からも使う)

struct RecipeEditSheet: View {
    let title: String
    let onSave: (_ name: String, _ emoji: String,
                 _ ingredients: [RecipeIngredient], _ memo: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var emoji: String
    @State private var ingredients: [RecipeIngredient]
    @State private var memo: String

    init(title: String, recipe: Recipe?,
         onSave: @escaping (_ name: String, _ emoji: String,
                            _ ingredients: [RecipeIngredient], _ memo: String) -> Void) {
        self.title = title
        self.onSave = onSave
        _name = State(initialValue: recipe?.name ?? "")
        _emoji = State(initialValue: recipe?.emoji ?? "🍽️")
        // 新規作成時は空の材料行を1つ用意しておく(すぐ入力を始められるように)
        _ingredients = State(initialValue: recipe?.ingredients ?? [RecipeIngredient(name: "")])
        _memo = State(initialValue: recipe?.memo ?? "")
    }

    private static let presetEmojis = [
        "🍛", "🍝", "🍜", "🍲", "🥘", "🍳", "🥗", "🍣",
        "🍤", "🥟", "🍔", "🍕", "🐟", "🥩", "🍗", "🍚",
        "🥪", "🌮", "🍢", "🥞", "🍙", "🥧", "🍰", "🍽️",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("料理名") {
                    TextField("例:カレーライス", text: $name)
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
                }

                Section {
                    ForEach($ingredients) { $ingredient in
                        HStack {
                            TextField("材料名(例:じゃがいも)", text: $ingredient.name)
                            TextField("数量", text: Binding(
                                get: { $ingredient.quantity.wrappedValue ?? "" },
                                set: { $ingredient.quantity.wrappedValue = $0.isEmpty ? nil : $0 }
                            ))
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { indexSet in
                        ingredients.remove(atOffsets: indexSet)
                    }

                    Button {
                        ingredients.append(RecipeIngredient(name: ""))
                    } label: {
                        Label("材料を追加", systemImage: "plus.circle")
                    }
                } header: {
                    Text("材料")
                } footer: {
                    Text("材料名は買い物リストの品名になります(カテゴリは自動推定)。スワイプで行を削除。")
                }

                Section("メモ") {
                    TextField("例:子どもの分は辛さ控えめ", text: $memo, axis: .vertical)
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
                        onSave(name, emoji, ingredients, memo)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
