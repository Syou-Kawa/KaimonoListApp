import SwiftUI
import FirebaseCore

@main
struct KaimonoListApp: App {
    /// 認証・世帯の状態を保持する。Firebase 設定後に生成する必要があるため
    /// プロパティ初期化子ではなく init 内で組み立てる(下記の順序に注意)。
    @State private var session: SessionStore

    init() {
        // ユニットテストはホストアプリ上で実行されるためこの init が走る。
        // テスト時は GoogleService-Info.plist を前提とする Firebase を構成せず、
        // Firestore にも触れない(ロジックのテストに Firebase は不要)。
        if !Self.isRunningUnitTests {
            FirebaseApp.configure()
        }
        _session = State(initialValue: SessionStore())
    }

    var body: some Scene {
        WindowGroup {
            if Self.isRunningUnitTests {
                // Firebase 未構成のため、テスト時は bootstrap を呼ばず空表示にする
                Color.clear
            } else {
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

    /// XCTest / Swift Testing のホスト実行中かどうか。テスト時は
    /// 環境変数 XCTestConfigurationFilePath がテストランナーによって設定される。
    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

/// セッションの状態に応じて、準備中 / メイン画面 / エラーを出し分ける
private struct RootView: View {
    let session: SessionStore

    var body: some View {
        switch session.state {
        case .loading:
            ProgressView("準備中…")
        case .signedOut:
            SignInView(session: session)
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
