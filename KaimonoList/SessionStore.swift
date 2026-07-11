import Foundation
import Observation
import CryptoKit
import AuthenticationServices
import FirebaseAuth
import FirebaseFirestore

/// 認証と世帯(household)の初期化を担当。
/// 認証は Sign in with Apple のみ。サインインしないとアプリを利用できない
/// (サインインゲート方式)。アカウントに UID が紐づくので、
/// 端末変更・再インストール後も同じ世帯データに復帰できる。
@MainActor
@Observable
final class SessionStore {

    enum State {
        case loading
        case signedOut
        case ready(uid: String, householdId: String)
        case failed(String)
    }

    private(set) var state: State = .loading

    /// サインイン画面に表示する認証エラー(ユーザーによるキャンセルは対象外)
    var authErrorMessage: String?

    /// アカウント削除の進行中フラグ(削除シートのプログレス表示に使う)
    var isDeletingAccount = false

    /// アカウント削除時のエラー(ユーザーによるキャンセルは対象外)
    var deletionErrorMessage: String?

    /// 現在サインイン中の UID(未確定なら nil)
    var currentUid: String? {
        if case let .ready(uid, _) = state { return uid }
        return nil
    }

    /// 現在アクティブな世帯ID(未確定なら nil)
    var currentHouseholdId: String? {
        if case let .ready(_, householdId) = state { return householdId }
        return nil
    }

    /// 一覧の「誰が追加したか」表示に使う名前。設定画面から変更でき、
    /// 初回サインイン時には Apple から取得した氏名を既定値として採用する。
    /// 変更は UserDefaults に永続化する(@Observable で画面にも反映される)。
    var displayName: String {
        didSet { UserDefaults.standard.set(displayName, forKey: displayNameKey) }
    }

    // Firestore への参照は初回アクセス時に生成する。SessionStore の生成自体では
    // Firebase に触れないため、Firebase 未構成のユニットテスト環境でも安全に初期化できる。
    @ObservationIgnored private lazy var db = Firestore.firestore()
    private let householdIdKey = "householdId"
    private let displayNameKey = "displayName"

    init() {
        displayName = UserDefaults.standard.string(forKey: displayNameKey) ?? "わたし"
    }

    /// Sign in with Apple のリプレイ攻撃対策 nonce。リクエスト時に生成し、
    /// 完了時に Firebase へ rawNonce として渡す
    private var currentNonce: String?

    // MARK: - 起動時の状態判定

    /// 既存の Apple サインインセッションがあればそのまま復帰、なければサインイン画面へ。
    func bootstrap() async {
        state = .loading
        if let user = Auth.auth().currentUser, !user.isAnonymous {
            do {
                try await completeSetup(uid: user.uid)
            } catch {
                state = .failed(error.localizedDescription)
            }
        } else {
            // 旧ビルドの匿名アカウントが残っていたらサインアウトしておく
            if Auth.auth().currentUser != nil {
                try? Auth.auth().signOut()
            }
            state = .signedOut
        }
    }

    /// サインイン成立後に共通で行う世帯まわりの初期化。
    private func completeSetup(uid: String) async throws {
        let householdId = try await ensureHousehold(uid: uid)
        try await seedDefaultCategoriesIfNeeded(householdId: householdId)
        try await ensureInviteCodeMapping(householdId: householdId)
        state = .ready(uid: uid, householdId: householdId)
        registerForPush(uid: uid, householdId: householdId)
    }

    /// 共有メンバーからの追加通知を受け取れるよう、通知許可を求めて
    /// デバイストークンをこの世帯に登録する。世帯が確定するたびに呼ぶ。
    private func registerForPush(uid: String, householdId: String) {
        PushManager.shared.updateContext(householdId: householdId, uid: uid)
        PushManager.shared.requestAuthorizationAndRegister()
    }

    // MARK: - Sign in with Apple

    /// SignInWithAppleButton の onRequest で呼ぶ。要求スコープと nonce を設定する。
    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.fullName]
        request.nonce = Self.sha256(nonce)
    }

    /// SignInWithAppleButton の onCompletion で呼ぶ。
    /// Apple の資格情報を Firebase の認証情報に変換してサインインする。
    func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        defer { currentNonce = nil }

        switch result {
        case .failure(let error):
            // ユーザーが自分でキャンセルした場合はエラー表示しない
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return
            }
            authErrorMessage = error.localizedDescription

        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                authErrorMessage = "Apple の認証情報を取得できませんでした。"
                return
            }
            guard let nonce = currentNonce else {
                authErrorMessage = "認証リクエストが正しく初期化されていません。もう一度お試しください。"
                return
            }
            guard let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                authErrorMessage = "ID トークンを取得できませんでした。"
                return
            }

            state = .loading
            do {
                let firebaseCredential = OAuthProvider.appleCredential(
                    withIDToken: idToken,
                    rawNonce: nonce,
                    fullName: credential.fullName
                )
                let authResult = try await Auth.auth().signIn(with: firebaseCredential)
                // 氏名は初回サインイン時のみ Apple から渡される。未設定なら表示名として保存
                storeDisplayNameIfNeeded(from: credential.fullName,
                                         fallback: authResult.user.displayName)
                try await completeSetup(uid: authResult.user.uid)
            } catch {
                authErrorMessage = error.localizedDescription
                state = .signedOut
            }
        }
    }

    /// サインアウトしてサインイン画面へ戻す。
    /// 端末に保存したアクティブ世帯IDは残す(同じアカウントなら次回そのまま復帰でき、
    /// 別アカウントがサインインした場合は ensureHousehold 側でメンバー判定して弾く)。
    func signOut() {
        Task { await PushManager.shared.clearRegistration() }
        do {
            try Auth.auth().signOut()
            state = .signedOut
        } catch {
            authErrorMessage = error.localizedDescription
        }
    }

    // MARK: - アカウント削除(退会)

    /// アカウントを削除する(App Store ガイドライン 5.1.1(v) 対応)。
    /// 破壊的操作のため、削除シートの SignInWithAppleButton で本人確認(再認証)を求め、
    /// その結果を受け取ってから実行する。処理の流れ:
    /// 1. 取得し直した Apple 資格情報で再認証(`user.delete()` の直近サインイン要件を満たす)
    /// 2. 世帯からの離脱(デバイストークン削除 → memberIds/memberNames から自分を除去)
    /// 3. Apple 側の連携トークンを失効(Sign in with Apple の要件)
    /// 4. Firebase の認証アカウント本体を削除
    /// - Parameter result: 削除シートの SignInWithAppleButton から渡される再認証結果
    func deleteAccount(reauthResult result: Result<ASAuthorization, Error>) async {
        defer { currentNonce = nil }

        switch result {
        case .failure(let error):
            // ユーザーが自分でキャンセルした場合はエラー表示しない
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return
            }
            deletionErrorMessage = error.localizedDescription

        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let nonce = currentNonce,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8),
                  let codeData = credential.authorizationCode,
                  let authCode = String(data: codeData, encoding: .utf8),
                  let user = Auth.auth().currentUser else {
                deletionErrorMessage = "認証情報を取得できませんでした。もう一度お試しください。"
                return
            }

            isDeletingAccount = true
            defer { isDeletingAccount = false }
            do {
                // 1. 直近サインインとして本人確認をやり直す
                let firebaseCredential = OAuthProvider.appleCredential(
                    withIDToken: idToken,
                    rawNonce: nonce,
                    fullName: nil
                )
                try await user.reauthenticate(with: firebaseCredential)

                // 2. 認証が有効なうちに世帯データから自分を外す(共有データ自体は残す)
                await removeSelfFromHouseholdForDeletion(uid: user.uid)

                // 3. Apple 側のトークンを失効(Sign in with Apple 利用アプリの要件)
                try await Auth.auth().revokeToken(withAuthorizationCode: authCode)

                // 4. 認証アカウント本体を削除
                try await user.delete()

                // 端末に残るキャッシュを片付けてサインイン画面へ戻す
                UserDefaults.standard.removeObject(forKey: householdIdKey)
                UserDefaults.standard.removeObject(forKey: displayNameKey)
                state = .signedOut
            } catch {
                deletionErrorMessage = error.localizedDescription
            }
        }
    }

    /// アカウント削除時に、現在の世帯から自分を取り除く(退出に相当。ただし
    /// 新しい世帯は作らない)。共有データは他のメンバーが引き続き利用できる。
    /// 認証アカウント削除を最優先とするため、世帯側の後片付けは失敗しても続行する。
    private func removeSelfFromHouseholdForDeletion(uid: String) async {
        // memberIds から外れると deviceTokens への書き込みがルールで拒否されるため、
        // 先にこの端末のトークン登録を消しておく。
        await PushManager.shared.clearRegistration()

        guard let householdId = currentHouseholdId else { return }
        try? await db.collection("households").document(householdId).updateData([
            "memberIds": FieldValue.arrayRemove([uid]),
            "memberNames.\(uid)": FieldValue.delete(),
        ])
    }

    private func storeDisplayNameIfNeeded(from fullName: PersonNameComponents?, fallback: String?) {
        // ユーザーがまだ表示名を保存していないときだけ Apple の氏名を採用する
        // (UserDefaults にキーが存在する = 既に設定済み)
        guard UserDefaults.standard.string(forKey: displayNameKey) == nil else { return }

        let formatter = PersonNameComponentsFormatter()
        if let fullName {
            let formatted = formatter.string(from: fullName)
            if !formatted.isEmpty {
                displayName = formatted
                return
            }
        }
        if let fallback, !fallback.isEmpty {
            displayName = fallback
        }
    }

    // MARK: - 世帯の用意

    /// サインインしたアカウントが利用する世帯IDを返す。
    /// 1. 端末に保存されたアクティブ世帯が、まだ自分がメンバーならそれを使う
    /// 2. 別端末・再インストール時は所属世帯を検索して復帰する
    /// 3. どこにも属していなければ新規作成する
    private func ensureHousehold(uid: String) async throws -> String {
        if let saved = UserDefaults.standard.string(forKey: householdIdKey), !saved.isEmpty {
            // 保存済み世帯がまだ有効かを確認する。読めない場合(別端末での退出などで
            // メンバーから外れ権限エラーになる、または世帯が消えている)は throw せず、
            // try? で無視して所属世帯の再検索・新規作成へフォールバックする。
            if let doc = try? await db.collection("households").document(saved).getDocument(),
               let memberIds = doc.data()?["memberIds"] as? [String], memberIds.contains(uid) {
                return saved
            }
        }

        let query = try await db.collection("households")
            .whereField("memberIds", arrayContains: uid)
            .limit(to: 1)
            .getDocuments()
        if let doc = query.documents.first {
            UserDefaults.standard.set(doc.documentID, forKey: householdIdKey)
            return doc.documentID
        }

        let inviteCode = Self.makeInviteCode()
        let household = Household(
            id: nil,
            name: "わが家",
            memberIds: [uid],
            memberNames: [uid: displayName],
            inviteCode: inviteCode,
            createdAt: nil  // @ServerTimestamp: nil のままだとサーバー時刻が入る
        )
        let ref = try db.collection("households").addDocument(from: household)
        UserDefaults.standard.set(ref.documentID, forKey: householdIdKey)

        // 招待コード → 世帯ID の対応表も同時に作る(参加時の逆引き用)
        try await inviteCodeRef(inviteCode).setData(["householdId": ref.documentID])
        return ref.documentID
    }

    /// inviteCodes/{code} ドキュメント参照。コードは大文字で正規化する
    private func inviteCodeRef(_ code: String) -> DocumentReference {
        db.collection("inviteCodes").document(code.uppercased())
    }

    /// 既存世帯には inviteCodes 対応表が無いことがあるので、無ければ作成する
    private func ensureInviteCodeMapping(householdId: String) async throws {
        let householdRef = db.collection("households").document(householdId)
        let snapshot = try await householdRef.getDocument()
        guard let code = snapshot.data()?["inviteCode"] as? String, !code.isEmpty else { return }

        let mappingRef = inviteCodeRef(code)
        let mapping = try await mappingRef.getDocument()
        if !mapping.exists {
            try await mappingRef.setData(["householdId": householdId])
        }
    }

    // MARK: - 世帯への参加・退出

    enum JoinError: LocalizedError {
        case codeNotFound
        case notSignedIn

        var errorDescription: String? {
            switch self {
            case .codeNotFound: return "そのコードの世帯は見つかりません。コードをご確認ください。"
            case .notSignedIn:  return "サインインが完了していません。少し待って再度お試しください。"
            }
        }
    }

    /// 招待コードで既存世帯に参加する。成功すると自分を memberIds に追加し、
    /// アクティブな世帯を切り替える(元の自動生成世帯は空のまま残る)
    func joinHousehold(code: String) async throws {
        guard let uid = currentUid else { throw JoinError.notSignedIn }

        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { throw JoinError.codeNotFound }

        // 1. コードから世帯IDを逆引き
        let mapping = try await inviteCodeRef(normalized).getDocument()
        guard mapping.exists, let householdId = mapping.data()?["householdId"] as? String else {
            throw JoinError.codeNotFound
        }

        // 2. 自分だけを memberIds に追加(ルールで許可された更新)
        try await db.collection("households").document(householdId).updateData([
            "memberIds": FieldValue.arrayUnion([uid]),
            "memberNames.\(uid)": displayName,
        ])

        // 3. アクティブな世帯を切り替える
        UserDefaults.standard.set(householdId, forKey: householdIdKey)
        state = .ready(uid: uid, householdId: householdId)
        registerForPush(uid: uid, householdId: householdId)
    }

    /// 現在の世帯から退出する。自分を memberIds / memberNames から外し、
    /// 新しい自分専用の世帯を用意し直す
    func leaveHousehold() async throws {
        guard let uid = currentUid, let householdId = currentHouseholdId else {
            throw JoinError.notSignedIn
        }

        // memberIds から外れると deviceTokens への書き込みがルールで拒否されるため、
        // 退出処理より先にこの世帯のトークン登録を消しておく。
        await PushManager.shared.clearRegistration()

        try await db.collection("households").document(householdId).updateData([
            "memberIds": FieldValue.arrayRemove([uid]),
            "memberNames.\(uid)": FieldValue.delete(),
        ])

        // 保存済みIDを消し、bootstrap で新しい世帯を作り直す
        UserDefaults.standard.removeObject(forKey: householdIdKey)
        await bootstrap()
    }

    /// categories コレクションが空なら初期カテゴリを一括投入する
    private func seedDefaultCategoriesIfNeeded(householdId: String) async throws {
        let categoriesRef = db.collection("households")
            .document(householdId)
            .collection("categories")

        let snapshot = try await categoriesRef.limit(to: 1).getDocuments()
        guard snapshot.isEmpty else { return }

        let batch = db.batch()
        for (index, seed) in DefaultCategories.seeds.enumerated() {
            let doc = categoriesRef.document()
            batch.setData([
                "name": seed.name,
                "emoji": seed.emoji,
                "sortOrder": index * 100,   // 間隔を空けておくと将来の挿入・並び替えが楽
                "matcherKey": seed.key,
                "createdAt": FieldValue.serverTimestamp(),
            ], forDocument: doc)
        }
        try await batch.commit()
    }

    // MARK: - nonce ユーティリティ(Sign in with Apple)

    /// 紛らわしい文字(0/O、1/I/L)を除いた6桁の招待コード
    private static func makeInviteCode() -> String {
        let chars = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
        return String((0..<6).compactMap { _ in chars.randomElement() })
    }

    /// リプレイ攻撃対策のランダム nonce を生成する
    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] =
            Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length

        while remaining > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            guard status == errSecSuccess else {
                fatalError("Unable to generate nonce. SecRandomCopyBytes failed with \(status)")
            }
            for random in randoms where remaining > 0 {
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remaining -= 1
                }
            }
        }
        return result
    }

    /// nonce を SHA256 でハッシュ化(Apple へはハッシュを渡し、Firebase へは生値を渡す)
    private static func sha256(_ input: String) -> String {
        let hashed = SHA256.hash(data: Data(input.utf8))
        return hashed.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Firestore エラー判定

extension Error {
    /// Firestore の「メンバーから外れて読めなくなった」権限エラーかどうか。
    /// 世帯からの退出・切り替え時、まだ生きているリスナーが一斉に発火して自然に起きる。
    /// (同じ Apple ID の別端末では uid を共有するため、片方が退出すると両方で発生する)
    /// ユーザー向けの警告として扱うべきではないので、この判定で握りつぶす。
    var isFirestorePermissionDenied: Bool {
        let nsError = self as NSError
        return nsError.domain == FirestoreErrorDomain
            && nsError.code == FirestoreErrorCode.permissionDenied.rawValue
    }
}
