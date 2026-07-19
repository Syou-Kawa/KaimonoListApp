import SwiftUI

// MARK: - ウィジェット表示レイアウト

/// ホーム画面ウィジェットの中身。App Group 共有スナップショットを描画する。
/// ウィジェット拡張ターゲットからも、アプリ内プレビューからも使えるよう、
/// WidgetKit に依存しない純粋な SwiftUI View にしている(サイズは isCompact で切り替え)。
struct ShoppingWidgetView: View {
    let snapshot: SharedShoppingSnapshot
    /// small サイズは true(表示件数を絞る)、medium は false。
    var isCompact: Bool

    /// サイズごとの最大表示件数(残りは「他N件」に集約)。
    private var visibleLimit: Int { isCompact ? 3 : 5 }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 6 : 8) {
            header

            if snapshot.uncheckedItems.isEmpty {
                emptyState
            } else {
                itemList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: 部品

    /// 「買うもの」見出し + 残り件数バッジ。
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "cart.fill")
                .font(.caption)
                .foregroundStyle(.green)
            Text("買うもの")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 4)
            if snapshot.uncheckedCount > 0 {
                Text("\(snapshot.uncheckedCount)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.green, in: Capsule())
            }
        }
    }

    /// 未購入アイテムを売り場(カテゴリ)順に表示。上限を超えた分は「他N件」。
    private var itemList: some View {
        VStack(alignment: .leading, spacing: isCompact ? 4 : 5) {
            ForEach(snapshot.uncheckedItems.prefix(visibleLimit)) { item in
                HStack(spacing: 6) {
                    Text(item.categoryEmoji)
                        .font(.caption)
                    Text(item.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let quantity = item.quantity, !quantity.isEmpty {
                        Text(quantity)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            let remaining = snapshot.uncheckedCount - min(snapshot.uncheckedItems.count, visibleLimit)
            if remaining > 0 {
                Text("他 \(remaining) 件")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
            }
        }
    }

    /// 未購入が無いときの表示。
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Label("リストは空です", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - プレビュー(サンプルデータ)

extension SharedShoppingSnapshot {
    /// プレビュー・デモ用のサンプル。実データの売り場順を模したもの。
    static let sample = SharedShoppingSnapshot(
        uncheckedItems: [
            .init(id: "1", name: "にんじん", quantity: "2本", categoryEmoji: "🥬"),
            .init(id: "2", name: "玉ねぎ", quantity: "3個", categoryEmoji: "🥬"),
            .init(id: "3", name: "豚こま肉", quantity: "300g", categoryEmoji: "🥩"),
            .init(id: "4", name: "牛乳", quantity: "1本", categoryEmoji: "🥚"),
            .init(id: "5", name: "卵", quantity: "1パック", categoryEmoji: "🥚"),
            .init(id: "6", name: "食パン", quantity: nil, categoryEmoji: "🍞"),
            .init(id: "7", name: "ヨーグルト", quantity: "2個", categoryEmoji: "🥚"),
            .init(id: "8", name: "トイレットペーパー", quantity: nil, categoryEmoji: "🧻"),
        ],
        uncheckedCount: 8,
        updatedAt: Date()
    )
}

/// small サイズ相当(約 170×170pt)。
#Preview("Small") {
    ShoppingWidgetView(snapshot: .sample, isCompact: true)
        .padding(16)
        .frame(width: 170, height: 170)
        .background(Color(white: 0.98))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .padding()
}

/// medium サイズ相当(約 360×170pt)。
#Preview("Medium") {
    ShoppingWidgetView(snapshot: .sample, isCompact: false)
        .padding(16)
        .frame(width: 360, height: 170)
        .background(Color(white: 0.98))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .padding()
}

/// 空リストの表示。
#Preview("Empty") {
    ShoppingWidgetView(snapshot: .empty, isCompact: true)
        .padding(16)
        .frame(width: 170, height: 170)
        .background(Color(white: 0.98))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .padding()
}
