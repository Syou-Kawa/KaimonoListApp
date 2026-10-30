import Foundation
import Observation
import UIKit
import FirebaseFirestore

/// 家計簿(レシート記録)の状態管理。
/// 選択中の月のレシートをリアルタイム購読し、家族が追加したレシートも即座に反映する。
/// レシートの品目は購入履歴(purchaseHistory)にも記録でき、
/// 「よく買うもの」候補や献立のおすすめの学習データとして活かされる。
@MainActor
@Observable
final class ReceiptBookViewModel {

    // MARK: - 状態

    /// 選択中の月(月初の Date)
    private(set) var selectedMonth: Date
    /// 選択中の月のレシート(購入日の新しい順、同日は追加の新しい順)
    private(set) var receipts: [Receipt] = []
    /// 世帯のカテゴリ(sortOrder 順)。品目のカテゴリ推定と内訳表示に使う
    private(set) var categories: [ItemCategory] = []
    private(set) var isLoading = false
    /// レシートの読み取り中(撮影後〜確認画面を出すまで)
    private(set) var isReading = false
    /// 読み取り中に表示する進捗メッセージ
    private(set) var readingStatus = ""
    var errorMessage: String?

    // MARK: - 依存

    let householdId: String
    let currentUid: String
    let currentUserName: String

    private let db = Firestore.firestore()
    private var receiptsListener: ListenerRegistration?
    private var categoriesListener: ListenerRegistration?

    private var householdRef: DocumentReference {
        db.collection("households").document(householdId)
    }
    private var receiptsRef: CollectionReference { householdRef.collection("receipts") }
    private var categoriesRef: CollectionReference { householdRef.collection("categories") }
    private var purchaseHistoryRef: CollectionReference { householdRef.collection("purchaseHistory") }

    init(householdId: String, currentUid: String, currentUserName: String) {
        self.householdId = householdId
        self.currentUid = currentUid
        self.currentUserName = currentUserName
        self.selectedMonth = MealHistoryViewModel.startOfMonth(Date())
    }

    // MARK: - 集計

    /// 選択中の月の支出合計
    var monthTotal: Int { receipts.reduce(0) { $0 + $1.total } }

    /// 選択中の月のカテゴリ別支出(品目の金額ベース)
    var categoryTotals: [ReceiptSummary.CategoryTotal] {
        ReceiptSummary.categoryTotals(receipts: receipts, categories: categories)
    }

    /// 1日分のレシート
    struct Day: Identifiable {
        let dateKey: String
        let receipts: [Receipt]
        var id: String { dateKey }
    }

    /// 購入日ごとにまとめたレシート(新しい日付順)
    var receiptsByDay: [Day] {
        let grouped = Dictionary(grouping: receipts, by: \.date)
        return grouped.keys.sorted(by: >).map { Day(dateKey: $0, receipts: grouped[$0] ?? []) }
    }

    /// カテゴリIDから表示用の絵文字を引く(未設定・削除済みは ❓)
    func categoryEmoji(for categoryId: String?) -> String {
        guard let categoryId, let category = categories.first(where: { $0.id == categoryId }) else {
            return "❓"
        }
        return category.emoji
    }

    // MARK: - リアルタイム同期

    /// 購読を開始する。すでに購読中なら何もしない(画面の再表示で読み直さない)
    func startListening() {
        guard receiptsListener == nil else { return }

        categoriesListener = categoriesRef
            .order(by: "sortOrder")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    // 退出・世帯切り替え時の権限エラーは自然に起きるので警告しない
                    if error.isFirestorePermissionDenied { return }
                    self.errorMessage = error.localizedDescription
                    return
                }
                self.categories = snapshot?.documents.compactMap {
                    try? $0.data(as: ItemCategory.self)
                } ?? []
            }

        listenSelectedMonth()
    }

    func stopListening() {
        receiptsListener?.remove()
        categoriesListener?.remove()
        receiptsListener = nil
        categoriesListener = nil
    }

    /// 選択中の月のレシートを購読し直す。
    /// `date` 単一フィールドの範囲＋並び替えなので複合インデックスは不要。
    private func listenSelectedMonth() {
        receiptsListener?.remove()
        receipts = []
        isLoading = true

        let monthStart = selectedMonth
        let nextMonthStart = Calendar.current.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart

        receiptsListener = receiptsRef
            .whereField("date", isGreaterThanOrEqualTo: MealPlannerViewModel.dateKey(monthStart))
            .whereField("date", isLessThan: MealPlannerViewModel.dateKey(nextMonthStart))
            .order(by: "date", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                self.isLoading = false
                if let error {
                    if error.isFirestorePermissionDenied { return }
                    self.errorMessage = error.localizedDescription
                    return
                }
                let loaded = snapshot?.documents.compactMap { try? $0.data(as: Receipt.self) } ?? []
                // 同じ日のレシートは追加の新しい順に並べる(未確定のサーバー時刻は最新扱い)
                self.receipts = loaded.sorted {
                    $0.date != $1.date
                        ? $0.date > $1.date
                        : ($0.createdAt ?? .distantFuture) > ($1.createdAt ?? .distantFuture)
                }
            }
    }

    // MARK: - 月の移動

    /// 今月より先(未来)へは進めない
    var canGoToNextMonth: Bool {
        selectedMonth < MealHistoryViewModel.startOfMonth(Date())
    }

    func goToPreviousMonth() {
        selectedMonth = Calendar.current.date(byAdding: .month, value: -1, to: selectedMonth) ?? selectedMonth
        listenSelectedMonth()
    }

    func goToNextMonth() {
        guard canGoToNextMonth else { return }
        selectedMonth = Calendar.current.date(byAdding: .month, value: 1, to: selectedMonth) ?? selectedMonth
        listenSelectedMonth()
    }

    /// 指定日の月へ移動する(未来の月は今月に丸める)。同じ月なら何もしない
    func jump(to date: Date) {
        let target = min(MealHistoryViewModel.startOfMonth(date), MealHistoryViewModel.startOfMonth(Date()))
        guard target != selectedMonth else { return }
        selectedMonth = target
        listenSelectedMonth()
    }

    // MARK: - レシートの読み取り

    /// 撮影・選択した画像から文字を読み取り、確認画面に渡す下書きを作る。
    /// 1) Vision で文字認識 → 2) ルールベースで解析 → 3) 対応端末なら端末内 AI で整形。
    /// 読み取れなかった項目は空のまま返し、確認画面で入力してもらう。
    func readReceipt(images: [UIImage]) async -> ReceiptDraft? {
        guard !images.isEmpty else { return nil }
        isReading = true
        readingStatus = "文字を読み取っています…"
        defer {
            isReading = false
            readingStatus = ""
        }

        var lines: [String] = []
        do {
            for image in images {
                lines += try await ReceiptTextRecognizer.recognizeLines(in: image)
            }
        } catch {
            errorMessage = "レシートを読み取れませんでした(\(error.localizedDescription))"
            return nil
        }
        guard !lines.isEmpty else {
            errorMessage = "文字が見つかりませんでした。明るい場所で、レシート全体が写るように撮影してください。"
            return nil
        }

        var result = ReceiptParser.parse(lines: lines)
        if ReceiptAIExtractor.isAvailable {
            readingStatus = "内容を整理しています…"
            if let ai = await ReceiptAIExtractor.extract(from: lines.map(ReceiptParser.normalize)) {
                result = ReceiptParser.merge(rule: result, ai: ai)
            }
        }
        return makeDraft(from: result)
    }

    /// 解析結果から確認画面用の下書きを作る。品目のカテゴリは品名から推定する。
    func makeDraft(from result: ReceiptParser.Result) -> ReceiptDraft {
        var draft = ReceiptDraft()
        draft.storeName = result.storeName ?? ""
        if let key = result.dateKey, let date = MealPlannerViewModel.date(fromKey: key) {
            draft.date = date
        }
        draft.items = result.items.map {
            ReceiptItem(
                name: $0.name,
                price: $0.price,
                quantity: $0.quantity > 1 ? $0.quantity : nil,   // 単品は nil にして保存を簡潔に
                categoryId: guessCategoryId(for: $0.name)
            )
        }
        draft.total = result.total
        return draft
    }

    /// 既存のレシートを編集用の下書きにする
    func makeDraft(from receipt: Receipt) -> ReceiptDraft {
        ReceiptDraft(
            storeName: receipt.storeName,
            date: MealPlannerViewModel.date(fromKey: receipt.date) ?? Date(),
            total: receipt.total,
            items: receipt.items,
            memo: receipt.memo ?? ""
        )
    }

    /// 品名から世帯のカテゴリIDを推定する(推定できなければ nil = 未分類)
    func guessCategoryId(for name: String) -> String? {
        guard let key = CategoryGuesser.guessKey(from: name) else { return nil }
        return categories.first(where: { $0.matcherKey == key })?.id
    }

    // MARK: - 保存・削除

    /// レシートを保存する(新規 / 既存の更新)。
    /// - addToHistory: true なら品目を購入履歴にも記録する。更新時は前回記録した履歴を消してから
    ///   記録し直すので、品目を直しても履歴が二重にならない。
    /// レシート本体と購入履歴は同一バッチで書き込む(片方だけ残らないように)。
    func save(_ draft: ReceiptDraft, editing existing: Receipt?, addToHistory: Bool) {
        let items: [ReceiptItem] = draft.items.compactMap { item in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            var cleaned = item
            cleaned.name = name
            // カテゴリ未設定・削除済みなら品名から推定し直す
            if cleaned.categoryId.map({ id in !categories.contains(where: { $0.id == id }) }) ?? true {
                cleaned.categoryId = guessCategoryId(for: name)
            }
            return cleaned
        }
        let dateKey = MealPlannerViewModel.dateKey(draft.date)
        let memo = draft.memo.trimmingCharacters(in: .whitespacesAndNewlines)

        let batch = db.batch()
        let receiptRef = existing?.id.map { receiptsRef.document($0) } ?? receiptsRef.document()

        // 前回このレシートから記録した購入履歴を取り消す
        for historyId in existing?.purchaseHistoryIds ?? [] {
            batch.deleteDocument(purchaseHistoryRef.document(historyId))
        }

        // 品目を購入履歴に記録する。購入日時はレシートの日付(今日なら現在時刻)
        var historyIds: [String] = []
        if addToHistory {
            let purchasedAt = Calendar.current.isDateInToday(draft.date)
                ? Date()
                : Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: draft.date) ?? draft.date
            for item in items {
                var record: [String: Any] = [
                    "name": item.name,
                    "purchasedByUid": currentUid,
                    "purchasedAt": Timestamp(date: purchasedAt),
                ]
                if let categoryId = item.categoryId {
                    record["categoryId"] = categoryId
                }
                let historyDoc = purchaseHistoryRef.document()
                historyIds.append(historyDoc.documentID)
                batch.setData(record, forDocument: historyDoc)
            }
        }

        let receipt = Receipt(
            id: nil,
            storeName: draft.storeName.trimmingCharacters(in: .whitespacesAndNewlines),
            date: dateKey,
            total: draft.resolvedTotal,
            items: items,
            memo: memo.isEmpty ? nil : memo,
            addedByUid: existing?.addedByUid ?? currentUid,
            addedByName: existing?.addedByName ?? currentUserName,
            purchaseHistoryIds: historyIds,
            createdAt: existing?.createdAt   // 新規は nil → サーバー時刻
        )
        do {
            try batch.setData(from: receipt, forDocument: receiptRef)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        batch.commit { [weak self] error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor [weak self] in self?.errorMessage = message }
        }

        // 保存したレシートが見えるよう、その月へ移動する
        jump(to: draft.date)
    }

    /// レシートを削除する。このレシートから記録した購入履歴も一緒に消す。
    func delete(_ receipt: Receipt) {
        guard let id = receipt.id else { return }
        let batch = db.batch()
        batch.deleteDocument(receiptsRef.document(id))
        for historyId in receipt.purchaseHistoryIds ?? [] {
            batch.deleteDocument(purchaseHistoryRef.document(historyId))
        }
        batch.commit { [weak self] error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor [weak self] in self?.errorMessage = message }
        }
    }
}
