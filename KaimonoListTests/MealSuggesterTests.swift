import Testing
@testable import KaimonoList

/// MealSuggester の献立提案スコアリングの検証。
/// 購入履歴(好み)を多く含むレシピが上位に来ること、除外・上限が正しく効くことを確認する。
@MainActor
struct MealSuggesterTests {

    // MARK: - テスト用のレシピ生成

    private func recipe(id: String, name: String, ingredients: [String]) -> Recipe {
        Recipe(
            id: id,
            name: name,
            emoji: "🍽️",
            ingredients: ingredients.map { RecipeIngredient(name: $0, quantity: nil) },
            memo: nil,
            createdAt: nil
        )
    }

    // MARK: - 正規化

    @Test("normalize は前後空白を除去し小文字化する")
    func normalizeTrimsAndLowercases() {
        #expect(MealSuggester.normalize("  Milk  ") == "milk")
        #expect(MealSuggester.normalize("牛乳") == "牛乳")
    }

    // MARK: - スコア順

    @Test("好み食材を多く含むレシピほど上位に来る")
    func ranksByPreferenceScore() {
        let recipes = [
            recipe(id: "a", name: "肉じゃが", ingredients: ["じゃがいも", "牛肉", "玉ねぎ"]),
            recipe(id: "b", name: "冷奴", ingredients: ["豆腐"]),
        ]
        // じゃがいも・牛肉・玉ねぎをよく買う世帯
        let counts = ["じゃがいも": 5, "牛肉": 3, "玉ねぎ": 4, "豆腐": 1]

        let result = MealSuggester.suggest(
            recipes: recipes, preferenceCounts: counts, excludedRecipeIds: [], limit: 5
        )

        #expect(result.count == 2)
        #expect(result.first?.id == "a")           // 5+3+4=12 で最上位
        #expect(result.first?.score == 12)
        #expect(result.last?.id == "b")            // 1
    }

    @Test("好みに一致した材料が理由として記録される")
    func recordsMatchedIngredients() {
        let recipes = [recipe(id: "a", name: "サラダ", ingredients: ["レタス", "トマト", "謎の食材"])]
        let counts = ["レタス": 2, "トマト": 1]

        let result = MealSuggester.suggest(
            recipes: recipes, preferenceCounts: counts, excludedRecipeIds: [], limit: 5
        )

        #expect(result.first?.matchedIngredients == ["レタス", "トマト"])
    }

    @Test("双方向の部分一致でマッチする(牛乳 ⊂ 低脂肪牛乳)")
    func matchesBySubstring() {
        let recipes = [recipe(id: "a", name: "シチュー", ingredients: ["牛乳"])]
        let counts = ["低脂肪牛乳": 3]   // 履歴側が長い名前でもマッチ

        let result = MealSuggester.suggest(
            recipes: recipes, preferenceCounts: counts, excludedRecipeIds: [], limit: 5
        )

        #expect(result.first?.score == 3)
    }

    // MARK: - 除外・上限・空入力

    @Test("excludedRecipeIds のレシピは提案されない")
    func excludesGivenRecipes() {
        let recipes = [
            recipe(id: "a", name: "肉じゃが", ingredients: ["じゃがいも"]),
            recipe(id: "b", name: "カレー", ingredients: ["じゃがいも"]),
        ]
        let counts = ["じゃがいも": 5]

        let result = MealSuggester.suggest(
            recipes: recipes, preferenceCounts: counts, excludedRecipeIds: ["a"], limit: 5
        )

        #expect(result.map(\.id) == ["b"])
    }

    @Test("スコア0(好みに一致しない)のレシピは含めない")
    func excludesZeroScore() {
        let recipes = [recipe(id: "a", name: "謎料理", ingredients: ["謎の食材"])]
        let counts = ["じゃがいも": 5]

        let result = MealSuggester.suggest(
            recipes: recipes, preferenceCounts: counts, excludedRecipeIds: [], limit: 5
        )

        #expect(result.isEmpty)
    }

    @Test("limit を超えて返さない")
    func respectsLimit() {
        let recipes = (1...10).map { recipe(id: "\($0)", name: "料理\($0)", ingredients: ["米"]) }
        let counts = ["米": 1]

        let result = MealSuggester.suggest(
            recipes: recipes, preferenceCounts: counts, excludedRecipeIds: [], limit: 3
        )

        #expect(result.count == 3)
    }

    @Test("履歴が空なら提案は空")
    func emptyHistoryReturnsEmpty() {
        let recipes = [recipe(id: "a", name: "肉じゃが", ingredients: ["じゃがいも"])]

        let result = MealSuggester.suggest(
            recipes: recipes, preferenceCounts: [:], excludedRecipeIds: [], limit: 5
        )

        #expect(result.isEmpty)
    }

    @Test("レシピが空なら提案は空")
    func emptyRecipesReturnsEmpty() {
        let result = MealSuggester.suggest(
            recipes: [], preferenceCounts: ["じゃがいも": 5], excludedRecipeIds: [], limit: 5
        )

        #expect(result.isEmpty)
    }
}
