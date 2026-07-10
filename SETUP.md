# 買い物リストアプリ セットアップ手順(MVP: カテゴリ別リスト + リアルタイム同期)

## 前提
- Mac + Xcode 16 以降
- デプロイターゲット: **iOS 17.0 以上**(`@Observable` を使用しているため)
- この段階では Apple Developer Program($99/年)は不要。シミュレータと手元の実機で動きます。
  プッシュ通知・App Store 提出のフェーズで加入します。

## 1. プロジェクトを開く
1. リポジトリを clone し、`KaimonoList.xcodeproj` を Xcode で開く
2. Bundle Identifier は `com.kawasoe.KaimonoList`(Firebase 登録で使用。自分用に変える場合は
   Signing & Capabilities で変更し、後述の Firebase 登録の Bundle ID も合わせる)
3. Firebase SDK(`FirebaseAuth` / `FirebaseFirestore`)は Swift Package Manager で**統合済み**。
   初回オープン時に自動でパッケージ解決が走ります(ネットワーク必要)

## 2. Firebase プロジェクト作成
1. https://console.firebase.google.com → プロジェクトを追加(Analytics は任意、オフでOK)
2. 「iOS アプリを追加」→ 手順1の Bundle ID を入力
3. **GoogleService-Info.plist** をダウンロードし、`KaimonoList/` フォルダに置く
   (同期フォルダ構成なので、フォルダに入れれば自動でターゲットへ含まれる。`.gitignore` 済み)

## 3. (SDK 追加は不要)
Firebase SDK は上記のとおりプロジェクトに統合済みのため、手動追加は不要です。
自分で追加し直す場合の設定: URL `https://github.com/firebase/firebase-ios-sdk` /
Dependency Rule **Up to Next Major** / プロダクト `FirebaseAuth`・`FirebaseFirestore`。

## 4. Firebase コンソール側の設定
### Authentication
- Build → Authentication → Sign-in method → **匿名** を有効化
  (開発用。リリース前に Sign in with Apple に置き換え予定)

### Firestore
- Build → Firestore Database → データベースを作成
- ロケーション: **asia-northeast1(東京)** 推奨
- 「本番環境モード」で作成 → ルールタブに `firestore.rules` の内容を貼り付けて公開

## 5. ソースファイルの構成
ソースは `KaimonoList/` フォルダに配置済み(clone すればそのまま揃っています):

```
KaimonoList/
├── KaimonoListApp.swift      ← @main(FirebaseApp.configure() 後に SessionStore を生成)
├── Models.swift              ← データモデル・カテゴリ・カテゴリ推定・レシピ・献立
├── SessionStore.swift        ← 匿名サインイン + 世帯(household)の初期化
├── RootTabView.swift         ← ルート画面(リスト / 献立 のタブ切り替え)
├── ShoppingListViewModel.swift
├── ShoppingListView.swift    ← リスト画面 + 追加シート
├── CategoryManageView.swift  ← カテゴリの追加・編集・並び替え画面
├── MealPlannerViewModel.swift ← レシピ・献立の同期 + 食材展開
├── MealPlanView.swift        ← 献立表(今日から7日分)+ レシピ選択シート
├── RecipeListView.swift      ← レシピ帳 + 追加・編集シート
├── HouseholdViewModel.swift  ← 世帯ドキュメントの同期(招待コード・メンバー・世帯名)
└── HouseholdView.swift       ← 共有タブ(招待コード表示・参加・退出・世帯名編集)
```

※ フェーズ2から、App ファイルでサインイン完了後に表示するビューを
   `ShoppingListView(...)` → `RootTabView(...)` に置き換えてください。
   **フェーズ3で `RootTabView` の引数が変わりました。** サインイン完了後の表示を
   `RootTabView(householdId:currentUid:currentUserName:)` から
   **`RootTabView(session: sessionStore)`** に変更してください(SessionStore インスタンスをそのまま渡す)。
   参加・退出でアクティブな世帯を切り替えるため、RootTabView が SessionStore を直接参照します。

## 6. 動作確認チェックリスト
1. ビルド&実行 → 「準備中…」→ 空のリスト画面が表示される
2. 「+」からアイテム追加。品名に「にんじん」と入れるとカテゴリが自動で「野菜・果物」になる
3. Firebase コンソール → Firestore で `households/{id}/items` にデータが入っている
4. **リアルタイム同期のデモ**: コンソール側で items にドキュメントを直接追加
   (`name`: 文字列, `categoryId`: categories 内の任意のドキュメントID, `isChecked`: false,
   `addedByUid`: 適当な文字列, `addedByName`: `"テスト"`, `createdAt`: timestamp)
   → アプリを操作せずに即座に画面へ反映されればOK
5. タップでチェック → 「購入済み」セクションへ移動 → まとめて削除
6. 左上のタグアイコン → カテゴリ画面。「+」で追加、タップで編集、
   「編集」ボタンからドラッグで並び替え・スワイプで削除ができる
   → 並び替えた順序がリスト画面のセクション順に反映されればOK

※ 2台間の共有(招待コードで参加)は次フェーズで Cloud Functions と一緒に実装します。
   現状は起動した端末ごとに自分の世帯が1つ作られる仕様です。

## 7. フェーズ2(献立プランナー)の動作確認チェックリスト
事前準備: **firestore.rules を更新したので、Firebase コンソールのルールタブに
最新の内容を貼り直して「公開」する**(recipes / mealPlans の読み書き許可が追加されています)。

1. 下のタブに「リスト」「献立」が表示される
2. 献立タブ → 左上の本アイコン → レシピ帳。「+」でレシピを追加
   (例:カレーライス / 材料:じゃがいも 3個、にんじん 1本、玉ねぎ 2個、豚こま 300g、カレールー 1箱)
3. 献立タブに戻り、日付見出しの「+」からレシピを選んで割り当てる
4. 献立行のカートアイコンをタップ → 「5件を買い物リストに追加しました」と表示され、
   リストタブに材料がカテゴリ分類済みで入っている
   (じゃがいも→野菜・果物、豚こま→肉、カレールー→缶詰・レトルト)
5. 同じレシピをもう一度展開しても、未購入リストにある品名は重複追加されない
6. 展開済みの献立は「追加済み」表示に変わる。複数日に割り当ててから
   「今週の材料をまとめてリストへ」で一括展開もできる
7. Firebase コンソール → `households/{id}/recipes` と `mealPlans` にデータが入っている。
   2台目(または コンソール直編集)での変更が献立表に即時反映される

## 8. フェーズ3(世帯の共有)の動作確認チェックリスト
事前準備:
- **firestore.rules を更新したので、Firebase コンソールのルールタブに最新の内容を貼り直して「公開」する**
  (トップレベルの `inviteCodes` コレクションと、招待コードでの自己参加を許可する household の `update` ルールが追加されています)。
- **App ファイルの表示を `RootTabView(session: sessionStore)` に変更する**(上記「5. ソースファイルの配置」の注記参照)。

1. 下のタブに「リスト」「献立」「共有」が表示される
2. 端末A:「共有」タブを開くと6桁の招待コードが表示される。リストタブで何品か追加しておく
3. 端末B(別シミュレータ or 実機):「共有」タブ → 招待コード欄に端末Aのコードを入力 →
   「この世帯に参加」→ 確認ダイアログで「参加する」
   → リストタブに端末Aで追加した品が即座に同期されればOK
4. 両端末の「共有」タブのメンバー一覧に2人が表示される(自分には「(あなた)」)
5. 「招待を送る」でシート共有、「コードをコピー」でクリップボードにコピーできる
6. 世帯名をタップして変更 → 他メンバーの画面にも即時反映される
7. 端末Bで「この世帯から出る」→ 確認 → 自分専用の空リストに戻る。
   端末Aのメンバー一覧から端末Bが消える
8. 存在しないコードを入力すると「そのコードの世帯は見つかりません」と表示される
9. Firebase コンソールで `inviteCodes/{コード}`(`householdId` を保持)と、
   `households/{id}` の `memberIds` / `memberNames` にデータが入っている

## 次フェーズの予定
1. Sign in with Apple(匿名アカウントからのリンク移行)
2. FCM プッシュ通知(共有メンバーのアイテム追加を検知)
3. 購入履歴の記録と、修正履歴から学習するカテゴリ辞書
4. 世帯オーナー権限・他メンバーの管理(現状はメンバー相互信頼モデル)
