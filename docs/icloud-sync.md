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

## 重複挿入バグとその修正 (実機で確認)

実機で「設定 → アカウント一覧に、まったく同じメールアドレスのアカウントが
2つ表示される」「メールを開くと、メールによって『本文の取得に失敗しました:
authenticationFailed』が出たり出なかったりする」という報告があり、原因を
特定して修正した。

### 原因

上記「突き合わせのルール」のフェーズ4 (旧実装) は、cloud にあってローカル
に無いアカウントを **`accountId` (UUID) だけで判定して**そのまま挿入して
いた。実機で直接追加したアカウントと、別デバイス (この開発ではシミュレータ)
で追加されて iCloud KVS 経由で降ってきたアカウントは、メールアドレスも
サーバー設定も完全に同一なのに `accountId` が異なる (それぞれのデバイスが
`AccountRecord.init()` で独立に `UUID()` を生成するため) — その結果、
別アカウントとして重複挿入されていた。

Keychain のパスワードは `accountId` をキーに保存されるため、降ってきた側の
UUID にはその端末の Keychain に資格情報が存在しない。統合トレイには両方の
アカウントのメールが混ざって表示されるので、「メールによってエラーが出たり
出なかったりする」という報告と一致する — 実際にはメールごとではなく、
**そのメールがどちらの重複アカウント経由で同期されたか**によってエラーの
有無が決まっていた。

シミュレータで、同じメールアドレス・同じ IMAP 設定で `accountId` だけが
異なる2つの `account` 行を直接 DB に挿入して再現し (`accountId` 以外は
一致・片方は `needsReauth = 1`)、修正前のビルドで実際に「設定 → アカウント」
に同じメールアドレスが2行表示され、2行目に「資格情報を待っています」
バナーが出ることを確認した (`apps/Otegami/UITests/OtegamiDuplicateAccountUITests.swift`
参照。実 2 台のデバイス間でこのバグを再現する経路自体は上記「制限」の理由で
検証できないが、バグが実際に残す **DB の終着状態** — 同一メールアドレスの
account 行が2つ、片方は資格情報なし — を直接作ることは同じ結論を検証する
上で妥当な代替手段と判断した)。

### 修正1: 新規の重複挿入を防止 (`AccountCloudSyncEngine.reconcile()`)

フェーズ4で cloud のアカウントを挿入する前に、`CloudAccountSnapshot
.identityKey` (`authType` + 大小文字を無視した `email`/`imapHost`/
`imapUsername` の組) で、既にローカルにある (今回のパスで既に挿入/確定
済みのものも含む) アカウントと一致しないかを確認する。一致すれば挿入せず
スキップする (`ReconcileSummary.duplicateCloudAccountIds` に記録)。

- `authType` を同一性判定に含めているのは、たまたまメールアドレスが同じ
  `.password` アカウントと `.oauth2` アカウントを誤って同一視しないための
  安全策 (資格情報の仕組みが根本的に異なるため)。
- cloud 側の走査順は `accountId` の昇順に固定した — 複数デバイスが同じ
  payload を突き合わせたとき、「どちらの重複を残すか」が実行順に依存して
  デバイスごとに割れないようにするため。
- 挿入をスキップするだけで、**cloud payload 側の重複エントリ自体は消さない**
  — 消すには tombstone を push する必要があるが、そのエントリを自分の
  ローカルアカウントとして持っている**別のデバイス**にとっては、それは
  「実在する自分のアカウントが消された」という意味になってしまう
  (「データ喪失を避ける」方針を全デバイスに一貫させるため)。このため
  cloud payload には無害な重複エントリが残り続ける可能性があるが、
  どのデバイスも新規挿入時に上記の同一性チェックでスキップするため、
  ローカルに重複した `account` 行が新たに作られることはない。

### 修正2: 既存の重複の解消 (`AccountDuplicateMerger`, 移行)

修正1は「今後」の重複挿入を防ぐだけなので、既にバグを踏んで重複してしまった
端末はそのままでは直らない。`AppEnvironment.init()` が起動のたびに
(`packages/OtegamiKit/Sources/OtegamiStore/AccountDuplicateMerger
.mergeDuplicateAccounts(db:)` を) 同期的に実行し、`AccountRecord
.identityKey` が一致するローカル `account` 行を1つに統合する。冪等
(統合後は重複グループが無くなるので次回以降は何もしない) なので、
一度きりのフラグ管理はせず毎回実行する設計にした — `FTSIndexer
.backfillIfNeeded` と同じ「解消済みなら実質無料」パターン。

**どちらの UUID を残すか**: (1) `needsReauth == false` (資格情報が動く方) を
優先、(2) 次にローカルに同期済みのメール件数が多い方、(3) 最後に
`createdAt` が古い方、の順で決定的に決める。「資格情報を持っている側を残す」
方針を素直に採用した — 資格情報が無い側を残しても、次に開いたときにまた
同じ認証エラーになるだけで実用上意味が無いため。

**データを一切失わないための設計** (最優先事項として扱った):

- `outboxMessage`/`draftMessage`/`mailTemplate`/`opQueue` は単純に
  `accountId` を書き換えて負け側から勝ち側へ引き継ぐ (一意制約が無いので
  衝突しない)。
- `thread` も同様に丸ごと引き継ぐ (一意制約が無い)。
- `mailbox` は、勝ち側にまだ無い `path` ならその `mailbox` 行ごと (配下の
  `message`/`thread` も含めて) 丸ごと引き継ぐ。
- 双方が同じ `path` (= 物理的に同じ IMAP メールボックス) を既に同期して
  いた場合 (実際に「統合トレイにメールが重複して並ぶ」原因) は、
  メッセージ単位で突き合わせる: `messageId` (無ければ `uidValidity` が
  一致する場合の `uid`) が一致するメッセージは、`isPinnedLocal` を OR、
  `flagsRaw` を OR して勝ち側の行に統合してから負け側の行を削除する
  (どちらかが true だと思っているフラグ/ピン留めは失わない)。一致する
  メッセージが勝ち側に無い (双方の同期が完全には揃っていなかった) 場合は、
  削除せず勝ち側の `mailbox` へ付け替えるだけにする — 消してよいのは
  「勝ち側に同じものが既にある」と確認できたメッセージだけ、という方針。
- 上記のいずれも「消してよいか判断がつかない場合は消さない」を徹底した
  設計になっている。回帰テスト
  (`packages/OtegamiKit/Tests/OtegamiStoreTests/AccountDuplicateMergerTests.swift`)
  で、メールを失わないこと・ピン留め/フラグが引き継がれること・下書き/
  送信待ち/テンプレート/opQueue が引き継がれること・冪等であることを
  それぞれ確認済み。

負け側の `account` 行を削除した後、この端末にだけ残っていた副作用 (Keychain
のパスワード、OAuth トークン、push watch、キャッシュされた `AccountSyncer`)
は `CloudAccountDirectory.cleanupAfterDuplicateMerge(accountId:)` が後始末
する。**tombstone は push しない** — 修正1の説明と同じ理由 (他のデバイスに
とってそのアカウントが本物である可能性を否定できないため)。

### 修正3: 資格情報が無いメールを開いたときのエラー表示

`AccountsSettingsView` の「資格情報を待っています」/「再接続」バナーは
既に存在していた (直前のコミットで `.password` アカウントにも `needsReauth`
を立てる修正が入っていたため) が、メッセージを開いたときのエラー文言は
`"本文の取得に失敗しました: authenticationFailed: missingCredential"` という
生のエラーをそのまま表示していた。`MessageView
.missingCredentialAwareErrorMessage` が、エラー発生時点でそのアカウントの
`needsReauth`/`authType` を DB から読み直し、この状態であれば「この端末には
このアカウントの資格情報がありません。設定 → アカウントの『再接続』から
パスワードを確認してください。」という、原因と次の行動が分かる文言に
差し替える (それ以外の失敗— オフライン・サーバーエラー等 — は元のエラーを
そのまま表示する)。

### 検証

- 単体テスト: `AccountCloudSyncEngineTests` (新規4件 — 同一性による重複
  挿入防止・複数重複からの決定的な1件選択・別アカウントは誤マージしない
  ・`authType` が違えばマージしない) と `AccountDuplicateMergerTests`
  (新規6件 — 無関係なら無視・資格情報がある方が生き残る・非衝突メール
  ボックスの丸ごと引き継ぎ・衝突メールボックスのメッセージ単位マージ
  (重複せず・ピン留め引き継ぎ・ユニークなメッセージは残る)・下書き等の
  引き継ぎ・冪等性)。
- シミュレータでの実機検証: `apps/Otegami/UITests
  /OtegamiDuplicateAccountUITests.swift` (3 フェーズ) — 実アカウントを
  追加 → (ホスト側から `sqlite3` で重複行を注入) → 移行を一時的にスキップ
  する `OTEGAMI_UITEST_SKIP_DUPLICATE_ACCOUNT_MERGE` フラグ付きで起動し
  「設定 → アカウント」に同じメールアドレスが2行・資格情報待ちバナーが
  出ることを確認 (修正前の状態の再現) → 通常起動 (フラグ無し) で1行に
  統合され、バナーが消え、かつ INBOX のメールが失われていないことを確認。
  `docs/verify.md` に画面遷移とスクリーンショットの詳細を記録。

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
- アカウント編集 UI (`AccountEditView`) は実装済み。保存のたびに
  `AppEnvironment` が `updatedAt` を更新してから `pushAccountToCloud` を
  呼ぶため、編集も上記の reconcile ルール (`updatedAt` が新しい方が勝つ)
  にそのまま乗る。
- 重複挿入バグの修正 (上記節) 後も、過去に重複挿入されてしまった
  cloud payload 側の「負け」エントリ (アカウントメタデータ) 自体は消えず
  に残り続けることがある — 消すと tombstone 経由で他のデバイスの実在する
  アカウントを誤って消しかねないため、意図的に消さない設計にした
  (「データ喪失を避ける」を最優先した結果のトレードオフ)。無害
  (`AccountCloudSyncEngine.reconcile()` の同一性チェックが、どのデバイス
  でもそのエントリを新規のローカル行として挿入させない) だが、KVS payload
  のサイズをわずかに消費し続ける点は既知の制約として残す。
