# 買い物リストと献立(KaimonoList)

家族で1つの買い物リストと献立を**リアルタイム共有**する iOS アプリ。
招待コードで世帯(household)に参加すると、リスト・カテゴリ・レシピ・献立がメンバー全員に即時同期されます。
メンバーがリストに品物を追加すると、他のメンバーへプッシュ通知が届きます。

> App Store 表示名は「買い物リストと献立」。Bundle ID は `com.kawasoe.KaimonoList`。

## 主な機能
- 🛒 **買い物リスト**: 品名からカテゴリを自動推定し、売り場順に並べて表示。チェック/購入済み管理
- 🏷 **カテゴリ管理**: 世帯ごとに追加・編集・並び替え(よく行く店の売り場順に調整可能)
- 🍽 **献立プランナー**: レシピ帳 + 今日から7日分の献立。レシピの材料をワンタップで買い物リストへ展開。人数に応じて材料の分量を自動スケール
- 💡 **献立のおすすめ**: 購入履歴(よく買う食材)+ 旬の食材 + マンネリ回避(直近に作った料理は減点)でレシピをスコアリングして提案。内蔵の定番レシピカタログから選ぶこともできる
- 🧾 **レシートで家計簿**: レシートを撮影(または写真を選択)すると、店名・日付・合計・品目を端末内で読み取って記録。月ごとの支出合計とカテゴリ別内訳を世帯で共有。品目は購入履歴にも反映して「よく買うもの」・献立のおすすめに活用。Apple Intelligence 対応端末(iOS 26+)では端末内の言語モデルで品目の読み取り精度を補強
- 👨‍👩‍👧 **世帯共有**: 招待コードで参加/退出。メンバー一覧表示。全データをリアルタイム同期
- 🔔 **プッシュ通知**: メンバーの買い物リスト追加を FCM + Cloud Functions で通知
- 👋 **初回チュートリアル**: 初回起動時に機能を案内するオンボーディング
- 🔐 **Sign in with Apple**: サインイン必須。アカウント削除(退会)にも対応

## 技術スタック
- **SwiftUI**(iOS 17 以降 / `@Observable` を使用)
- **Firebase**: Authentication(**Sign in with Apple**)+ Cloud Firestore(リアルタイム同期・セキュリティルール)+ Cloud Messaging(プッシュ通知)
- **Cloud Functions**(Node.js / 2nd Gen, asia-northeast1): リスト追加を検知して通知送信
- 状態管理は MV パターン(`@MainActor @Observable` な ViewModel)。Combine は使わず async/await ベース
- テスト: Swift Testing(純粋関数のユニットテスト)

## 認証と世帯の仕組み
- 認証は **Sign in with Apple のみ**。起動時にサインインゲートを表示し、サインインしないと利用できない。
- 世帯の解決は**アカウントベース**。`households where memberIds array-contains uid` で所属世帯を検索するため、端末変更・再インストール後も同じ世帯データに復帰できる(端末に保存した `householdId` はキャッシュ扱い)。
- アカウント削除は Apple 再認証 → 世帯からの離脱 → Apple トークン失効 → 認証アカウント削除、の順で行う(App Store ガイドライン 5.1.1(v) 対応)。

## プロジェクト構成
| ファイル | 役割 |
|---|---|
| `KaimonoListApp.swift` | `@main`。Firebase 構成 → サインイン状態に応じて `SignInView` / `RootTabView` を表示。テスト実行時は Firebase 構成をスキップ |
| `SessionStore.swift` | Sign in with Apple・世帯の用意/参加/退出・招待コード管理・アカウント削除 |
| `SignInView.swift` | サインインゲート画面(`SignInWithAppleButton`) |
| `Models.swift` | データモデル + カテゴリ推定 `CategoryGuesser` / 献立提案 `MealSuggester` / 旬食材 `SeasonalIngredients` / 定番レシピ `RecipeCatalog` / 数量スケール `IngredientScaler` / 献立削除の材料クリーンアップ `MealPlanIngredientRemoval` |
| `RootTabView.swift` | 「リスト」「献立」「記録」「家計簿」「共有」のタブ + 初回オンボーディング表示制御 |
| `OnboardingView.swift` | 初回起動チュートリアル(4ページのページ送り) |
| `ShoppingListView` / `ShoppingListViewModel` | 買い物リスト画面と同期・購入履歴の記録 |
| `CategoryManageView` | カテゴリの追加・編集・並び替え |
| `MealPlanView` / `MealPlannerViewModel` / `RecipeListView` | 献立・レシピ・食材展開・おすすめ生成 |
| `Receipt.swift` | レシートのモデル・ルールベース解析 `ReceiptParser` / OCR 断片の行まとめ `ReceiptRowGrouper` / カテゴリ別集計 `ReceiptSummary` |
| `ReceiptScanner.swift` | 文字認識(Vision)・端末内 AI での整形(Foundation Models, iOS 26+)・書類スキャナ(VisionKit) |
| `ReceiptBookView` / `ReceiptBookViewModel` | 家計簿タブ(月の支出・カテゴリ内訳・レシート一覧)と、読み取り結果の確認・編集・保存 |
| `HouseholdView` / `HouseholdViewModel` | 共有・メンバー管理・アカウント設定・退会 |
| `PushNotifications.swift` | FCM/APNs 連携(`PushManager` / `AppDelegate`) |
| `PrivacyInfo.xcprivacy` | プライバシーマニフェスト(収集データ種別・Required Reason API) |
| `firestore.rules` | 「世帯メンバーだけが読み書きできる」セキュリティルール |
| `functions/index.js` | Cloud Functions `notifyItemAdded`(リスト追加をメンバーへ通知) |

## Firestore データ構造
```
households/{householdId}          … name / memberIds / memberNames / inviteCode
  ├─ items/{itemId}               … 買い物アイテム
  ├─ categories/{categoryId}      … 世帯ごとのカテゴリ(売り場順)
  ├─ recipes/{recipeId}           … レシピ帳
  ├─ mealPlans/{entryId}          … 日付へのレシピ割り当て
  ├─ purchaseHistory/{recordId}   … 購入履歴(好みの学習データ)
  ├─ receipts/{receiptId}         … 家計簿のレシート(店名・日付・合計・品目)
  └─ deviceTokens/{fcmToken}      … プッシュ通知の送信先
inviteCodes/{code}                … 招待コード → householdId の逆引き表
```

## テスト
`KaimonoListTests`(Swift Testing)。純粋関数を中心にユニットテスト化:
- `CategoryGuesserTests` — 品名からのカテゴリ推定
- `ShoppingListGroupingTests` — 未購入アイテムのカテゴリ別グルーピング
- `MealSuggesterTests` — 献立提案のスコアリング(好み/旬/マンネリ)
- `IngredientScalerTests` — 材料数量の人数スケール
- `MealPlanRemovalTests` — 献立削除時の材料クリーンアップ判定
- `DateKeyTests` — 日付キー(`yyyy-MM-dd`)
- `ReceiptParserTests` / `ReceiptSummaryTests` — レシートの解析(店名・日付・合計・品目)とカテゴリ別集計

## セットアップ
詳細は [`SETUP.md`](SETUP.md) を参照。

## 動作環境
- iOS 17.0 以上
- Xcode 16 以降(`PBXFileSystemSynchronizedRootGroup` を使用)

## ライセンス
(必要に応じて記載)
