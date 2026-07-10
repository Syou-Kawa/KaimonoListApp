# KaimonoList(買い物リストアプリ)

家族で1つの買い物リストと献立を**リアルタイム共有**する iOS アプリ。
招待コードで世帯(household)に参加すると、リスト・カテゴリ・レシピ・献立がメンバー全員に即時同期されます。

## 主な機能
- 🛒 **買い物リスト**: 品名からカテゴリを自動推定し、売り場順に並べて表示。チェック/購入済み管理
- 🏷 **カテゴリ管理**: 世帯ごとに追加・編集・並び替え(よく行く店の売り場順に調整可能)
- 🍽 **献立プランナー**: レシピ帳 + 今日から7日分の献立。レシピの材料をワンタップで買い物リストへ展開
- 👨‍👩‍👧 **世帯共有**: 招待コードで参加/退出。メンバー一覧表示。全データをリアルタイム同期

## 技術スタック
- **SwiftUI**(iOS 17 以降 / `@Observable` を使用)
- **Firebase**: Authentication(匿名)+ Cloud Firestore(リアルタイム同期・セキュリティルール)
- 状態管理は MV パターン(`@MainActor @Observable` な ViewModel)。Combine は使わず async/await ベース

## プロジェクト構成
| ファイル | 役割 |
|---|---|
| `KaimonoListApp.swift` | `@main`。起動〜サインイン後に `RootTabView(session:)` を表示 |
| `SessionStore.swift` | 匿名サインイン・世帯の用意/参加/退出・招待コード管理 |
| `Models.swift` | データモデル(`Household` / `ShoppingItem` / `Recipe` など)+ カテゴリ推定 `CategoryGuesser` |
| `RootTabView.swift` | 「リスト」「献立」「共有」の3タブ |
| `ShoppingListView` / `ShoppingListViewModel` | 買い物リスト画面と同期 |
| `CategoryManageView` | カテゴリの追加・編集・並び替え |
| `MealPlanView` / `MealPlannerViewModel` / `RecipeListView` | 献立・レシピと食材展開 |
| `HouseholdView` / `HouseholdViewModel` | 共有・メンバー管理 |
| `firestore.rules` | 「世帯メンバーだけが読み書きできる」セキュリティルール |

## セットアップ
詳細は [`SETUP.md`](SETUP.md) を参照。要点のみ:

1. リポジトリを clone して `KaimonoList.xcodeproj` を開く
   - Firebase SDK(`FirebaseAuth` / `FirebaseFirestore`)は Swift Package Manager で統合済み。初回オープン時に自動解決されます
2. Firebase プロジェクトを作成し、**`GoogleService-Info.plist` を `KaimonoList/` フォルダに配置**
   - このファイルは `.gitignore` 済み。各自 Firebase コンソールからダウンロードしてください
3. Firebase コンソールで **匿名認証**を有効化、**Firestore** を作成し `firestore.rules` を公開
4. ビルド & 実行

## 動作環境
- iOS 17.0 以上
- Xcode 16 以降

## ライセンス
(必要に応じて記載)
