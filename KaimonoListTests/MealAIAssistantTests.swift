import Testing
import Foundation
@testable import KaimonoList

/// MealAIAssistant の「モデル非依存の純粋ヘルパー」の検証。
/// 実際の AI 生成(LanguageModelSession)はシミュレータ/CI では使えない(isAvailable が false)ため、
/// ここでは重複判定・材料の整形・絵文字整形・プロンプト文脈の組み立てのみを確認する。
@MainActor
struct MealAIAssistantTests {

    // MARK: - isNovel(既存レシピとの重複判定)

    @Test("既存名と重複しないレシピ名は新しい(novel)と判定する")
    func novelWhenNotInExisting() {
        let existing: Set<String> = [MealSuggester.normalize("カレーライス")]
        #expect(MealAIAssistant.isNovel(name: "なすの揚げ浸し", existing: existing))
    }

    @Test("既存名と一致するレシピ名は新しくないと判定する(表記ゆれも吸収)")
    func notNovelWhenMatchesExisting() {
        let existing: Set<String> = [MealSuggester.normalize("カレーライス")]
        #expect(!MealAIAssistant.isNovel(name: "カレーライス", existing: existing))
        // normalize は前後空白除去 + 小文字化。空白違いでも重複扱いになる
        #expect(!MealAIAssistant.isNovel(name: " カレーライス ", existing: existing))
    }

    @Test("空名は novel とみなさない")
    func emptyNameNotNovel() {
        #expect(!MealAIAssistant.isNovel(name: "   ", existing: []))
    }

    // MARK: - cleanedIngredients(材料の整形)

    @Test("空名の材料を除外し、前後の空白を落とす")
    func cleanedIngredientsRemovesEmptyAndTrims() {
        let input = [
            RecipeIngredient(name: "  なす ", quantity: " 3本 "),
            RecipeIngredient(name: "   ", quantity: "1個"),
            RecipeIngredient(name: "豚こま肉", quantity: "  "),
        ]
        let result = MealAIAssistant.cleanedIngredients(input)

        #expect(result.count == 2)
        #expect(result[0].name == "なす")
        #expect(result[0].quantity == "3本")
        // 空白だけの数量は nil になる
        #expect(result[1].name == "豚こま肉")
        #expect(result[1].quantity == nil)
    }

    // MARK: - normalizedEmoji(絵文字の整形)

    @Test("絵文字は1文字に整え、空なら皿アイコンにフォールバックする")
    func normalizedEmojiTrimsAndFallsBack() {
        #expect(MealAIAssistant.normalizedEmoji(" 🍆 ") == "🍆")
        #expect(MealAIAssistant.normalizedEmoji("") == "🍽️")
        #expect(MealAIAssistant.normalizedEmoji("   ") == "🍽️")
    }

    // MARK: - プロンプト文脈の組み立て

    @Test("栄養アドバイスの文脈に料理名と旬食材が含まれる")
    func nutritionContextIncludesNamesAndSeason() {
        let context = MealAIAssistant.nutritionPromptContext(
            recipeNames: ["カレーライス", "焼き魚"],
            season: ["なす", "トマト"]
        )
        #expect(context.contains("カレーライス"))
        #expect(context.contains("焼き魚"))
        #expect(context.contains("なす"))
    }

    @Test("レシピ創作の文脈に旬食材と好み食材が含まれる")
    func inventContextIncludesSeasonAndPreferred() {
        let context = MealAIAssistant.inventPromptContext(
            season: ["さんま"],
            preferred: ["豚こま肉"]
        )
        #expect(context.contains("さんま"))
        #expect(context.contains("豚こま肉"))
    }

    @Test("数日分提案の文脈に日数・旬・最近作った料理が含まれる")
    func planContextIncludesDaysSeasonRecent() {
        let context = MealAIAssistant.planPromptContext(
            days: 3,
            existingRecipes: ["肉じゃが"],
            season: ["大根"],
            preferred: ["鶏もも肉"],
            recent: ["カレーライス"]
        )
        #expect(context.contains("3日分"))
        #expect(context.contains("大根"))
        #expect(context.contains("カレーライス"))
    }

    // MARK: - 可用性

    @Test("シミュレータ/CI では端末内 AI は使えない想定(false)")
    func isAvailableFalseOnSimulator() {
        // 実機の Apple Intelligence 対応端末では true になりうるが、
        // テスト環境(シミュレータ/CI)では false になる前提。実モデル出力はここでは検証しない。
        #expect(MealAIAssistant.isAvailable == false)
    }
}
