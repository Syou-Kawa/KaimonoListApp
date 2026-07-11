import SwiftUI
import UIKit

/// 世帯の共有・メンバー管理画面。
/// 招待コードの共有、メンバー一覧、招待コードでの参加、世帯からの退出を行う。
struct HouseholdView: View {
    /// アクティブな世帯の切り替え(参加・退出)を担うので SessionStore を直接持つ
    let session: SessionStore

    @State private var viewModel: HouseholdViewModel

    @State private var joinCode = ""
    @State private var isProcessing = false
    @State private var isShowingRenameSheet = false
    @State private var isShowingNameSheet = false
    @State private var isConfirmingJoin = false
    @State private var isConfirmingLeave = false
    @State private var didCopyCode = false

    init(session: SessionStore) {
        self.session = session
        _viewModel = State(initialValue: HouseholdViewModel(
            householdId: session.currentHouseholdId ?? "",
            currentUid: session.currentUid ?? ""
        ))
    }

    var body: some View {
        NavigationStack {
            List {
                accountSection
                householdSection
                inviteCodeSection
                membersSection
                joinSection
                leaveSection
                signOutSection
            }
            .navigationTitle("共有")
            .onAppear { viewModel.startListening() }
            .sheet(isPresented: $isShowingRenameSheet) {
                SingleFieldSheet(
                    navigationTitle: "世帯名を変更",
                    sectionTitle: "世帯の名前",
                    placeholder: "例:わが家",
                    initialValue: viewModel.householdName
                ) { newName in
                    viewModel.renameHousehold(newName)
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $isShowingNameSheet) {
                SingleFieldSheet(
                    navigationTitle: "表示名を変更",
                    sectionTitle: "あなたの表示名",
                    placeholder: "例:たろう",
                    initialValue: session.displayName
                ) { newName in
                    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    session.displayName = trimmed
                    viewModel.updateMemberName(trimmed)
                }
                .presentationDetents([.medium])
            }
            .alert("エラー", isPresented: errorBinding) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    // MARK: - アカウント(表示名)

    private var accountSection: some View {
        Section {
            Button {
                isShowingNameSheet = true
            } label: {
                HStack {
                    Text("表示名")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(session.displayName)
                        .foregroundStyle(.secondary)
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("アカウント")
        } footer: {
            Text("買い物リストや献立に「追加した人」として表示される名前です。")
        }
    }

    // MARK: - 世帯名

    private var householdSection: some View {
        Section("世帯") {
            Button {
                isShowingRenameSheet = true
            } label: {
                HStack {
                    Text(viewModel.householdName)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - 招待コード

    private var inviteCodeSection: some View {
        Section {
            HStack {
                Text(viewModel.inviteCode)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .kerning(4)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Button {
                UIPasteboard.general.string = viewModel.inviteCode
                didCopyCode = true
            } label: {
                Label(didCopyCode ? "コピーしました" : "コードをコピー",
                      systemImage: didCopyCode ? "checkmark" : "doc.on.doc")
            }
            .disabled(viewModel.inviteCode.isEmpty)

            ShareLink(item: "買い物リストを一緒に使いましょう!アプリの「共有」タブで招待コード \(viewModel.inviteCode) を入力してください。") {
                Label("招待を送る", systemImage: "square.and.arrow.up")
            }
            .disabled(viewModel.inviteCode.isEmpty)
        } header: {
            Text("招待コード")
        } footer: {
            Text("この6桁を家族に伝えて、相手の「共有」タブで入力してもらうと同じリストを使えます。")
        }
    }

    // MARK: - メンバー

    private var membersSection: some View {
        Section("メンバー") {
            ForEach(viewModel.members) { member in
                HStack(spacing: 12) {
                    Image(systemName: "person.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(member.name)
                    if member.isCurrentUser {
                        Text("(あなた)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - 参加

    private var joinSection: some View {
        Section {
            TextField("招待コード(6桁)", text: $joinCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .disabled(isProcessing)

            Button {
                isConfirmingJoin = true
            } label: {
                if isProcessing {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("この世帯に参加")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(isProcessing || joinCode.trimmingCharacters(in: .whitespaces).isEmpty)
            .confirmationDialog(
                "この招待コードの世帯に参加しますか?",
                isPresented: $isConfirmingJoin,
                titleVisibility: .visible
            ) {
                Button("参加する") { join() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("現在の自分のリストからは切り替わり、参加先の世帯のリストが表示されます。")
            }
        } header: {
            Text("別の世帯に参加")
        } footer: {
            Text("家族から共有された招待コードを入力すると、その世帯の買い物リストと献立に切り替わります。")
        }
    }

    // MARK: - 退出

    private var leaveSection: some View {
        Section {
            Button(role: .destructive) {
                isConfirmingLeave = true
            } label: {
                Text("この世帯から出る")
                    .frame(maxWidth: .infinity)
            }
            .disabled(isProcessing)
            .confirmationDialog(
                "この世帯から出ますか?",
                isPresented: $isConfirmingLeave,
                titleVisibility: .visible
            ) {
                Button("退出する", role: .destructive) { leave() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("あなたはメンバーから外れ、新しい自分専用のリストが用意されます。")
            }
        } footer: {
            Text("共有をやめても、世帯に残ったデータは他のメンバーが引き続き利用できます。")
        }
    }

    // MARK: - サインアウト

    private var signOutSection: some View {
        Section {
            Button("サインアウト") {
                session.signOut()
            }
            .disabled(isProcessing)
        } footer: {
            Text("同じ Apple ID で再度サインインすれば、同じリストに戻れます。")
        }
    }

    // MARK: - アクション

    private func join() {
        let code = joinCode
        isProcessing = true
        Task {
            do {
                try await session.joinHousehold(code: code)
                joinCode = ""
                // 参加成功後は RootTabView が householdId で再構築されるため、
                // このビュー自体が作り直される
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
            isProcessing = false
        }
    }

    private func leave() {
        isProcessing = true
        Task {
            do {
                try await session.leaveHousehold()
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
            isProcessing = false
        }
    }
}

// MARK: - 単一テキスト入力の編集シート(世帯名・表示名で共用)

private struct SingleFieldSheet: View {
    let navigationTitle: String
    let sectionTitle: String
    let placeholder: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(navigationTitle: String, sectionTitle: String, placeholder: String,
         initialValue: String, onSave: @escaping (String) -> Void) {
        self.navigationTitle = navigationTitle
        self.sectionTitle = sectionTitle
        self.placeholder = placeholder
        self.onSave = onSave
        _text = State(initialValue: initialValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(sectionTitle) {
                    TextField(placeholder, text: $text)
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
