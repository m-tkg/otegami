# iCloud アカウント同期 (M11)

同じ Apple ID の iOS/Mac 間で「iOS で追加したメールアカウントが Mac にも
自動出現し、そのまま受信開始できる」を実現する機能。2 層構成:

1. **資格情報の同期**: IMAP/SMTP パスワード・Gmail の OAuth リフレッシュ
   トークンは、Keychain 項目を iCloud キーチェーン同期対象
   (`kSecAttrSynchronizable`) にすることで、ユーザーがシステム設定で
   iCloud キーチェーンを有効にしている限り自動的に同期される。
2. **アカウント定義の同期**: account のメタデータ (種別・メールアドレス・
   ホスト名・ポート・認証方式など、秘密情報を除くすべて) を
   `NSUbiquitousKeyValueStore` 経由で同期し、起動時 + 外部変更通知受信時に
   ローカル GRDB と突き合わせる (`AccountCloudSyncEngine.reconcile()`)。

## 何が同期され、何が同期されないか

| 同期される | 同期されない |
|---|---|
| account の表示名・メールアドレス・IMAP/SMTP ホスト/ポート/接続方式・ユーザー名・認証方式・作成/更新日時 | メール本文・添付ファイル・メールボックス一覧・フラグ・スレッド (すべてローカル GRDB のみ) |
| IMAP/SMTP パスワード (Keychain, iCloud キーチェーン経由) | プッシュ通知の `deviceSecret` (APNs デバイストークンと対のデバイス固有の秘密。同期すると他デバイスがトークンなしの秘密を持つだけになり無意味なため意図的に対象外) |
| Gmail の OAuth リフレッシュトークン (Keychain, iCloud キーチェーン経由) | アクセストークン (`GoogleOAuth.TokenStore` の インメモリキャッシュのみ。各デバイスがリフレッシュトークンから自分で取得する) |
| — | `needsReauth` (デバイスごとの「このデバイスにはまだ資格情報が届いていない/再認証が必要」状態そのもの) |

`AccountCloudSync.CloudAccountSnapshot` が実際に iCloud に載る唯一の型で、
秘密情報を表すフィールドを一切持たない。

## KVS スキーマ

キー `accounts.v1` に JSON を 1 個保存する (`AccountCloudSyncEngine`):

```json
{
  "accounts": [
    {
      "accountId": "UUID文字列 (AccountRecord.id と同じ)",
      "displayName": "...",
      "email": "...",
      "authType": "password | oauth2",
      "kind": "generic | gmail | icloud",
      "imapHost": "...", "imapPort": 993, "imapSecurity": "plain|tls|startTLS",
      "imapAllowsInsecureTLS": false,
      "imapUsername": "...",
      "smtpHost": "...", "smtpPort": 587, "smtpSecurity": "...",
      "smtpAllowsInsecureTLS": false,
      "smtpUsername": "...",
      "createdAt": "ISO8601", "updatedAt": "ISO8601"
    }
  ],
  "tombstones": [
    { "accountId": "...", "deletedAt": "ISO8601" }
  ]
}
```

`NSUbiquitousKeyValueStore` は 1 キーあたり約 64KB、合計 1MB の上限が
あるドキュメント上の制約がある。このアプリが現実的に扱うアカウント数
(数十件程度) では JSON が数 KB を超えることはまず無いが、
`AccountCloudSyncEngine.maxPayloadBytes` (60,000 バイト) を超える書き込みは
サイズガードとして拒否し、既存の cloud 側の値をそのまま残す
(壊れた/肥大化したペイロードで iCloud 同期自体を詰まらせないための安全弁)。

tombstone (削除の記録) は 90 日で自動的に掃除される
(`AccountCloudSyncEngine`, `reconcile()` の冒頭)。

## 突き合わせ (reconcile) のルール

起動時、および `NSUbiquitousKeyValueStore.didChangeExternallyNotification`
受信時に `AccountCloudSyncEngine.reconcile()` が実行される:

1. **tombstone にあり、ローカルにもある** → ローカル削除 (IDLE 停止・
   Keychain パスワード削除・push watch 解除・DB カスケード削除。Keychain
   削除は同期項目なので他デバイスにも波及する — それが正しい挙動)。
2. **ローカルにあり、cloud に無い** (tombstone も無い) → cloud へ push。
   初回移行 (この機能を初めて有効化したときの既存アカウント全件) もこの
   経路で行われる。
3. **cloud にあり、ローカルに無い** (tombstone も無い) → ローカル
   GRDB に account を挿入。資格情報を Keychain から探し:
   - 見つかれば通常どおり初期同期を開始し、プッシュ通知が有効なら watch
     も登録する。
   - 見つからなければ `needsReauth = true` で挿入する (iCloud キーチェーン
     の同期がまだ追いついていない状態)。設定画面のアカウント一覧に
     「資格情報を待っています」バナー + 「再接続」ボタンが表示され、
     タップすると Keychain を再チェックする。何もしなくても、アプリ起動の
     たびに自動で再チェックされる (`AppEnvironment
     .retryPendingCredentialIfAvailable`)。
4. **両方にある** → `updatedAt` が新しい方が勝つ (last-writer-wins)。
   古い方を新しい方で上書きする (ローカルが勝てば cloud へ再 push、cloud
   が勝てばローカルの行を更新)。

ローカルでのアカウント追加時は上記の起動時/通知時 reconcile を待たず、
即座に `AccountCloudSyncEngine.pushLocalChange`/`pushLocalDeletion` で
cloud へ反映する。

## 「iCloud でアカウントを同期」トグル

設定画面 (`AccountsSettingsView`) にトグルがあり、デフォルト ON。

- **OFF**: ローカルでの新規アカウント追加時の push、起動時/通知時の
  reconcile が両方とも止まる。ローカルの同期・送受信動作自体には一切
  影響しない。
- **OFF → ON**: すぐに 1 回 full reconcile が走る。

トグルの状態自体は `UserDefaults` に保存されるデバイスローカルな設定で、
iCloud 経由では同期されない (片方のデバイスだけ切りたい場合を想定)。

## 制限

- iOS シミュレータでは実 iCloud KVS が「ローカルフォールバック」動作を
  する場合がある (Apple のドキュメント上の既知の制約)。この開発環境の
  シミュレータでは実際に KVS の内容がシミュレータ単位で永続化され
  (`xcrun simctl uninstall` では消えない — Keychain も同様)、複数の
  verify スクリプトをまたいで意図せずアカウントが「復活」する現象を
  確認した (`docs/verify.md`/`.claude/skills/verify/SKILL.md` の M11 節
  参照)。実 2 台のデバイス間での本当の同期は、この開発環境からは検証
  できない (`PENDING.md` 参照)。
- `.gmail` (`.oauth2`) kind のアカウントも同期対象だが (スキーマ上は
  generic/icloud と同列)、cloud から新規挿入されたケースの自動同期開始は
  `GoogleOAuth.TokenStore.hasStoredRefreshToken`/`.accessToken(for:)`
  経由でのみ検証しており、実 Google アカウントでの 2 台間確認は未実施
  (`PENDING.md`)。
- アカウント設定を後から編集する UI が (M11 時点で) 存在しないため、
  `updatedAt` は実質「作成時刻」からほぼ変化しない。編集 UI ができた際は
  保存のたびに `updatedAt` を更新し `pushAccountToCloud` を呼ぶ必要がある。
