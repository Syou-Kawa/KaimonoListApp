import SwiftUI
import FirebaseCore

@main
struct KaimonoListApp: App {
    /// 認証・世帯の状態を保持する。Firebase 設定後に生成する必要があるため
    /// プロパティ初期化子ではなく init 内で組み立てる(下記の順序に注意)。
    @State private var session: SessionStore

    init() {
        // SessionStore は生成時に Firestore へ触れるので、
        // 必ず FirebaseApp.configure() を先に済ませてから生成する。
        FirebaseApp.configure()
        _session = State(initialValue: SessionStore())
    }

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .task {
                    // 未サインインのときだけ初期化を走らせる(再描画での重複実行を防ぐ)
                    if case .loading = session.state {
                        await session.bootstrap()
                    }
                }
        }
    }
}

/// セッションの状態に応じて、準備中 / メイン画面 / エラーを出し分ける
private struct RootView: View {
    let session: SessionStore

    var body: some View {
        switch session.state {
        case .loading:
            ProgressView("準備中…")
        case .ready:
            RootTabView(session: session)
        case .failed(let message):
            ContentUnavailableView {
                Label("接続に失敗しました", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("再試行") {
                    Task { await session.bootstrap() }
                }
            }
        }
    }
}
