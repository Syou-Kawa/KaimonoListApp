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
    /// 献立から展開された材料のとき、その料理名・絵文字を非正規化して持つ。
    /// 買い物リストで「どの料理の材料か」を確認できるようにする。手動追加は nil。
    /// (Optional なのでキー欠落でもデコードは失敗しない)
    var sourceRecipeName: String?
    var sourceRecipeEmoji: String?
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
    /// このレシピの材料数量が「何人前の分量か」の基準。
    /// 献立の人数とこの値の比率で買い物リストの数量をスケールする。
    /// 既存レシピには無いプロパティなので Optional にしてデコード失敗を防ぐ
    /// (nil = 未設定 → `baseServingsOrDefault` で既定人数として扱う)。
    var baseServings: Int? = nil
    @ServerTimestamp var createdAt: Date?
}

extension Recipe {
    /// 数量スケールの基準にする人数(nil を既定人数に丸める)
    var baseServingsOrDefault: Int { baseServings ?? MealPlanEntry.defaultServings }
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
    /// 何人前か。既存エントリには無いプロパティなので Optional にしてデコード失敗を防ぐ
    /// (Optional は synthesized Decodable が decodeIfPresent 扱いでキー欠落を許容する)。
    /// nil = 未設定 → 表示・保存時は `defaultServings` として扱う。
    var servings: Int? = nil
    @ServerTimestamp var createdAt: Date?
    /// 材料を買い物リストへ展開した日時。nil = 未展開(ボタンの表示切り替えに使用)
    var ingredientsAddedAt: Date?
}

extension MealPlanEntry {
    /// 人数未指定(既存エントリや nil)のときに使うデフォルト人数
    static let defaultServings = 2
    /// 表示・編集の基準にする人数(nil を defaultServings に丸める)
    var servingsOrDefault: Int { servings ?? Self.defaultServings }
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

// MARK: - よく買うもの(購入履歴の頻度ランキング)

/// 購入履歴から「よく買う品」を頻度順に集計する純粋関数。
/// Firestore に依存しないのでユニットテストから直接呼べる(CategoryGuesser と同じ方針)。
/// 買い物リストの追加シートで、ワンタップ追加の候補チップに使う。
enum FrequentItems {

    /// ランキング1件。ワンタップ追加に必要な品名とカテゴリを持つ。
    struct Item: Identifiable, Equatable {
        var name: String        // 代表表記(最も最近購入したときの品名)
        var categoryId: String? // 最も最近購入したときのカテゴリ(削除済みなら追加側で推定し直す)
        var count: Int          // 購入回数(表記ゆれをまとめた合計)
        var id: String { name }
    }

    /// 品名の表記ゆれを吸収する正規化(前後空白除去 + 小文字化)。純粋関数。
    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// - Parameters:
    ///   - history: 購入履歴(順序は問わない)
    ///   - excludingNames: すでにリストにある等、候補から外す品名(正規化して比較)
    ///   - limit: 返す最大件数
    /// - Returns: 購入回数の多い順(同数は最近購入した順、さらに品名昇順)の候補。
    ///   品名が空の履歴、および除外対象の品名は含めない。
    static func topItems(from history: [PurchaseRecord],
                         excludingNames: Set<String> = [],
                         limit: Int) -> [Item] {
        guard limit > 0 else { return [] }
        let excluded = Set(excludingNames.map(normalize))

        // 正規化キーごとに、回数・最新の購入時刻・その時点の表記/カテゴリを集める
        struct Bucket {
            var count = 0
            var latestDate = Date.distantPast
            var latestName = ""
            var latestCategoryId: String?
        }
        var buckets: [String: Bucket] = [:]

        for record in history {
            let displayName = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalize(displayName)
            guard !key.isEmpty, !excluded.contains(key) else { continue }

            var bucket = buckets[key] ?? Bucket()
            bucket.count += 1
            // 最新の購入を代表の表記・カテゴリにする(未設定 or より新しい記録で更新)
            let date = record.purchasedAt ?? .distantPast
            if bucket.latestName.isEmpty || date >= bucket.latestDate {
                bucket.latestDate = date
                bucket.latestName = displayName
                bucket.latestCategoryId = record.categoryId
            }
            buckets[key] = bucket
        }

        let sorted = buckets.values.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            if lhs.latestDate != rhs.latestDate { return lhs.latestDate > rhs.latestDate }
            return lhs.latestName < rhs.latestName
        }
        return sorted.prefix(limit).map {
            Item(name: $0.latestName, categoryId: $0.latestCategoryId, count: $0.count)
        }
    }
}

// MARK: - 品名からカテゴリを推定(簡易キーワードマッチ)

/// matcherKey を返し、UI 側で「その key を持つカテゴリ」を探して適用する。
/// ルールは上から順に評価されるので、判定の優先度 = 配列の順序。
/// (例:「冷凍うどん」→ 麺ではなく冷凍、「牛乳」→ 肉ではなく乳製品)
/// フェーズ3で「ユーザーの修正履歴から学習する辞書」に発展させられる。
enum CategoryGuesser {
    /// 1件の推定ルール。`excludes` に該当語を含む品名では、そのルールを飛ばして
    /// 後続ルールの評価へ回す(例:「フライパン」を bread の「パン」で拾わない)。
    private struct Rule {
        let key: String
        let keywords: [String]
        let excludes: [String]
        init(_ key: String, _ keywords: [String], excludes: [String] = []) {
            self.key = key
            self.keywords = keywords
            self.excludes = excludes
        }
    }

    private static let rules: [Rule] = [
        Rule("frozen",        ["冷凍", "アイス"]),
        Rule("tofu",          ["豆腐", "納豆", "油揚げ", "厚揚げ", "豆乳", "こんにゃく"]),
        Rule("dairyEgg",      ["牛乳", "ヨーグルト", "チーズ", "バター", "卵", "たまご", "生クリーム"]),
        Rule("meat",          ["豚", "鶏", "牛", "ひき肉", "挽き肉", "ベーコン", "ハム", "ソーセージ", "ウインナー"]),
        Rule("seafood",       ["鮭", "さけ", "サーモン", "まぐろ", "マグロ", "さば", "サバ", "ぶり", "えび", "エビ",
                               "いか", "たこ", "しらす", "刺身", "ちくわ", "かまぼこ"]),
        Rule("cannedInstant", ["缶", "ツナ", "レトルト", "カレールー", "インスタント", "カップ麺"]),
        Rule("seasoning",     ["醤油", "しょうゆ", "味噌", "みそ", "みりん", "砂糖", "塩", "酢", "油",
                               "マヨネーズ", "ケチャップ", "ソース", "ドレッシング", "こしょう", "胡椒",
                               "だしの素", "コンソメ", "めんつゆ"]),
        Rule("noodleDry",     ["米", "パスタ", "うどん", "そば", "そうめん", "中華麺", "春雨",
                               "わかめ", "のり", "海苔", "かつお節", "ごま", "小麦粉", "片栗粉", "パン粉"]),
        // 「フライパン」など調理器具を「パン」で誤検出しないよう除外する
        Rule("bread",         ["パン", "ベーグル", "マフィン"], excludes: ["フライパン"]),
        Rule("produce",       ["にんじん", "人参", "玉ねぎ", "たまねぎ", "じゃがいも", "トマト", "きゅうり",
                               "キャベツ", "レタス", "白菜", "ほうれん草", "小松菜", "水菜", "ねぎ", "なす", "ピーマン",
                               "もやし", "しめじ", "えのき", "しいたけ", "大根", "ごぼう", "かぼちゃ",
                               "ブロッコリー", "バナナ", "りんご", "みかん", "いちご", "レモン", "アボカド",
                               "にんにく", "しょうが", "生姜"]),
        // 「水菜」「化粧水」を「水」で拾わないよう除外(水菜は produce が先に拾う)
        Rule("beverage",      ["水", "お茶", "麦茶", "コーヒー", "ジュース", "炭酸", "ビール", "ワイン"],
                              excludes: ["水菜", "化粧水"]),
        Rule("snack",         ["チョコ", "クッキー", "スナック", "せんべい", "グミ", "ポテチ"]),
        Rule("daily",         ["ティッシュ", "トイレットペーパー", "洗剤", "シャンプー", "ハンドソープ",
                               "ラップ", "アルミホイル", "スポンジ", "ゴミ袋", "電池", "歯磨き"]),
    ]

    static func guessKey(from name: String) -> String? {
        guard !name.isEmpty else { return nil }
        for rule in rules {
            // 除外語を含む品名では、このルールは適用せず次のルールへ
            if rule.excludes.contains(where: { name.contains($0) }) { continue }
            if rule.keywords.contains(where: { name.contains($0) }) {
                return rule.key
            }
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
        var seasonalMatches: [String]      // 旬に一致した材料名(提案理由の表示用)
    }

    /// スコア調整の重み(テストが挙動を検証するため定数として公開する)。
    static let seasonalBonusPerIngredient = 3   // 旬の食材1つあたりの加点
    static let recencyPenaltyPerCook = 4        // 直近に作った回数1回あたりの減点(マンネリ回避)

    /// 品名の表記ゆれを吸収するための正規化(前後空白除去 + 小文字化)。純粋関数。
    nonisolated static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// - Parameters:
    ///   - recipes: レシピ帳
    ///   - preferenceCounts: 正規化した品名 → 購入回数
    ///   - seasonalIngredients: 当月の旬食材(正規化済み)。含む材料に加点する
    ///   - recentCookCounts: recipeId → 直近に献立へ入れた回数。よく作ったものほど減点する
    ///   - excludedRecipeIds: すでに献立に入っているなど、提案対象から除外するレシピID
    ///   - limit: 返す最大件数
    /// - Returns: スコア降順(同点はレシピ名昇順)の提案。好みにも旬にも一致しないレシピ、
    ///   および減点でスコアが0以下になったレシピは含めない。
    static func suggest(recipes: [Recipe],
                        preferenceCounts: [String: Int],
                        seasonalIngredients: Set<String> = [],
                        recentCookCounts: [String: Int] = [:],
                        excludedRecipeIds: Set<String>,
                        limit: Int) -> [Suggestion] {
        guard limit > 0 else { return [] }
        // 好み(購入履歴)も旬情報も無ければ提案の根拠が無いので空を返す
        guard !preferenceCounts.isEmpty || !seasonalIngredients.isEmpty else { return [] }

        var suggestions: [Suggestion] = []
        for recipe in recipes {
            guard let id = recipe.id, !excludedRecipeIds.contains(id) else { continue }

            var preferenceScore = 0
            var matched: [String] = []
            var seasonalMatched: [String] = []
            for ingredient in recipe.ingredients {
                let key = normalize(ingredient.name)
                guard !key.isEmpty else { continue }
                // 完全一致 or 双方向の包含(「牛乳」⊂「低脂肪牛乳」等)でマッチ判定
                if let count = matchedCount(for: key, in: preferenceCounts) {
                    preferenceScore += count
                    matched.append(ingredient.name)
                }
                if isSeasonalMatch(key, in: seasonalIngredients) {
                    seasonalMatched.append(ingredient.name)
                }
            }

            // 好みにも旬にも一致しないレシピは提案しない(減点だけで残っても意味がない)
            guard preferenceScore > 0 || !seasonalMatched.isEmpty else { continue }

            let seasonalBonus = seasonalMatched.count * seasonalBonusPerIngredient
            let penalty = (recentCookCounts[id] ?? 0) * recencyPenaltyPerCook
            let score = preferenceScore + seasonalBonus - penalty
            guard score > 0 else { continue }

            suggestions.append(Suggestion(id: id, recipe: recipe, score: score,
                                          matchedIngredients: matched,
                                          seasonalMatches: seasonalMatched))
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

    /// 材料名(正規化済み)が旬食材に該当するか。品名一致と同様に双方向の包含も許す。
    private static func isSeasonalMatch(_ key: String, in seasonal: Set<String>) -> Bool {
        if seasonal.contains(key) { return true }
        return seasonal.contains { $0.contains(key) || key.contains($0) }
    }
}

// MARK: - 旬の食材テーブル(月ごとの代表的な食材)

/// 献立提案で「旬の食材を使うレシピ」を後押しするための、月ごとの代表的な旬食材。
/// 外部サービスに依存せずオフラインで動くよう、コードに直接持つ。
enum SeasonalIngredients {

    /// 端末の現在月の旬食材(正規化済み)。`MealSuggester.suggest` にそのまま渡せる。
    static func current(now: Date = Date(), calendar: Calendar = .current) -> Set<String> {
        let month = calendar.component(.month, from: now)
        return Set(forMonth(month).map(MealSuggester.normalize))
    }

    /// 指定した月(1〜12)の旬食材。範囲外なら空配列。
    static func forMonth(_ month: Int) -> [String] {
        table[month] ?? []
    }

    private static let table: [Int: [String]] = [
        1:  ["大根", "白菜", "ほうれん草", "ねぎ", "小松菜", "みかん", "りんご", "ぶり", "牡蠣"],
        2:  ["大根", "白菜", "ほうれん草", "ねぎ", "キャベツ", "ぶり", "牡蠣", "いちご"],
        3:  ["キャベツ", "菜の花", "たけのこ", "新玉ねぎ", "いちご", "あさり", "はまぐり"],
        4:  ["たけのこ", "春キャベツ", "菜の花", "アスパラガス", "さやえんどう", "新玉ねぎ", "あさり"],
        5:  ["アスパラガス", "そら豆", "グリンピース", "キャベツ", "新玉ねぎ", "いちご", "かつお"],
        6:  ["なす", "トマト", "きゅうり", "ズッキーニ", "さやいんげん", "梅", "あじ"],
        7:  ["なす", "トマト", "きゅうり", "とうもろこし", "ピーマン", "オクラ", "ゴーヤ", "枝豆", "すいか"],
        8:  ["なす", "トマト", "きゅうり", "とうもろこし", "ピーマン", "オクラ", "ゴーヤ", "かぼちゃ", "枝豆"],
        9:  ["さつまいも", "かぼちゃ", "なす", "しめじ", "まいたけ", "さんま", "ぶどう", "梨"],
        10: ["さつまいも", "かぼちゃ", "しいたけ", "しめじ", "さんま", "鮭", "栗", "柿", "りんご"],
        11: ["大根", "白菜", "ほうれん草", "ねぎ", "さつまいも", "れんこん", "鮭", "りんご", "みかん"],
        12: ["大根", "白菜", "ねぎ", "ほうれん草", "れんこん", "ぶり", "牡蠣", "みかん"],
    ]
}

// MARK: - 定番レシピのカタログ(アプリ内蔵の献立候補)

/// 自分でレシピを登録していなくても「いろいろな料理」を選べるように、
/// アプリに内蔵した定番レシピ集。外部サービスに依存せずオフラインで動くよう
/// コードに直接持つ(旬食材テーブルと同じ方針)。
///
/// これらは Firestore には保存されていないため id は合成値(`idPrefix` 始まり)を持つ。
/// 献立に選ばれた時点で初めてレシピ帳へ保存(マテリアライズ)し、
/// 実際の Firestore ドキュメントIDを採番する(MealPlannerViewModel 側で処理)。
enum RecipeCatalog {
    /// カタログ由来のレシピを見分けるための id 接頭辞
    static let idPrefix = "catalog-"

    /// あるレシピがカタログ由来か(= まだ Firestore に保存されていないか)
    static func isCatalog(_ recipe: Recipe) -> Bool {
        recipe.id?.hasPrefix(idPrefix) ?? false
    }

    private static func make(_ slug: String, _ emoji: String, _ name: String,
                             _ ingredients: [(String, String?)]) -> Recipe {
        Recipe(
            id: idPrefix + slug,
            name: name,
            emoji: emoji,
            ingredients: ingredients.map { RecipeIngredient(name: $0.0, quantity: $0.1) },
            memo: nil,
            createdAt: nil
        )
    }

    /// 定番レシピ一覧。肉・魚・麺・ごはん・鍋物など幅広いジャンルを揃える。
    static let all: [Recipe] = [
        make("curry",        "🍛", "カレーライス",
             [("豚こま肉", "200g"), ("じゃがいも", "2個"), ("にんじん", "1本"),
              ("玉ねぎ", "2個"), ("カレールー", "1箱"), ("米", "2合")]),
        make("nikujaga",     "🥘", "肉じゃが",
             [("牛こま肉", "200g"), ("じゃがいも", "3個"), ("にんじん", "1本"),
              ("玉ねぎ", "1個"), ("しらたき", "1袋"), ("醤油", "大さじ3")]),
        make("shogayaki",    "🍖", "豚の生姜焼き",
             [("豚ロース", "300g"), ("玉ねぎ", "1個"), ("しょうが", "1片"),
              ("キャベツ", "1/4個"), ("醤油", "大さじ2")]),
        make("hamburg",      "🥩", "ハンバーグ",
             [("合いびき肉", "300g"), ("玉ねぎ", "1個"), ("卵", "1個"),
              ("パン粉", "適量"), ("ケチャップ", "適量")]),
        make("karaage",      "🍗", "鶏の唐揚げ",
             [("鶏もも肉", "400g"), ("にんにく", "1片"), ("しょうが", "1片"),
              ("片栗粉", "適量"), ("醤油", "大さじ2")]),
        make("oyakodon",     "🍚", "親子丼",
             [("鶏もも肉", "200g"), ("卵", "3個"), ("玉ねぎ", "1個"),
              ("めんつゆ", "適量"), ("米", "2合")]),
        make("gyudon",       "🍚", "牛丼",
             [("牛こま肉", "250g"), ("玉ねぎ", "1個"), ("しょうが", "1片"),
              ("米", "2合"), ("醤油", "大さじ2")]),
        make("mabodofu",     "🥘", "麻婆豆腐",
             [("豚ひき肉", "150g"), ("豆腐", "1丁"), ("ねぎ", "1本"),
              ("にんにく", "1片"), ("味噌", "大さじ1")]),
        make("gyoza",        "🥟", "餃子",
             [("豚ひき肉", "200g"), ("キャベツ", "1/4個"), ("にら", "1束"),
              ("にんにく", "1片"), ("餃子の皮", "1袋")]),
        make("teriyaki",     "🍗", "鶏の照り焼き",
             [("鶏もも肉", "2枚"), ("醤油", "大さじ2"), ("みりん", "大さじ2"),
              ("砂糖", "大さじ1")]),
        make("tonkatsu",     "🍖", "とんかつ",
             [("豚ロース", "2枚"), ("パン粉", "適量"), ("卵", "1個"),
              ("キャベツ", "1/4個")]),
        make("chinjao",      "🥘", "チンジャオロース",
             [("牛肉", "200g"), ("ピーマン", "4個"), ("たけのこ", "1個"),
              ("オイスターソース", "大さじ1")]),
        make("hoikoro",      "🥘", "回鍋肉",
             [("豚バラ肉", "200g"), ("キャベツ", "1/4個"), ("ピーマン", "2個"),
              ("味噌", "大さじ1")]),
        make("subuta",       "🥘", "酢豚",
             [("豚肉", "250g"), ("玉ねぎ", "1個"), ("ピーマン", "2個"),
              ("にんじん", "1本"), ("ケチャップ", "適量")]),
        make("rollcabbage",  "🍲", "ロールキャベツ",
             [("合いびき肉", "200g"), ("キャベツ", "6枚"), ("玉ねぎ", "1個"),
              ("コンソメ", "適量")]),
        make("tonjiru",      "🍲", "豚汁",
             [("豚バラ肉", "150g"), ("大根", "1/4本"), ("にんじん", "1本"),
              ("ごぼう", "1本"), ("豆腐", "1/2丁"), ("味噌", "適量")]),
        make("nikudofu",     "🍲", "肉豆腐",
             [("牛肉", "150g"), ("豆腐", "1丁"), ("ねぎ", "1本"), ("しらたき", "1袋")]),
        make("shiozake",     "🐟", "鮭の塩焼き",
             [("鮭", "2切れ"), ("塩", "適量"), ("大根", "適量")]),
        make("sabamiso",     "🐟", "さばの味噌煮",
             [("さば", "2切れ"), ("しょうが", "1片"), ("味噌", "大さじ2"),
              ("みりん", "大さじ2")]),
        make("buridaikon",   "🐟", "ぶり大根",
             [("ぶり", "2切れ"), ("大根", "1/2本"), ("しょうが", "1片"),
              ("醤油", "適量")]),
        make("ebifry",       "🍤", "えびフライ",
             [("えび", "8尾"), ("パン粉", "適量"), ("卵", "1個"),
              ("キャベツ", "適量")]),
        make("muniere",      "🐟", "白身魚のムニエル",
             [("白身魚", "2切れ"), ("バター", "適量"), ("レモン", "1個"),
              ("小麦粉", "適量")]),
        make("nanban",       "🐟", "あじの南蛮漬け",
             [("あじ", "4尾"), ("玉ねぎ", "1個"), ("にんじん", "1本"),
              ("酢", "適量")]),
        make("napolitan",    "🍝", "ナポリタン",
             [("パスタ", "200g"), ("ウインナー", "4本"), ("玉ねぎ", "1個"),
              ("ピーマン", "2個"), ("ケチャップ", "適量")]),
        make("meatsauce",    "🍝", "ミートソースパスタ",
             [("パスタ", "200g"), ("合いびき肉", "200g"), ("玉ねぎ", "1個"),
              ("トマト缶", "1缶")]),
        make("carbonara",    "🍝", "カルボナーラ",
             [("パスタ", "200g"), ("ベーコン", "100g"), ("卵", "2個"),
              ("生クリーム", "適量"), ("チーズ", "適量")]),
        make("peperoncino",  "🍝", "ペペロンチーノ",
             [("パスタ", "200g"), ("にんにく", "2片"), ("唐辛子", "適量"),
              ("オリーブオイル", "適量")]),
        make("yakisoba",     "🍜", "焼きそば",
             [("中華麺", "3玉"), ("豚こま肉", "150g"), ("キャベツ", "1/4個"),
              ("にんじん", "1本"), ("ソース", "適量")]),
        make("chahan",       "🍚", "チャーハン",
             [("米", "2合"), ("卵", "2個"), ("ねぎ", "1本"), ("ハム", "4枚")]),
        make("omurice",      "🍳", "オムライス",
             [("米", "2合"), ("鶏もも肉", "150g"), ("玉ねぎ", "1個"),
              ("卵", "4個"), ("ケチャップ", "適量")]),
        make("tendon",       "🍤", "天丼",
             [("えび", "4尾"), ("なす", "1本"), ("さつまいも", "1/2本"),
              ("米", "2合"), ("天ぷら粉", "適量")]),
        make("nabeudon",     "🍜", "鍋焼きうどん",
             [("うどん", "2玉"), ("鶏肉", "100g"), ("卵", "2個"),
              ("ねぎ", "1本"), ("めんつゆ", "適量")]),
        make("yasaiitame",   "🥘", "野菜炒め",
             [("豚こま肉", "150g"), ("キャベツ", "1/4個"), ("もやし", "1袋"),
              ("にんじん", "1本"), ("ピーマン", "2個")]),
        make("gratin",       "🧀", "グラタン",
             [("マカロニ", "100g"), ("鶏もも肉", "150g"), ("玉ねぎ", "1個"),
              ("牛乳", "300ml"), ("チーズ", "適量")]),
        make("stew",         "🍲", "クリームシチュー",
             [("鶏もも肉", "200g"), ("じゃがいも", "2個"), ("にんじん", "1本"),
              ("玉ねぎ", "1個"), ("牛乳", "300ml"), ("シチュールー", "1箱")]),
        make("oden",         "🍢", "おでん",
             [("大根", "1/2本"), ("卵", "4個"), ("こんにゃく", "1枚"),
              ("ちくわ", "2本"), ("はんぺん", "1枚")]),
        make("sukiyaki",     "🍲", "すき焼き",
             [("牛肉", "400g"), ("白菜", "1/4個"), ("ねぎ", "1本"),
              ("豆腐", "1丁"), ("しらたき", "1袋"), ("春菊", "1束")]),
        make("okonomiyaki",  "🥞", "お好み焼き",
             [("キャベツ", "1/4個"), ("豚バラ肉", "150g"), ("卵", "2個"),
              ("小麦粉", "適量"), ("ソース", "適量")]),
        make("croquette",    "🥔", "コロッケ",
             [("じゃがいも", "4個"), ("合いびき肉", "150g"), ("玉ねぎ", "1個"),
              ("パン粉", "適量")]),
        make("hiyashi",      "🍜", "冷やし中華",
             [("中華麺", "2玉"), ("きゅうり", "1本"), ("ハム", "4枚"),
              ("卵", "2個"), ("トマト", "1個")]),
        make("mabonasu",     "🥘", "麻婆茄子",
             [("なす", "3本"), ("豚ひき肉", "150g"), ("ねぎ", "1本"),
              ("味噌", "大さじ1")]),
        make("ebichili",     "🍤", "エビチリ",
             [("えび", "12尾"), ("ねぎ", "1本"), ("にんにく", "1片"),
              ("ケチャップ", "適量")]),
        make("happosai",     "🥘", "八宝菜",
             [("豚肉", "100g"), ("白菜", "1/4個"), ("にんじん", "1本"),
              ("しいたけ", "3個"), ("うずら卵", "適量")]),
        make("misoshiru",    "🍲", "味噌汁",
             [("豆腐", "1/2丁"), ("わかめ", "適量"), ("ねぎ", "1本"),
              ("味噌", "適量")]),
        make("salad",        "🥗", "サラダ",
             [("レタス", "1/2個"), ("トマト", "1個"), ("きゅうり", "1本"),
              ("ドレッシング", "適量")]),
    ]
}

// MARK: - 献立削除時の材料クリーンアップ(買い物リストから消す材料の判定)

/// 献立を削除したとき、買い物リストから消してよい材料名を求める純粋関数。
/// Firestore に依存しないのでユニットテストから直接呼べる。
/// 「他の残る献立でも使う材料は残す」というルールを表現する。
enum MealPlanIngredientRemoval {
    /// - Parameters:
    ///   - deletedRecipe: 削除する献立のレシピ
    ///   - remainingEntries: 削除後も残る献立エントリ(削除対象は除いておく)
    ///   - recipesById: recipeId → Recipe の対応表
    /// - Returns: 削除対象レシピの材料名のうち、他の残る献立では使わないものの集合。
    ///   実際の削除側では、この集合に一致する「未購入」アイテムのみを消す。
    static func namesToRemove(deletedRecipe: Recipe,
                              remainingEntries: [MealPlanEntry],
                              recipesById: [String: Recipe]) -> Set<String> {
        var keep: Set<String> = []
        for entry in remainingEntries {
            guard let recipe = recipesById[entry.recipeId] else { continue }
            keep.formUnion(recipe.ingredients.map(\.name))
        }
        return Set(deletedRecipe.ingredients.map(\.name)).subtracting(keep)
    }
}

// MARK: - 材料数量の人数スケール(自由入力の数量を人数比で増減する)

/// レシピの材料数量(「200g」「大さじ2」「1/2本」など自由入力)を、
/// 基準人数から目標人数へ比率でスケールする純粋関数。
/// Firestore に依存しないのでユニットテストから直接呼べる(CategoryGuesser と同じ方針)。
///
/// 文字列中に最初に現れる数値(整数・小数・分数 a/b)だけを比率倍し、単位や
/// 「適量」などの非数値部分はそのまま残す。数値が無い/基準が不正な場合は原文を返す。
enum IngredientScaler {
    /// - Parameters:
    ///   - quantity: 元の数量文字列(nil や数値なしはそのまま返す)
    ///   - base: レシピの基準人数(> 0)
    ///   - target: 目標人数(> 0)
    static func scale(_ quantity: String?, from base: Int, to target: Int) -> String? {
        guard let quantity else { return nil }
        guard base > 0, target > 0, base != target else { return quantity }

        let ns = quantity as NSString
        // 最初の数値トークン(分数・小数・整数)を1つだけ対象にする
        guard let regex = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)?(?:/\d+)?"#),
              let match = regex.firstMatch(in: quantity,
                                           range: NSRange(location: 0, length: ns.length)) else {
            return quantity
        }

        let token = ns.substring(with: match.range)
        guard let value = numericValue(of: token) else { return quantity }
        let scaled = formatNumber(value * Double(target) / Double(base))
        return ns.replacingCharacters(in: match.range, with: scaled)
    }

    /// "1/2" → 0.5、"1.5" → 1.5、"200" → 200 を Double へ。解釈できなければ nil。
    private static func numericValue(of token: String) -> Double? {
        if token.contains("/") {
            let parts = token.split(separator: "/")
            guard parts.count == 2,
                  let numerator = Double(parts[0]),
                  let denominator = Double(parts[1]),
                  denominator != 0 else { return nil }
            return numerator / denominator
        }
        return Double(token)
    }

    /// 整数なら小数点なし、端数は小数第2位まで(末尾の0は落とす)で表示する。
    private static func formatNumber(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(Int(rounded.rounded()))
        }
        return String(format: "%.2f", rounded)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

// MARK: - 週間まとめ買い(1週間分の材料の集約)

/// 1週間分の献立から、買い物リストへ追加する材料を品名ごとに集約する純粋関数。
/// Firestore に依存しないのでユニットテストから直接呼べる(CategoryGuesser と同じ方針)。
/// 数量は買い物リストへの展開と同じ比率(レシピの基準人数 → 献立の人数)でスケールし、
/// 同じ品名は1件にまとめる。数量は合算せず、料理ごとの内訳として並べる
/// (買い物リストへの追加も数量を合算しないため、表示と実際の挙動を一致させる)。
enum WeeklyShoppingAggregator {

    /// 集約後の材料1件。
    struct Item: Identifiable, Equatable {
        /// 品名(買い物アイテムの name と一致する)
        var name: String
        /// スケール済みの数量の内訳(同一表記は除く。数量未設定の材料は含めない)。
        /// 例: 玉ねぎ → ["2個", "1個"]
        var quantities: [String]
        /// この材料を使う料理名(出現順・重複なし)。例: ["カレーライス", "肉じゃが"]
        var recipeNames: [String]
        var id: String { name }
    }

    /// - Parameters:
    ///   - entries: 集約対象の献立エントリ(通常は材料未展開のもの)
    ///   - recipesById: recipeId → Recipe
    /// - Returns: 品名の出現順に並べた集約結果。参照先レシピが見つからないエントリは無視する。
    static func aggregate(entries: [MealPlanEntry],
                          recipesById: [String: Recipe]) -> [Item] {
        var order: [String] = []                        // 品名の初出順を保つ
        var quantitiesByName: [String: [String]] = [:]
        var recipesByName: [String: [String]] = [:]

        for entry in entries {
            guard let recipe = recipesById[entry.recipeId] else { continue }
            for ingredient in recipe.ingredients {
                let name = ingredient.name
                guard !name.isEmpty else { continue }
                if quantitiesByName[name] == nil {
                    order.append(name)
                    quantitiesByName[name] = []
                    recipesByName[name] = []
                }
                // 数量は献立の人数に合わせてスケール(買い物リストへの展開時と同じ計算)。
                // すでに同じ表記があれば重ねない(「適量」などが並ぶのを防ぐ)。
                if let scaled = IngredientScaler.scale(ingredient.quantity,
                                                       from: recipe.baseServingsOrDefault,
                                                       to: entry.servingsOrDefault),
                   !(quantitiesByName[name]?.contains(scaled) ?? false) {
                    quantitiesByName[name]?.append(scaled)
                }
                if !(recipesByName[name]?.contains(recipe.name) ?? false) {
                    recipesByName[name]?.append(recipe.name)
                }
            }
        }

        return order.map { name in
            Item(name: name,
                 quantities: quantitiesByName[name] ?? [],
                 recipeNames: recipesByName[name] ?? [])
        }
    }
}
