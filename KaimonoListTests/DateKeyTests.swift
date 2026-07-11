import Foundation
import Testing
@testable import KaimonoList

/// 献立の日付キー("yyyy-MM-dd")変換の検証。
/// 端末タイムゾーンの暦日をキーにし、文字列の辞書順 = 日付順になることが要件。
@MainActor
struct DateKeyTests {

    /// 端末カレンダーで指定年月日の 12:00(タイムゾーン境界の影響を避ける)を作る
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return Calendar.current.date(from: components)!
    }

    @Test("年月日が yyyy-MM-dd 形式に変換される")
    func formatsAsISODate() {
        #expect(MealPlannerViewModel.dateKey(date(2026, 7, 11)) == "2026-07-11")
    }

    @Test("1桁の月日はゼロ埋めされる")
    func padsSingleDigits() {
        #expect(MealPlannerViewModel.dateKey(date(2026, 1, 5)) == "2026-01-05")
    }

    @Test("文字列の辞書順が日付の前後関係と一致する")
    func lexicographicOrderMatchesChronological() {
        let earlier = MealPlannerViewModel.dateKey(date(2026, 7, 11))
        let sameMonthLater = MealPlannerViewModel.dateKey(date(2026, 7, 12))
        let nextMonth = MealPlannerViewModel.dateKey(date(2026, 8, 1))
        let nextYear = MealPlannerViewModel.dateKey(date(2027, 1, 1))

        #expect(earlier < sameMonthLater)
        #expect(sameMonthLater < nextMonth)
        #expect(nextMonth < nextYear)
    }

    @Test("同じ暦日は同じキーになる(時刻が違っても)")
    func sameDayProducesSameKey() {
        let noon = date(2026, 7, 11)
        let evening = Calendar.current.date(byAdding: .hour, value: 8, to: noon)!
        #expect(MealPlannerViewModel.dateKey(noon) == MealPlannerViewModel.dateKey(evening))
    }
}
