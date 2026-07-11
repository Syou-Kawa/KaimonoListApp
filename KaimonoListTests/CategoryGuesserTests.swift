import Testing
@testable import KaimonoList

/// CategoryGuesser の品名→カテゴリ推定ロジックの検証。
/// ルールは配列の上から順に評価されるため、「優先度」が正しく効くかが重要。
@MainActor
struct CategoryGuesserTests {

    @Test("代表的な品名がそれぞれ想定カテゴリに推定される")
    func guessesCommonItems() {
        #expect(CategoryGuesser.guessKey(from: "にんじん") == "produce")
        #expect(CategoryGuesser.guessKey(from: "豚こま肉") == "meat")
        #expect(CategoryGuesser.guessKey(from: "牛乳") == "dairyEgg")
        #expect(CategoryGuesser.guessKey(from: "絹ごし豆腐") == "tofu")
        #expect(CategoryGuesser.guessKey(from: "醤油") == "seasoning")
        #expect(CategoryGuesser.guessKey(from: "トイレットペーパー") == "daily")
    }

    @Test("空文字は nil を返す")
    func emptyStringReturnsNil() {
        #expect(CategoryGuesser.guessKey(from: "") == nil)
    }

    @Test("どのキーワードにも当たらない品名は nil を返す")
    func unknownItemReturnsNil() {
        #expect(CategoryGuesser.guessKey(from: "謎の新商品") == nil)
    }

    // MARK: - ルール優先度(順序依存)の検証

    @Test("「冷凍うどん」は麺ではなく冷凍食品に推定される(frozen が noodleDry より前)")
    func frozenBeatsNoodle() {
        #expect(CategoryGuesser.guessKey(from: "冷凍うどん") == "frozen")
    }

    @Test("「牛乳」は肉ではなく乳製品に推定される(dairyEgg が meat より前)")
    func milkIsDairyNotMeat() {
        // 「牛」を含むが、dairyEgg ルールの「牛乳」が先に評価される
        #expect(CategoryGuesser.guessKey(from: "牛乳") == "dairyEgg")
    }

    @Test("「ツナ缶」は魚介ではなく缶詰に推定される(cannedInstant が seafood より前)")
    func cannedTunaIsCanned() {
        #expect(CategoryGuesser.guessKey(from: "ツナ缶") == "cannedInstant")
    }

    @Test("部分一致で推定される(前後に文字があっても当たる)")
    func matchesAsSubstring() {
        #expect(CategoryGuesser.guessKey(from: "国産若鶏もも肉 300g") == "meat")
    }
}
