import Foundation
import FirebaseFirestore

// MARK: - 世帯(共有グループ)

struct Household: Identifiable, Codable {
    @DocumentID var id: String?
    var name: String
    var memberIds: [String]     // Firebase Auth の UID を格納。セキュリティルールで参照
    /// uid → 表示名。メンバー一覧を追加の読み取りなしで表示するための非正規化。
    /// 既存世帯には無いプロパティなので Optional にしてデコード失敗を防ぐ
    /// (Swift の合成 Codable はデフォルト値を使わず、キー欠落で throw するため)
    var memberNames: [String: String]?
    var inviteCode: String      // 招待コード。inviteCodes/{code} から世帯を引く際のキー
    @ServerTimestamp var createdAt: Date?
}

// MARK: - カテゴリ(世帯ごとに追加・編集・並び替え可能)

/// households/{id}/categories/{id} に保存。
/// 世帯単位で持つので、カスタムカテゴリや並び順も家族全員に同期される
struct ItemCategory: Identifiable, Codable, Equatable {
    @DocumentID var id: String?
    var name: String
    var emoji: String
    /// 表示順。並び替え時に振り直す(間隔を空けた値で保存)
    var sortOrder: Int
    /// カテゴリ自動推定用のキー。初期カテゴリにのみ設定され、
    /// ユーザーが名前を変更しても推定が壊れないようにする。
    /// ユーザーが自分で作ったカテゴリは nil
    var matcherKey: String?
    @ServerTimestamp var createdAt: Date?
}

// MARK: - 初期カテゴリ(新規世帯にシードするデータ)

enum DefaultCategories {
    /// 一般的なスーパーの回遊順(入口の青果 → 生鮮 → 加工品 → レジ前)。
    /// ユーザーはあとから自由に追加・編集・並び替えできる
    static let seeds: [(key: String, name: String, emoji: String)] = [
        ("produce",       "野菜・果物",     "🥬"),
        ("meat",          "肉",             "🥩"),
        ("seafood",       "魚介",           "🐟"),
        ("tofu",          "豆腐・大豆製品", "🫘"),
        ("dairyEgg",      "乳製品・卵",     "🥚"),
        ("bread",         "パン",           "🍞"),
        ("noodleDry",     "麺・乾物・米",   "🍚"),
        ("seasoning",     "調味料",         "🧂"),
        ("cannedInstant", "缶詰・レトルト", "🥫"),
        ("frozen",        "冷凍食品",       "🧊"),
        ("beverage",      "飲料",           "🥤"),
        ("snack",         "お菓子",         "🍪"),
        ("daily",         "日用品",         "🧻"),
        ("other",         "その他",         "🛒"),
    ]
}

// MARK: - 買い物アイテム

struct ShoppingItem: Identifiable, Codable, Equatable {
    @DocumentID var id: String?
    var name: String
    /// ItemCategory のドキュメントID。nil や参照切れ(カテゴリ削除後)は「未分類」表示
    var categoryId: String?
    var quantity: String?           // "2本" "300g" など自由入力
    var isChecked: Bool = false
    var addedByUid: String
    var addedByName: String         // 「誰が追加したか」を一覧に表示するため非正規化して持つ
    @ServerTimestamp var createdAt: Date?
    var checkedAt: Date?
}

// MARK: - レシピ(献立プランナー)

/// households/{id}/recipes/{id} に保存。世帯で共有するレシピ帳。
/// 材料は ShoppingItem と同じ「品名 + 自由入力の数量」形式で持ち、
/// 買い物リストへの展開時に CategoryGuesser でカテゴリを推定する
struct Recipe: Identifiable, Codable, Equatable {
    @DocumentID var id: String?
    var name: String
    var emoji: String
    var ingredients: [RecipeIngredient]
    var memo: String?
    @ServerTimestamp var createdAt: Date?
}

/// レシピ内の材料1件。配列としてレシピドキュメントに埋め込む
/// (材料単位で共有・検索する要件がないため、サブコレクションにはしない)
struct RecipeIngredient: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString   // 編集画面の ForEach 用に安定したIDを持つ
    var name: String
    var quantity: String?                // "2本" "300g" など自由入力
}

// MARK: - 献立(日付へのレシピ割り当て)

/// households/{id}/mealPlans/{id} に保存。1日に複数件(主菜+副菜など)割り当て可能。
struct MealPlanEntry: Identifiable, Codable, Equatable {
    @DocumentID var id: String?
    /// 端末タイムゾーンの暦日 "yyyy-MM-dd"。文字列の辞書順 = 日付順なので
    /// Firestore の範囲クエリ(今日以降)がそのまま使える
    var date: String
    var recipeId: String
    var recipeName: String      // レシピが後から削除されても表示できるよう非正規化
    var recipeEmoji: String
    var addedByUid: String
    @ServerTimestamp var createdAt: Date?
    /// 材料を買い物リストへ展開した日時。nil = 未展開(ボタンの表示切り替えに使用)
    var ingredientsAddedAt: Date?
}

// MARK: - 購入履歴(好みの学習データ)

/// households/{id}/purchaseHistory/{id} に保存。
/// 買い物リストで「購入済み」を削除する際に記録し、世帯の好み(よく買う食材)を蓄積する。
/// 献立提案(MealSuggester)のスコアリング入力になる。
struct PurchaseRecord: Identifiable, Codable {
    @DocumentID var id: String?
    var name: String
    var categoryId: String?
    var purchasedByUid: String
    @ServerTimestamp var purchasedAt: Date?
}

// MARK: - 品名からカテゴリを推定(簡易キーワードマッチ)

/// matcherKey を返し、UI 側で「その key を持つカテゴリ」を探して適用する。
/// ルールは上から順に評価されるので、判定の優先度 = 配列の順序。
/// (例:「冷凍うどん」→ 麺ではなく冷凍、「牛乳」→ 肉ではなく乳製品)
/// フェーズ3で「ユーザーの修正履歴から学習する辞書」に発展させられる。
enum CategoryGuesser {
    private static let rules: [(key: String, keywords: [String])] = [
        ("frozen",        ["冷凍", "アイス"]),
        ("tofu",          ["豆腐", "納豆", "油揚げ", "厚揚げ", "豆乳", "こんにゃく"]),
        ("dairyEgg",      ["牛乳", "ヨーグルト", "チーズ", "バター", "卵", "たまご", "生クリーム"]),
        ("meat",          ["豚", "鶏", "牛", "ひき肉", "挽き肉", "ベーコン", "ハム", "ソーセージ", "ウインナー"]),
        ("seafood",       ["鮭", "さけ", "サーモン", "まぐろ", "マグロ", "さば", "サバ", "ぶり", "えび", "エビ",
                           "いか", "たこ", "しらす", "刺身", "ちくわ", "かまぼこ"]),
        ("cannedInstant", ["缶", "ツナ", "レトルト", "カレールー", "インスタント", "カップ麺"]),
        ("seasoning",     ["醤油", "しょうゆ", "味噌", "みそ", "みりん", "砂糖", "塩", "酢", "油",
                           "マヨネーズ", "ケチャップ", "ソース", "ドレッシング", "こしょう", "胡椒",
                           "だしの素", "コンソメ", "めんつゆ"]),
        ("noodleDry",     ["米", "パスタ", "うどん", "そば", "そうめん", "中華麺", "春雨",
                           "わかめ", "のり", "海苔", "かつお節", "ごま", "小麦粉", "片栗粉", "パン粉"]),
        ("bread",         ["パン", "ベーグル", "マフィン"]),
        ("produce",       ["にんじん", "人参", "玉ねぎ", "たまねぎ", "じゃがいも", "トマト", "きゅうり",
                           "キャベツ", "レタス", "白菜", "ほうれん草", "小松菜", "ねぎ", "なす", "ピーマン",
                           "もやし", "しめじ", "えのき", "しいたけ", "大根", "ごぼう", "かぼちゃ",
                           "ブロッコリー", "バナナ", "りんご", "みかん", "いちご", "レモン", "アボカド",
                           "にんにく", "しょうが", "生姜"]),
        ("beverage",      ["水", "お茶", "麦茶", "コーヒー", "ジュース", "炭酸", "ビール", "ワイン"]),
        ("snack",         ["チョコ", "クッキー", "スナック", "せんべい", "グミ", "ポテチ"]),
        ("daily",         ["ティッシュ", "トイレットペーパー", "洗剤", "シャンプー", "ハンドソープ",
                           "ラップ", "アルミホイル", "スポンジ", "ゴミ袋", "電池", "歯磨き"]),
    ]

    static func guessKey(from name: String) -> String? {
        guard !name.isEmpty else { return nil }
        for rule in rules where rule.keywords.contains(where: { name.contains($0) }) {
            return rule.key
        }
        return nil
    }
}

// MARK: - 献立提案(購入履歴からの好みスコアリング)

/// レシピ帳の中から、世帯の好み(=よく買う食材)に合うレシピを提案する純粋関数。
/// Firestore に依存しないのでユニットテストから直接呼べる(CategoryGuesser と同じ方針)。
/// スコア = レシピの各材料の購入回数の合計。多く買う食材を使うレシピほど上位になる。
/// フェーズ3で購入頻度・季節性などの重み付けに発展させられる。
enum MealSuggester {
    struct Suggestion: Identifiable {
        var id: String                     // recipe.id
        var recipe: Recipe
        var score: Int
        var matchedIngredients: [String]   // 好みに一致した材料名(提案理由の表示用)
    }

    /// 品名の表記ゆれを吸収するための正規化(前後空白除去 + 小文字化)。
    static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// - Parameters:
    ///   - recipes: レシピ帳
    ///   - preferenceCounts: 正規化した品名 → 購入回数
    ///   - excludedRecipeIds: すでに献立に入っているなど、提案対象から除外するレシピID
    ///   - limit: 返す最大件数
    /// - Returns: スコア降順(同点はレシピ名昇順)の提案。スコア0のレシピは含めない。
    static func suggest(recipes: [Recipe],
                        preferenceCounts: [String: Int],
                        excludedRecipeIds: Set<String>,
                        limit: Int) -> [Suggestion] {
        guard limit > 0, !preferenceCounts.isEmpty else { return [] }

        var suggestions: [Suggestion] = []
        for recipe in recipes {
            guard let id = recipe.id, !excludedRecipeIds.contains(id) else { continue }

            var score = 0
            var matched: [String] = []
            for ingredient in recipe.ingredients {
                let key = normalize(ingredient.name)
                guard !key.isEmpty else { continue }
                // 完全一致 or 双方向の包含(「牛乳」⊂「低脂肪牛乳」等)でマッチ判定
                if let count = matchedCount(for: key, in: preferenceCounts) {
                    score += count
                    matched.append(ingredient.name)
                }
            }
            guard score > 0 else { continue }
            suggestions.append(Suggestion(id: id, recipe: recipe, score: score,
                                          matchedIngredients: matched))
        }

        suggestions.sort {
            $0.score != $1.score ? $0.score > $1.score : $0.recipe.name < $1.recipe.name
        }
        return Array(suggestions.prefix(limit))
    }

    /// 材料名(正規化済み)に対応する購入回数を返す。完全一致を優先し、
    /// 無ければ双方向の部分一致でマッチした回数を合算する。マッチ無しは nil。
    private static func matchedCount(for key: String, in counts: [String: Int]) -> Int? {
        if let exact = counts[key] { return exact }
        var total = 0
        for (name, count) in counts where name.contains(key) || key.contains(name) {
            total += count
        }
        return total > 0 ? total : nil
    }
}
