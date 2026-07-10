import SwiftUI

/// 献立プランナーのメイン画面。今日から7日分の献立表を表示し、
/// 各日にレシピを割り当てて材料を買い物リストへ展開できる
struct MealPlanView: View {
    @State private var viewModel: MealPlannerViewModel
    @State private var pickTarget: PickTarget?

    /// sheet(item:) に渡すためのラッパー(Date は Identifiable ではないので)
    private struct PickTarget: Identifiable {
        let date: Date
        var id: String { MealPlannerViewModel.dateKey(date) }
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
                            Task { await viewModel.addAllPendingIngredients() }
                        } label: {
                            Label("今週の材料をまとめてリストへ", systemImage: "cart.badge.plus")
                        }
                    } footer: {
                        Text("同じ品名がすでに未購入リストにある材料は追加されません(数量の合算はしません)。")
                    }
                }

                ForEach(viewModel.weekDates, id: \.self) { date in
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
            }
            .sheet(item: $pickTarget) { target in
                RecipePickerSheet(viewModel: viewModel, date: target.date)
                    .presentationDetents([.medium, .large])
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
                PlanRow(entry: entry) {
                    Task { await viewModel.addIngredients(for: entry) }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        viewModel.removePlan(entry)
                    } label: {
                        Label("削除", systemImage: "trash")
                    }
                }
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
}

// MARK: - 献立の行

private struct PlanRow: View {
    let entry: MealPlanEntry
    let onAddIngredients: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.recipeEmoji)
                .font(.title3)
            Text(entry.recipeName)

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
    }
}

// MARK: - レシピ選択シート

private struct RecipePickerSheet: View {
    let viewModel: MealPlannerViewModel
    let date: Date

    @Environment(\.dismiss) private var dismiss
    @State private var isShowingNewRecipe = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.recipes.isEmpty {
                    ContentUnavailableView {
                        Label("レシピがありません", systemImage: "book")
                    } description: {
                        Text("まずは定番メニューを登録しましょう")
                    } actions: {
                        Button("レシピを作る") { isShowingNewRecipe = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List(viewModel.recipes) { recipe in
                        Button {
                            viewModel.addPlan(recipe: recipe, on: date)
                            dismiss()
                        } label: {
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
                            }
                        }
                    }
                }
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
                RecipeEditSheet(title: "レシピを追加", recipe: nil) { name, emoji, ingredients, memo in
                    viewModel.addRecipe(name: name, emoji: emoji, ingredients: ingredients, memo: memo)
                }
            }
        }
    }
}
