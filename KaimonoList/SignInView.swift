import SwiftUI
import AuthenticationServices

/// サインインゲート。未サインインのときに表示し、Apple でのサインインを促す。
/// サインインが成立すると SessionStore の状態が .ready に変わり、RootView がメイン画面へ切り替える。
struct SignInView: View {
    let session: SessionStore

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "cart.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text("かいものリスト")
                    .font(.largeTitle.bold())
                Text("家族と共有できる買い物リストと献立プランナー")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 12) {
                SignInWithAppleButton(.signIn) { request in
                    session.prepareAppleRequest(request)
                } onCompletion: { result in
                    Task { await session.handleAppleSignIn(result) }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)

                Text("サインインすると、端末を変えても同じリストに戻れます。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .padding()
        .alert("サインインに失敗しました", isPresented: authErrorBinding) {
            Button("OK") { session.authErrorMessage = nil }
        } message: {
            Text(session.authErrorMessage ?? "")
        }
    }

    private var authErrorBinding: Binding<Bool> {
        Binding(
            get: { session.authErrorMessage != nil },
            set: { if !$0 { session.authErrorMessage = nil } }
        )
    }
}
