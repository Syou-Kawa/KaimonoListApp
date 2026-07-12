"use strict";

// 買い物リストへのアイテム追加を検知し、追加した本人を除く世帯メンバーの
// 全デバイスへプッシュ通知を送る Cloud Function。
//
// 送信先トークンはクライアントが households/{id}/deviceTokens/{token} に登録する
// (KaimonoList/PushNotifications.swift 参照)。ドキュメントIDが FCM トークンそのもの。
//
// リージョンは Firestore と同じ asia-northeast1(東京)に合わせる。

const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {initializeApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");

initializeApp();

exports.notifyItemAdded = onDocumentCreated(
    {
      region: "asia-northeast1",
      document: "households/{householdId}/items/{itemId}",
    },
    async (event) => {
      const snapshot = event.data;
      if (!snapshot) return;

      const item = snapshot.data();

      // まとめ買い(バッチ追加)の抑制対象は通知しない。
      // クライアントは一括追加時、先頭の1件だけに batchSize を持たせ、
      // 残りには suppressNotification を付けて重複通知を防ぐ。
      if (item.suppressNotification) return;

      const {householdId} = event.params;
      const adderUid = item.addedByUid || "";
      const adderName = item.addedByName || "メンバー";
      const itemName = item.name || "アイテム";
      const batchSize = item.batchSize;

      const db = getFirestore();

      // この世帯のデバイストークンを集め、追加した本人の端末は除外する。
      const tokensSnapshot = await db
          .collection("households")
          .doc(householdId)
          .collection("deviceTokens")
          .get();

      const tokens = [];
      tokensSnapshot.forEach((doc) => {
        if (doc.data().uid !== adderUid) tokens.push(doc.id);
      });
      if (tokens.length === 0) return;

      const message = {
        tokens,
        notification: {
          title: "🛒 買い物リストが更新されました",
          body: (typeof batchSize === "number" && batchSize > 1) ?
            `${adderName}さんが${batchSize}件追加しました` :
            `${adderName}さんが「${itemName}」を追加しました`,
        },
        apns: {
          payload: {
            aps: {sound: "default"},
          },
        },
      };

      const response = await getMessaging().sendEachForMulticast(message);

      // 無効になったトークン(アンインストール等)を掃除する。
      const deletions = [];
      response.responses.forEach((result, index) => {
        if (result.success) return;
        const code = result.error && result.error.code;
        if (
          code === "messaging/registration-token-not-registered" ||
          code === "messaging/invalid-registration-token" ||
          code === "messaging/invalid-argument"
        ) {
          deletions.push(
              db
                  .collection("households")
                  .doc(householdId)
                  .collection("deviceTokens")
                  .doc(tokens[index])
                  .delete(),
          );
        }
      });
      await Promise.all(deletions);
    },
);
