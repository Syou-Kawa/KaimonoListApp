import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore

/// 認証と世帯(household)の初期化を担当。
/// 現状は開発用の匿名認証。リリース前に Sign in with Apple へ置き換える
/// (匿名アカウントは Auth.auth().currentUser.link(with:) で本アカウントに昇格でき、
///  UID が変わらないので Firestore のデータはそのまま引き継げる)。
@MainActor
@Observable
final class SessionStore {

    enum State {
        case loading
        case ready(uid: String, householdId: String)
        case failed(String)
    }

    private(set) var state: State = .loading

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

    /// 一覧の「誰が追加したか」表示に使う名前。
    /// 設定画面を作るまでの暫定として UserDefaults を参照
    var displayName: String {
        UserDefaults.standard.string(forKey: "displayName") ?? "わたし"
    }

    private let db = Firestore.firestore()
    private let householdIdKey = "householdId"

    func bootstrap() async {
        state = .loading
        do {
            // 1. サインイン(既存セッションがあれば再利用)
            let uid: String
            if let user = Auth.auth().currentUser {
                uid = user.uid
            } else {
                let result = try await Auth.auth().signInAnonymously()
                uid = result.user.uid
            }

            // 2. 世帯の用意(保存済みIDがあればそれを、なければ新規作成)
            let householdId = try await ensureHousehold(uid: uid)

            // 3. 初期カテゴリのシード(空の場合のみ。既存世帯のアップグレードも兼ねる)
            try await seedDefaultCategoriesIfNeeded(householdId: householdId)

            // 4. 招待コード → 世帯ID の対応表を用意(既存世帯のアップグレードも兼ねる)
            try await ensureInviteCodeMapping(householdId: householdId)

            state = .ready(uid: uid, householdId: householdId)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func ensureHousehold(uid: String) async throws -> String {
        if let saved = UserDefaults.standard.string(forKey: householdIdKey), !saved.isEmpty {
            return saved
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
        let ref = try await db.collection("households").addDocument(from: household)
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
    }

    /// 現在の世帯から退出する。自分を memberIds / memberNames から外し、
    /// 新しい自分専用の世帯を用意し直す
    func leaveHousehold() async throws {
        guard let uid = currentUid, let householdId = currentHouseholdId else {
            throw JoinError.notSignedIn
        }

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

    /// 紛らわしい文字(0/O、1/I/L)を除いた6桁の招待コード
    private static func makeInviteCode() -> String {
        let chars = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
        return String((0..<6).compactMap { _ in chars.randomElement() })
    }
}
