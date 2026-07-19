import SwiftUI

/// 初回インストール時に表示する簡単なチュートリアル。
/// 3つのタブ(買い物リスト・献立・共有)の使い方をページ送りで紹介する。
/// 表示済みかどうかは AppStorage("hasCompletedOnboarding") で管理し、
/// 一度「はじめる」を押すと次回以降は表示しない。
struct OnboardingView: View {
    /// 完了時に呼ばれる。呼び出し側でフラグを保存し、シートを閉じる。
    let onFinish: () -> Void

    @State private var currentPage = 0

    /// 紹介ページの内容。順序がそのまま表示順になる。
    private let pages: [OnboardingPage] = [
        OnboardingPage(
            symbol: "cart.fill",
            tint: .green,
            title: "ようこそ!",
            message: "買うものリストと献立を家族みんなで共有できるアプリです。まずは基本的な使い方を見てみましょう。"
        ),
        OnboardingPage(
            symbol: "cart.badge.plus",
            tint: .green,
            title: "買い物リスト",
            message: "右上の + から買うものを追加。品名から売り場のカテゴリを自動で振り分けるので、お店で回りやすい順に並びます。買えたらタップでチェック。"
        ),
        OnboardingPage(
            symbol: "fork.knife",
            tint: .orange,
            title: "献立プランナー",
            message: "1週間分の献立を決めて、必要な材料をまとめて買い物リストへ。レシピ帳に登録しておけば、毎週の献立づくりがぐっと楽になります。"
        ),
        OnboardingPage(
            symbol: "clock.arrow.circlepath",
            tint: .pink,
            title: "記録をふり返る",
            message: "「記録」タブでは、これまで作った献立を月ごとのカレンダーでふり返れます。◀▶や年月の選択で好きな月へジャンプ。作ったものを後から記録することもできるので、家族の食事の記録として残せます。"
        ),
        OnboardingPage(
            symbol: "person.2.fill",
            tint: .blue,
            title: "家族と共有",
            message: "「共有」タブの招待コードを家族に伝えると、同じリストと献立をリアルタイムで共有できます。誰が追加したかも一目で分かります。"
        ),
        OnboardingPage(
            symbol: "square.grid.2x2.fill",
            tint: .purple,
            title: "ホーム画面ウィジェット",
            message: "買うものリストはホーム画面にも置けます。アプリを開かなくても残りの品数がひと目で分かって便利。ホーム画面を長押し → 左上の + →「買い物リスト」で追加できます。便利そうなら試してみてください。"
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // スキップ(最終ページ以外で表示)
            HStack {
                Spacer()
                if currentPage < pages.count - 1 {
                    Button("スキップ") { onFinish() }
                        .padding()
                }
            }
            .frame(height: 44)

            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    OnboardingPageView(page: page)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            actionButton
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        let isLast = currentPage == pages.count - 1
        Button {
            if isLast {
                onFinish()
            } else {
                withAnimation { currentPage += 1 }
            }
        } label: {
            Text(isLast ? "はじめる" : "次へ")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

// MARK: - ページのデータ

private struct OnboardingPage {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
}

// MARK: - 1ページ分の表示

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: page.symbol)
                .font(.system(size: 84))
                .foregroundStyle(page.tint)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 16) {
                Text(page.title)
                    .font(.title.bold())

                Text(page.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
        }
    }
}

#Preview {
    OnboardingView(onFinish: {})
}
