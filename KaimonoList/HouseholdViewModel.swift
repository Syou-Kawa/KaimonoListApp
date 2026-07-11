import Foundation
import Observation
import FirebaseFirestore

/// 世帯(household)ドキュメントの購読と編集を担当。
/// 招待コード・世帯名・メンバー一覧を共有メンバー全員にリアルタイム同期する。
/// 参加・退出そのものは SessionStore が担う(アクティブ世帯の切り替えを伴うため)。
@MainActor
@Observable
final class HouseholdViewModel {

    // MARK: - 状態

    private(set) var household: Household?
    var errorMessage: String?

    /// 招待コード(未取得なら空文字)
    var inviteCode: String { household?.inviteCode ?? "" }

    /// 世帯名(未取得なら暫定表示)
    var householdName: String { household?.name ?? "わが家" }

    /// 表示用のメンバー一覧。自分を先頭に、以降は名前順で並べる
    var members: [Member] {
        guard let household else { return [] }
        let rows = household.memberIds.map { uid in
            Member(
                uid: uid,
                name: household.memberNames?[uid] ?? "メンバー",
                isCurrentUser: uid == currentUid
            )
        }
        return rows.sorted { lhs, rhs in
            if lhs.isCurrentUser != rhs.isCurrentUser { return lhs.isCurrentUser }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    struct Member: Identifiable {
        let uid: String
        let name: String
        let isCurrentUser: Bool
        var id: String { uid }
    }

    // MARK: - 依存

    let householdId: String
    let currentUid: String

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?

    private var householdRef: DocumentReference {
        db.collection("households").document(householdId)
    }

    init(householdId: String, currentUid: String) {
        self.householdId = householdId
        self.currentUid = currentUid
    }

    // MARK: - リアルタイム同期

    func startListening() {
        stopListening()
        listener = householdRef.addSnapshotListener { [weak self] snapshot, error in
            guard let self else { return }
            if let error {
                // 退出・世帯切り替え時の権限エラーは自然に起きるので警告しない
                if error.isFirestorePermissionDenied { return }
                self.errorMessage = error.localizedDescription
                return
            }
            self.household = try? snapshot?.data(as: Household.self)
        }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
    }

    // MARK: - 編集

    func renameHousehold(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                try await householdRef.updateData(["name": trimmed])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 自分の表示名を世帯のメンバー一覧に反映する。
    /// 他のメンバーの画面にもリアルタイムで新しい名前が表示される。
    func updateMemberName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                try await householdRef.updateData(["memberNames.\(currentUid)": trimmed])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
