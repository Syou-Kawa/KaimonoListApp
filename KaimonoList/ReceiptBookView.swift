import SwiftUI
import PhotosUI

// MARK: - 家計簿タブ

/// レシートを撮影して記録する家計簿画面。
/// 月ごとの支出合計・カテゴリ別の内訳と、その月のレシート一覧を表示する。
/// 右上の + から「撮影」「写真から読み取り」「手入力」でレシートを追加できる。
struct ReceiptBookView: View {
    @State private var viewModel: ReceiptBookViewModel

    /// 確認・編集シートの対象。nil = 非表示
    @State private var editor: ReceiptEditorContext?
    @State private var isShowingCamera = false
    /// カメラで撮影した画像。カメラを閉じ終わってから読み取りを始めるため一時的に持つ
    @State private var capturedImages: [UIImage] = []
    @State private var isPickingPhoto = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var isPickingMonth = false
    /// 削除確認の対象
    @State private var deleteTarget: Receipt?

    init(householdId: String, currentUid: String, currentUserName: String) {
        _viewModel = State(initialValue: ReceiptBookViewModel(
            householdId: householdId,
            currentUid: currentUid,
            currentUserName: currentUserName
        ))
    }

    var body: some View {
        NavigationStack {
            content
                .safeAreaInset(edge: .top, spacing: 0) { monthNavigator }
                .navigationTitle("家計簿")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { addMenu }
                }
                .overlay { readingOverlay }
                // 他の画面と同じく onDisappear では止めない(シートやカメラ表示中も同期を続ける)。
                // startListening は購読済みなら何もしない
                .onAppear { viewModel.startListening() }
                .fullScreenCover(isPresented: $isShowingCamera, onDismiss: startReadingCapturedImages) {
                    DocumentCameraView { images in
                        capturedImages = images
                        isShowingCamera = false
                    } onCancel: {
                        isShowingCamera = false
                    }
                    .ignoresSafeArea()
                }
                .photosPicker(isPresented: $isPickingPhoto, selection: $pickedPhoto, matching: .images)
                .onChange(of: pickedPhoto) { _, item in
                    guard let item else { return }
                    pickedPhoto = nil
                    Task { await readPickedPhoto(item) }
                }
                .sheet(item: $editor) { context in
                    ReceiptEditorSheet(viewModel: viewModel, context: context)
                }
                .sheet(isPresented: $isPickingMonth) {
                    MonthPickerSheet(selectedMonth: viewModel.selectedMonth) { month in
                        viewModel.jump(to: month)
                    }
                    .presentationDetents([.medium])
                }
                .confirmationDialog(
                    "このレシートを削除しますか?",
                    isPresented: deleteDialogBinding,
                    titleVisibility: .visible,
                    presenting: deleteTarget
                ) { receipt in
                    Button("削除", role: .destructive) { viewModel.delete(receipt) }
                } message: { _ in
                    Text("購入履歴に追加した品目も一緒に削除されます。")
                }
                .alert("エラー", isPresented: errorBinding) {
                    Button("OK") { viewModel.errorMessage = nil }
                } message: {
                    Text(viewModel.errorMessage ?? "")
                }
        }
    }

    // MARK: - 本体

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.receipts.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.receipts.isEmpty {
            ContentUnavailableView {
                Label("レシートがありません", systemImage: "doc.text.viewfinder")
            } description: {
                Text("レシートを撮影すると、お店・日付・合計・品目を読み取って記録します。")
            } actions: {
                if DocumentCameraView.isSupported {
                    Button("レシートを撮影") { isShowingCamera = true }
                        .buttonStyle(.borderedProminent)
                }
                Button("写真から読み取る") { isPickingPhoto = true }
            }
        } else {
            List {
                summarySection
                ForEach(viewModel.receiptsByDay) { day in
                    Section(Self.dayTitle(for: day.dateKey)) {
                        ForEach(day.receipts) { receipt in
                            Button {
                                editor = ReceiptEditorContext(
                                    mode: .edit(receipt),
                                    draft: viewModel.makeDraft(from: receipt)
                                )
                            } label: {
                                ReceiptRow(receipt: receipt)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    deleteTarget = receipt
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    /// 月の合計とカテゴリ別の内訳
    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("この月の支出")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    Text(Yen.format(viewModel.monthTotal))
                        .font(.largeTitle.bold())
                        .monospacedDigit()
                    Spacer()
                    Text("レシート \(viewModel.receipts.count)枚")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            let totals = viewModel.categoryTotals
            if let maxAmount = totals.map(\.amount).max(), maxAmount > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    Text("カテゴリ別(品目の金額)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(totals) { total in
                        CategoryBar(total: total, maxAmount: maxAmount)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - 追加メニュー

    private var addMenu: some View {
        Menu {
            Button {
                isShowingCamera = true
            } label: {
                Label("レシートを撮影", systemImage: "camera")
            }
            .disabled(!DocumentCameraView.isSupported)

            Button {
                isPickingPhoto = true
            } label: {
                Label("写真から読み取る", systemImage: "photo")
            }

            Button {
                editor = ReceiptEditorContext(mode: .manual, draft: ReceiptDraft())
            } label: {
                Label("手入力する", systemImage: "square.and.pencil")
            }
        } label: {
            Label("レシートを追加", systemImage: "plus")
        }
        .disabled(viewModel.isReading)
    }

    // MARK: - 読み取り

    /// カメラを閉じ終えたら、撮影した画像の読み取りを始める
    private func startReadingCapturedImages() {
        let images = capturedImages
        capturedImages = []
        guard !images.isEmpty else { return }
        Task { await read(images) }
    }

    private func readPickedPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            viewModel.errorMessage = "写真を読み込めませんでした"
            return
        }
        await read([image])
    }

    private func read(_ images: [UIImage]) async {
        guard let draft = await viewModel.readReceipt(images: images) else { return }
        editor = ReceiptEditorContext(mode: .scanned(images), draft: draft)
    }

    @ViewBuilder
    private var readingOverlay: some View {
        if viewModel.isReading {
            ZStack {
                Color.black.opacity(0.2).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(viewModel.readingStatus)
                        .font(.subheadline)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    // MARK: - 月ナビ(◀ 年月 ▶)

    private var monthNavigator: some View {
        HStack {
            Button {
                viewModel.goToPreviousMonth()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("前の月")

            Spacer()

            Button {
                isPickingMonth = true
            } label: {
                HStack(spacing: 6) {
                    Text(Self.monthFormatter.string(from: viewModel.selectedMonth))
                        .font(.headline)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.primary)
            }
            .accessibilityLabel("月を選ぶ(現在 \(Self.monthFormatter.string(from: viewModel.selectedMonth)))")

            Spacer()

            Button {
                viewModel.goToNextMonth()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .disabled(!viewModel.canGoToNextMonth)
            .accessibilityLabel("次の月")
        }
        .padding(.horizontal, 8)
        .background(.bar)
    }

    // MARK: - バインディング・書式

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d(E)"
        return formatter
    }()

    /// 日付見出し("yyyy-MM-dd" → 「今日 M/d(E)」「昨日 M/d(E)」「M/d(E)」)
    private static func dayTitle(for key: String) -> String {
        guard let date = MealPlannerViewModel.date(fromKey: key) else { return key }
        let label = dayFormatter.string(from: date)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今日 \(label)" }
        if calendar.isDateInYesterday(date) { return "昨日 \(label)" }
        return label
    }
}

// MARK: - 一覧の行

private struct ReceiptRow: View {
    let receipt: Receipt

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(.teal)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.storeName.isEmpty ? "店名なし" : receipt.storeName)
                    .font(.body)
                    .foregroundStyle(receipt.storeName.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(Yen.format(receipt.total))
                .font(.body.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = []
        if !receipt.items.isEmpty {
            let pieces = receipt.items.reduce(0) { $0 + $1.resolvedQuantity }
            // まとめ買いがあるときは品目数に加えて合計点数も見せる
            parts.append(pieces > receipt.items.count ? "\(receipt.items.count)品・計\(pieces)点" : "\(receipt.items.count)品")
        }
        parts.append(receipt.addedByName)
        if let memo = receipt.memo, !memo.isEmpty { parts.append(memo) }
        return parts.joined(separator: " · ")
    }
}

/// カテゴリ別支出の横棒
private struct CategoryBar: View {
    let total: ReceiptSummary.CategoryTotal
    let maxAmount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(total.title)
                    .font(.subheadline)
                Spacer()
                Text(Yen.format(total.amount))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                Capsule()
                    .fill(Color.teal.opacity(0.7))
                    .frame(width: max(4, proxy.size.width * CGFloat(max(total.amount, 0)) / CGFloat(maxAmount)))
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 確認・編集シート

/// 確認・編集シートに渡す内容
struct ReceiptEditorContext: Identifiable {
    enum Mode {
        /// 撮影・写真から読み取った直後(読み取った画像を見比べられる)
        case scanned([UIImage])
        /// 手入力で新規追加
        case manual
        /// 既存レシートの編集
        case edit(Receipt)
    }

    let id = UUID()
    let mode: Mode
    let draft: ReceiptDraft

    var existing: Receipt? {
        if case let .edit(receipt) = mode { return receipt }
        return nil
    }

    var images: [UIImage] {
        if case let .scanned(images) = mode { return images }
        return []
    }
}

/// 読み取り結果を確認・修正して保存するシート。既存レシートの編集にも使う。
private struct ReceiptEditorSheet: View {
    let viewModel: ReceiptBookViewModel
    let context: ReceiptEditorContext

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReceiptDraft
    @State private var addToHistory: Bool
    @State private var isShowingImages = false

    init(viewModel: ReceiptBookViewModel, context: ReceiptEditorContext) {
        self.viewModel = viewModel
        self.context = context
        _draft = State(initialValue: context.draft)
        // 既存レシートは前回の設定を引き継ぐ。新規は購入履歴にも追加する
        _addToHistory = State(initialValue: context.existing.map { !($0.purchaseHistoryIds ?? []).isEmpty } ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !context.images.isEmpty {
                    Section {
                        Button {
                            isShowingImages = true
                        } label: {
                            Label("読み取ったレシートを見る", systemImage: "doc.text.image")
                        }
                    } footer: {
                        Text("読み取り結果に間違いがないか確認してください。")
                    }
                }

                Section("お店") {
                    TextField("店名", text: $draft.storeName)
                    DatePicker("購入日", selection: $draft.date, in: ...Date(), displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "ja_JP"))
                }

                Section {
                    HStack {
                        Text("合計")
                        Spacer()
                        Text("¥").foregroundStyle(.secondary)
                        TextField("品目の合計", value: $draft.total, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 140)
                    }
                } footer: {
                    totalFooter
                }

                itemsSection

                Section {
                    Toggle("購入履歴に追加", isOn: $addToHistory)
                } footer: {
                    Text("品目を「よく買うもの」や献立のおすすめに使います。リストで購入済みにして削除した品と重複する場合はオフにしてください。")
                }

                Section("メモ") {
                    TextField("メモ(任意)", text: $draft.memo, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        viewModel.save(draft, editing: context.existing, addToHistory: addToHistory)
                        dismiss()
                    }
                    .disabled(draft.isEmpty)
                }
            }
            .sheet(isPresented: $isShowingImages) {
                ReceiptImagesSheet(images: context.images)
            }
        }
        // 読み取り直後は入力途中で閉じて内容を失わないよう、スワイプで閉じられないようにする
        .interactiveDismissDisabled(context.existing == nil && !draft.isEmpty)
    }

    private var title: String {
        switch context.mode {
        case .scanned: return "レシートを確認"
        case .manual:  return "レシートを入力"
        case .edit:    return "レシートを編集"
        }
    }

    @ViewBuilder
    private var totalFooter: some View {
        let itemsTotal = draft.itemsTotal
        if draft.items.isEmpty {
            EmptyView()
        } else if let total = draft.total, total != itemsTotal {
            VStack(alignment: .leading, spacing: 4) {
                Text("品目の合計 \(Yen.format(itemsTotal))(差額 \(Yen.format(total - itemsTotal)):税・値引など)")
                Button("品目の合計を使う") { draft.total = itemsTotal }
                    .font(.footnote)
            }
        } else if draft.total == nil {
            Text("未入力のときは品目の合計 \(Yen.format(itemsTotal)) で保存します。")
        }
    }

    private var itemsSection: some View {
        Section {
            ForEach($draft.items) { $item in
                // 個数は nil(=単品)を 1 として見せ、1 に戻したら nil に片付ける
                let quantity = Binding<Int>(
                    get: { item.quantity ?? 1 },
                    set: { $item.wrappedValue.quantity = $0 > 1 ? $0 : nil }
                )
                HStack(spacing: 8) {
                    Menu {
                        ForEach(viewModel.categories) { category in
                            Button("\(category.emoji) \(category.name)") {
                                item.categoryId = category.id
                            }
                        }
                    } label: {
                        Text(viewModel.categoryEmoji(for: item.categoryId))
                            .frame(width: 28)
                    }
                    .accessibilityLabel("カテゴリを選ぶ")

                    TextField("品名", text: $item.name)

                    Text("×").font(.caption).foregroundStyle(.secondary)
                    TextField("1", value: quantity, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .monospacedDigit()
                        .frame(width: 28)
                        .accessibilityLabel("個数")

                    Text("¥").foregroundStyle(.secondary)
                    TextField("0", value: $item.price, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 72)
                        .accessibilityLabel("金額")
                }
            }
            .onDelete { draft.items.remove(atOffsets: $0) }

            Button {
                draft.items.append(ReceiptItem(name: "", price: 0))
            } label: {
                Label("品目を追加", systemImage: "plus.circle")
            }
        } header: {
            Text("品目(\(draft.items.count))")
        } footer: {
            if !draft.items.isEmpty {
                Text("左のアイコンでカテゴリ、「×」で個数を変更できます。金額は個数分の小計です。左にスワイプで削除。")
            }
        }
    }
}

/// 読み取ったレシート画像の確認用
private struct ReceiptImagesSheet: View {
    let images: [UIImage]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(images.indices, id: \.self) { index in
                        Image(uiImage: images[index])
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding()
            }
            .navigationTitle("レシート")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}
