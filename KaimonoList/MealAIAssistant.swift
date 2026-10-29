import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - 端末内 AI による献立の提案(Apple Intelligence 対応端末のみ)

/// 端末内の言語モデル(Foundation Models)を使って献立を支援する。
/// ReceiptAIExtractor と同じく、購入履歴や献立などの情報を外部に送らず端末内で処理する。
/// iOS 26 未満・非対応端末・Apple Intelligence オフのときは何もしない(`isAvailable` が false)。
///
/// - 栄養バランスは端末内モデルが数値計算を苦手とするため、カロリー等の数値は扱わず
///   「野菜が少ない」「タンパク質を足すと良い」といった定性的なアドバイスに限定する。
/// - レシピ創作・数日分の提案は `@Generable` による構造化出力で受け取る。
enum MealAIAssistant {

    // MARK: - 結果の型(端末・OS を問わず参照できるドメイン型)

    /// 献立全体の栄養バランスについての定性的なアドバイス。
    struct NutritionAdvice: Equatable {
        /// 全体の総評(1〜2文)
        var summary: String
        /// 具体的な改善の提案(各1文)
        var tips: [String]
    }

    /// AI が創作した新しいレシピ。採用するとレシピ帳へ保存して献立に追加できる。
    struct InventedRecipe: Equatable, Identifiable {
        var id = UUID().uuidString
        var name: String
        var emoji: String
        var ingredients: [RecipeIngredient]
        var memo: String?
    }

    /// 数日分の献立提案の1件。`dayOffset` は今日からの日数(0 = 今日)で、
    /// モデルは数値を苦手とするため呼び出し側が並び順から振り直す。
    struct ProposedMeal: Equatable, Identifiable {
        var id = UUID().uuidString
        var dayOffset: Int
        var recipe: InventedRecipe
        /// 提案理由(旬・好み・栄養バランスなど。表示用)
        var reason: String?
    }

    // MARK: - 可用性

    /// この端末で端末内 AI が使えるか(ReceiptAIExtractor.isAvailable と同じ判定)。
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    // MARK: - 生成(AI 呼び出し)

    /// 今の献立(料理名の一覧)と旬の食材から、栄養バランスの定性的アドバイスを作る。
    /// 失敗・非対応時は nil。
    static func nutritionAdvice(recipeNames: [String], season: [String]) async -> NutritionAdvice? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard isAvailable, !recipeNames.isEmpty else { return nil }
            do {
                let session = LanguageModelSession(instructions: """
                あなたは家庭料理の献立をやさしくサポートする栄養アドバイザーです。
                渡された数日分の献立全体を見て、栄養バランスの観点から短く助言してください。
                - カロリーや gram などの数値は出さないでください(定性的な助言だけ)。
                - 「野菜が少ない」「タンパク質を足すと良い」「主菜が肉に偏っている」など
                  家庭で分かりやすい言葉で伝えてください。
                - tips は具体的な一品や食材の提案を2〜3件、各1文で。
                - 日本語で、前向きで押し付けがましくない表現にしてください。
                """)
                let prompt = nutritionPromptContext(recipeNames: recipeNames, season: season)
                let response = try await session.respond(to: prompt, generating: GenAdvice.self)
                return mapAdvice(response.content)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    /// 旬の食材を使った新しいレシピを1品創作する。`avoidNames` は既存レシピ/カタログ名の
    /// 正規化済み集合で、同じ料理の重複提案を避ける。失敗・非対応・重複時は nil。
    static func inventRecipe(season: [String], avoidNames: Set<String>, preferred: [String]) async -> InventedRecipe? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard isAvailable, !season.isEmpty else { return nil }
            do {
                let session = LanguageModelSession(instructions: """
                あなたは家庭料理が得意な料理人です。今の季節の旬の食材を主役にした、
                家庭で作りやすい晩ごはんのメインのおかずを1品だけ考えてください。
                - name は料理名(簡潔に)。emoji はその料理に合う絵文字を1文字。
                - ingredients は主な材料。quantity はおおよその分量(2人前、例:「2個」「200g」「適量」)。
                - memo に作り方の要点を2〜4文で簡潔に。
                - 凝りすぎず、スーパーで手に入る食材で作れるものにしてください。
                - 日本語で答えてください。
                """)
                let prompt = inventPromptContext(season: season, preferred: preferred)
                let response = try await session.respond(to: prompt, generating: GenRecipe.self)
                guard let recipe = mapRecipe(response.content),
                      isNovel(name: recipe.name, existing: avoidNames) else { return nil }
                return recipe
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    /// 数日分の献立をまとめて提案する。好み・旬・栄養バランスの偏り回避を考慮する。
    /// `dayOffset` は返り値の並び順から 0,1,2… と振り直す。失敗・非対応時は nil。
    static func planMeals(days: Int,
                          existingRecipes: [String],
                          season: [String],
                          preferred: [String],
                          recent: [String]) async -> [ProposedMeal]? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard isAvailable, days > 0 else { return nil }
            do {
                let session = LanguageModelSession(instructions: """
                あなたは家庭の献立を考えるアシスタントです。晩ごはんのメインのおかずを提案します。
                - 栄養バランスが偏らないよう、肉・魚・野菜中心などの主菜をバランス良く散らしてください。
                - できれば旬の食材を活かし、最近作った料理とは重ならないようにしてください。
                - 各料理に ingredients(主な材料)と、1文の reason(選んだ理由)を付けてください。
                - quantity はおおよその分量(2人前)。memo は無くてよい。
                - 指定された日数ぴったりの品数を、作りやすい家庭料理で提案してください。
                - 日本語で答えてください。
                """)
                let prompt = planPromptContext(days: days, existingRecipes: existingRecipes,
                                               season: season, preferred: preferred, recent: recent)
                let response = try await session.respond(to: prompt, generating: GenWeekPlan.self)
                return mapPlan(response.content, days: days)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    // MARK: - 純粋ヘルパー(モデル非依存・テスト対象)

    /// 生成レシピの名前が、既存レシピ/カタログと重複しない新しいものか。
    /// `existing` は `MealSuggester.normalize` 済みの名前集合。
    static func isNovel(name: String, existing: Set<String>) -> Bool {
        let key = MealSuggester.normalize(name)
        guard !key.isEmpty else { return false }
        return !existing.contains(key)
    }

    /// 名前が空の材料を除外し、前後の空白を落とす(MealPlannerViewModel と同じ方針)。
    static func cleanedIngredients(_ ingredients: [RecipeIngredient]) -> [RecipeIngredient] {
        ingredients.compactMap { ingredient in
            let name = ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let quantity = ingredient.quantity?.trimmingCharacters(in: .whitespacesAndNewlines)
            return RecipeIngredient(id: ingredient.id, name: name,
                                    quantity: (quantity?.isEmpty ?? true) ? nil : quantity)
        }
    }

    /// 絵文字欄を1文字に整える。空なら既定の皿アイコン。
    static func normalizedEmoji(_ emoji: String) -> String {
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "🍽️" }
        return String(first)
    }

    /// 栄養アドバイス用のプロンプト本文。
    static func nutritionPromptContext(recipeNames: [String], season: [String]) -> String {
        var lines = ["これからの献立(晩ごはんのメイン):", recipeNames.joined(separator: "、")]
        if !season.isEmpty {
            lines.append("今の旬の食材:" + season.joined(separator: "、"))
        }
        return lines.joined(separator: "\n")
    }

    /// レシピ創作用のプロンプト本文。
    static func inventPromptContext(season: [String], preferred: [String]) -> String {
        var lines = ["今の旬の食材:" + season.joined(separator: "、")]
        if !preferred.isEmpty {
            lines.append("この家庭がよく買う食材:" + preferred.joined(separator: "、"))
        }
        lines.append("これらを活かした晩ごはんのメインを1品考えてください。")
        return lines.joined(separator: "\n")
    }

    /// 数日分提案用のプロンプト本文。
    static func planPromptContext(days: Int,
                                  existingRecipes: [String],
                                  season: [String],
                                  preferred: [String],
                                  recent: [String]) -> String {
        var lines = ["\(days)日分の晩ごはんのメインを提案してください。"]
        if !season.isEmpty {
            lines.append("今の旬の食材:" + season.joined(separator: "、"))
        }
        if !preferred.isEmpty {
            lines.append("よく買う食材:" + preferred.joined(separator: "、"))
        }
        if !recent.isEmpty {
            lines.append("最近作った料理(重複を避けたい):" + recent.joined(separator: "、"))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - @Generable 中間型とマッピング(iOS 26+ / Apple Intelligence)

#if canImport(FoundationModels)
@available(iOS 26.0, *)
extension MealAIAssistant {

    /// 栄養アドバイスの生成用スキーマ。
    @Generable
    struct GenAdvice {
        @Guide(description: "献立全体の栄養バランスの短い総評。1〜2文。数値は含めない。")
        var summary: String
        @Guide(description: "具体的な改善の提案。各項目は1文。2〜3件。")
        var tips: [String]
    }

    /// 1品のレシピの生成用スキーマ。
    @Generable
    struct GenRecipe {
        @Guide(description: "料理名。簡潔に。")
        var name: String
        @Guide(description: "料理に合う絵文字を1文字。")
        var emoji: String
        var ingredients: [GenIngredient]
        @Guide(description: "作り方の要点。2〜4文。無ければ空文字。")
        var memo: String
    }

    /// レシピの材料1件の生成用スキーマ。
    @Generable
    struct GenIngredient {
        @Guide(description: "材料名(例:なす、豚こま肉)。")
        var name: String
        @Guide(description: "おおよその分量(2人前。例:2個、200g、適量)。")
        var quantity: String
    }

    /// 数日分の献立提案の生成用スキーマ。
    @Generable
    struct GenWeekPlan {
        var meals: [GenProposedMeal]
    }

    /// 数日分提案の1品の生成用スキーマ。
    @Generable
    struct GenProposedMeal {
        @Guide(description: "料理名。簡潔に。")
        var name: String
        @Guide(description: "料理に合う絵文字を1文字。")
        var emoji: String
        var ingredients: [GenIngredient]
        @Guide(description: "この料理を選んだ理由。1文。")
        var reason: String
    }

    // MARK: マッピング(生成結果 → ドメイン型)

    static func mapAdvice(_ gen: GenAdvice) -> NutritionAdvice? {
        let summary = gen.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let tips = gen.tips
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !summary.isEmpty || !tips.isEmpty else { return nil }
        return NutritionAdvice(summary: summary, tips: tips)
    }

    static func mapRecipe(_ gen: GenRecipe) -> InventedRecipe? {
        let name = gen.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ingredients = cleanedIngredients(gen.ingredients.map {
            RecipeIngredient(name: $0.name, quantity: $0.quantity)
        })
        guard !name.isEmpty, !ingredients.isEmpty else { return nil }
        let memo = gen.memo.trimmingCharacters(in: .whitespacesAndNewlines)
        return InventedRecipe(name: name, emoji: normalizedEmoji(gen.emoji),
                              ingredients: ingredients, memo: memo.isEmpty ? nil : memo)
    }

    static func mapPlan(_ gen: GenWeekPlan, days: Int) -> [ProposedMeal] {
        // 先に無効な料理(名前・材料が空)を除いてから日数分に絞る。
        // prefix を先にかけると、無効な料理が混ざったとき要求日数より少なくなってしまうため。
        let valid = gen.meals.compactMap { meal -> (recipe: InventedRecipe, reason: String?)? in
            let name = meal.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let ingredients = cleanedIngredients(meal.ingredients.map {
                RecipeIngredient(name: $0.name, quantity: $0.quantity)
            })
            guard !name.isEmpty, !ingredients.isEmpty else { return nil }
            let reason = meal.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            let recipe = InventedRecipe(name: name, emoji: normalizedEmoji(meal.emoji),
                                        ingredients: ingredients, memo: nil)
            return (recipe, reason.isEmpty ? nil : reason)
        }
        // dayOffset は絞り込み後の並び順から 0,1,2… と割り当てる。
        return valid.prefix(days).enumerated().map { index, pair in
            ProposedMeal(dayOffset: index, recipe: pair.recipe, reason: pair.reason)
        }
    }
}
#endif
