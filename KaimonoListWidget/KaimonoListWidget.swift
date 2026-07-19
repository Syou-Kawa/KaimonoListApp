import WidgetKit
import SwiftUI

// MARK: - タイムライン

/// ウィジェット1コマ分のデータ。App Group 共有領域から読んだ買い物リストを持つ。
struct ShoppingEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedShoppingSnapshot
}

/// 共有スナップショットを読み込んでタイムラインを組み立てる。
/// アプリがリスト更新のたびに `WidgetCenter.reloadAllTimelines()` を呼ぶので、
/// ここでは1コマだけ返し、フォールバックとして数時間後に再読込する。
struct Provider: TimelineProvider {
    /// ギャラリー等でのプレースホルダ表示用のサンプル。
    func placeholder(in context: Context) -> ShoppingEntry {
        ShoppingEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (ShoppingEntry) -> Void) {
        // プレビュー(ギャラリー)ではサンプル、実際の配置では共有データを表示する
        let snapshot = context.isPreview ? .sample : SharedShoppingStore.load()
        completion(ShoppingEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ShoppingEntry>) -> Void) {
        let entry = ShoppingEntry(date: Date(), snapshot: SharedShoppingStore.load())
        // アプリからの reload が主だが、念のため数時間後にも再読込する
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 6, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

// MARK: - 表示

/// ウィジェットの中身。サイズ(family)に応じて表示件数を切り替える。
struct KaimonoListWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: Provider.Entry

    var body: some View {
        ShoppingWidgetView(snapshot: entry.snapshot, isCompact: family == .systemSmall)
    }
}

// MARK: - ウィジェット定義

struct KaimonoListWidget: Widget {
    let kind = "KaimonoListWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            KaimonoListWidgetEntryView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("買い物リスト")
        .description("未購入のアイテムをホーム画面で確認できます。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - プレビュー

#Preview("Small", as: .systemSmall) {
    KaimonoListWidget()
} timeline: {
    ShoppingEntry(date: .now, snapshot: .sample)
}

#Preview("Medium", as: .systemMedium) {
    KaimonoListWidget()
} timeline: {
    ShoppingEntry(date: .now, snapshot: .sample)
}
