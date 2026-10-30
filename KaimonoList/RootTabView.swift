import SwiftUI

/// サインイン完了後のルート画面。買い物リスト・献立プランナー・記録・家計簿・共有をタブで切り替える。
/// App ファイル側では、これまでの ShoppingListView(...) の代わりに RootTabView(session:) を表示する。
///
/// 世帯の切り替え(招待コードでの参加・退出)に追従するため SessionStore を受け取り、
/// アクティブな householdId を .id に与えることで、切り替え時に各タブの ViewModel を作り直す。
struct RootTabView: View {
    let session: SessionStore

    /// 初回起動時のチュートリアルを表示済みか。true になると次回以降は出さない。
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        if case let .ready(uid, householdId) = session.state {
            TabView {
                ShoppingListView(
                    householdId: householdId,
                    currentUid: uid,
                    currentUserName: session.displayName
                )
                .tabItem { Label("リスト", systemImage: "cart") }

                MealPlanView(
                    householdId: householdId,
                    currentUid: uid,
                    currentUserName: session.displayName
                )
                .tabItem { Label("献立", systemImage: "fork.knife") }

                MealHistoryView(
                    householdId: householdId,
                    currentUid: uid,
                    currentUserName: session.displayName
                )
                .tabItem { Label("記録", systemImage: "clock.arrow.circlepath") }

                ReceiptBookView(
                    householdId: householdId,
                    currentUid: uid,
                    currentUserName: session.displayName
                )
                .tabItem { Label("家計簿", systemImage: "yensign.circle") }

                HouseholdView(session: session)
                    .tabItem { Label("共有", systemImage: "person.2") }
            }
            // householdId が変わったらリスト・献立タブの ViewModel を作り直す
            .id(householdId)
            // 初回のみチュートリアルを全画面で表示する
            .fullScreenCover(isPresented: .constant(!hasCompletedOnboarding)) {
                OnboardingView {
                    hasCompletedOnboarding = true
                }
            }
        }
    }
}
