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
| IMAP/SMTP パスワード (Keychain, iCloud キーチェーン経由) | プッシュ通知の `deviceSecret` (APNs デバイストークンと対のデバイス固有の秘密。同期すると他デバイスがトークンなしの秘密を持つだけになり無意味なため意図的に対象外)、リレーの `registrationSecret` (Task #171: `RELAY_DEVICE_REGISTRATION_SECRET` を運用者が設定している場合に入力する共有シークレット。deviceSecret と同じく Keychain 保存だが `kSecAttrSynchronizable` を付けないため、プッシュ通知を使う端末それぞれで入力が必要) |
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
**2026-07-31 追記 (Task #189)**: このトグルの置き場所はその後2回移設
されている — 実機フィードバック第3弾 (I) で「その他」から「アカウント
の設定」(`AccountSettingsCategoryView`) へ、さらに Task #189 で新設
「一般」カテゴリ (`GeneralSettingsView`、設定カテゴリ一覧の先頭) へ。
移設したのはトグルの置き場所 (UI 上の画面) だけで、この節が説明する
挙動 (OFF/OFF→ON/`UserDefaults`ローカル設定という性質) 自体は変わって
いない。「一般」への移設理由は Task #186 で同期対象がアカウントの接続
設定を超えて設定全般へ広がり、「アカウントの設定」に属する項目とは
言えなくなったため — 詳細は本ドキュメント末尾の「Task #186」節、
実装経緯は`docs/design-system.md`「Task #189」節参照。

- **OFF**: ローカルでの新規アカウント追加時の push、起動時/通知時の
  reconcile が両方とも止まる。ローカルの同期・送受信動作自体には一切
  影響しない。
- **OFF → ON**: すぐに 1 回 full reconcile が走る。

トグルの状態自体は `UserDefaults` に保存されるデバイスローカルな設定で、
iCloud 経由では同期されない (片方のデバイスだけ切りたい場合を想定)。

## 制限

- **[訂正]** 以前この節には「iOS シミュレータでは実 iCloud KVS が
  『ローカルフォールバック』動作をする場合がある」と書いていたが、
  この前提は誤りだったことが実機汚染インシデントの調査で判明した —
  実際にはこの開発機のシミュレータは**実 iCloud** (この Mac がサイン
  インしている実 Apple ID) と通信していた。詳細と修正は下記「開発用
  アカウントの除外と実機汚染インシデント」節を参照。実 2 台のデバイス
  間での本当の同期は、この開発環境からは検証できない (`PENDING.md`
  参照)。
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

## 重複統合バグの修正後も資格情報が消えていたバグとその根本原因 (実機で確認)

上記の重複統合修正 (`8d4969c`〜`afc25f0`) を入れた実機で、新たな報告が
あった:「重複アカウントは1つに統合されたが、残ったアカウントに資格情報が
無い。設定 → アカウントに『資格情報を待っています』バナーが出続け、
『再接続』ボタンを押しても何も変化しない」。

### 根本原因: Keychain `service` 文字列のリネームによる資格情報の孤立化

調査の結果、重複統合ロジック自体のバグではなく、**その少し前に入っていた
別のコミットが Keychain 項目を事実上「行方不明」にしていた**ことが分かった。

`52df393` ("use com.mtkg as the bundle identifier prefix everywhere") は
`KeychainCredentialStore.init(service:)` の**デフォルト引数**を
`"com.m-tkg.otegami.account-password"` から
`"com.mtkg.otegami.account-password"` へ変更した。このデフォルト値は
xcconfig 由来ではなく、ソースコードに直接書かれた Swift の文字列リテラル
であり、`PRODUCT_BUNDLE_IDENTIFIER`/`Local.xcconfig` の `com.mtkg.*`
オーバーライド (このコミット自体のメッセージが「実際の signed build は
元々 com.mtkg.* を使っていた」と書いている、まさにそれ) とは完全に独立
している。つまり **実機の bundle id が何であったかに関係なく**、この
コミット以前にビルドされたアプリは全員 `"com.m-tkg.otegami.account-password"`
という service で Keychain にパスワードを保存していた。

`kSecAttrService` は Generic Password 項目の「識別子の一部」であり、
`SecItemCopyMatching` は service が一致しない項目を返さない (自由に
付け替えられるラベルではない)。したがって、このコミット以降にビルドした
アプリは、コミット前に保存されたパスワードを**すべて** `errSecItemNotFound`
として扱う — Keychain には項目が実在するのに、「一度も保存されていない」
のと区別がつかない。これがまさに「資格情報がありません」という症状であり、
`AppEnvironment.auth(for:)` がこの `nil` を見て `needsReauth = true` を
立てるため、`AccountDuplicateMerger` が (次の起動で) その直後に生存者を
選ぶ際、本来資格情報を持っているはずのアカウントまで「資格情報が無い」と
誤判定してしまう連鎖も引き起こしていた (次節参照)。`PushSettingsStore`
の `deviceSecret` (push のデバイス秘密) にも同じ形のハードコード
デフォルト文字列があり、同じ理由で同じ影響を受けていた。

**教訓**: Keychain の `kSecAttrService`/`kSecAttrAccount` のようなクエリ
識別子に使う文字列は、たとえ見た目が bundle id と同じパターンでも、
xcconfig 変数からではなく完全に独立したハードコード文字列でありうる。
「bundle id を揃えるだけの無害な rename」のつもりのコミットが、無関係な
文字列リテラルを一緒に変えてしまうと、Keychain 項目のようにストレージの
識別子そのものになっている文字列は容赦なく壊れる — レビュー時に `service`/
`account`/`kSecAttrService` 引数のデフォルト値の diff は要注意。

### 副次的なバグ: `AccountDuplicateMerger` が Keychain を直接見ていなかった

`AccountDuplicateMerger.order()` (生存者選定) は `AccountRecord
.needsReauth` という**永続化された DB カラム**だけを見ており、実際の
Keychain を都度読み直してはいなかった。`needsReauth` は「前回のアプリ
セッションが最後に観測した状態」でしかなく、上記の `service` リネームの
ように **グループ内の全アカウントについて同時に**古い/誤った状態のまま
になりうる。この場合、`!needsReauth` による一次判定が引き分けになり、
メッセージ件数/`createdAt` によるタイブレークにフォールバックしてしまう
ため、実際に資格情報を持つはずのアカウントが生存者に選ばれない可能性が
あった。

修正: `AccountDuplicateMerger.mergeDuplicateAccounts(db:hasCredential:)`
に、生存者選定用の**同期的なライブチェック** `hasCredential` 引数を追加
した。`OtegamiStore` パッケージは Keychain/`TokenStore` に依存しない設計
のため、実際のチェックはアプリ層 (`AppEnvironment.init()`) が注入する —
`.password` アカウントは `KeychainCredentialStore.password(forAccountId:)`
が同期 API なのでそのまま呼べる (`.oauth2` は `TokenStore` が `actor` の
`async` メソッドのみのため、この統合処理自体が同期的に実行される制約上
ライブチェックはできず、従来通り `!needsReauth` にフォールバックする —
実機報告は `.password` アカウントのものだったため、この制約は許容した)。
`hasCredential` を渡さなかった場合は元の `!needsReauth` の挙動に完全に
フォールバックする (「注入されなかった場合は資格情報の有無を無視しない」
という安全側設計)。回帰テスト:
`AccountDuplicateMergerTests.staleNeedsReauthColumnPicksWrongSurvivorWithoutLiveCheck`
(ライブチェック無しでは誤った生存者が選ばれることを確認) /
`.liveCredentialCheckOverridesStaleNeedsReauthColumn` (ライブチェックを
渡すと正しい生存者が選ばれることを確認)。

### 修正: Keychain のレガシー `service` 文字列からの自動回復

`KeychainCredentialStore`/`PushSettingsStore` に、現在の `service` で
見つからなかった場合に旧 `service` 文字列 (`legacyServices`) でも探す
フォールバックを追加し、見つかったら現在の `service` へ書き戻し
(delete-then-add、`kSecAttrSynchronizable = true` で保存) つつ旧項目を
削除する遅延マイグレーションを実装した (`kSecAttrSynchronizable` 未設定
の項目を M11 で移行した既存の `migrateToSynchronizableAndWrite` と同じ
パターン)。これにより、**既にこのバグで資格情報を見失っていた端末も、
パスワードの再入力なしに次回起動で自動的に回復する** — アプリ内で
ユーザーが何かする必要は無い。

`setPassword`/`deletePassword`/`deviceSecret` もレガシー `service` の
項目を洗い出して整理するので、一度パスワードを再保存する操作 (アカウント
編集画面での保存など) を経れば、レガシー項目は残らず現在の `service` に
一本化される。

### UI: 「再接続」ボタンが `.password` アカウントで機能しなかった問題

上記の Keychain 修正とは別に、`AccountsSettingsView` の「資格情報を
待っています」バナーの「再接続」ボタンは、実は `.password` アカウントに
対しては Keychain を再チェックするだけで、資格情報が実際に消えている
場合は何度押しても永久に無反応だった (M6 で Gmail の OAuth 再認証用に
作られたボタンを流用していたための設計ミス)。`AppEnvironment
.startObservingAccounts` が同じチェックを毎ティック自動実行しているため、
このボタンは「もう一度同じ自動チェックを手動で走らせるだけ」であり、
資格情報が本当に無くなっているケースでは実質的に意味の無いボタンだった。

修正: `.password` アカウントの場合、ボタンを「パスワードを入力」に変更
し、押すと `AccountEditView` (パスワード欄がある編集画面) へ直接遷移する
ようにした (`AccountsSettingsView.passwordEntryAccountId` 経由の
`navigationDestination(item:)`)。`.oauth2` アカウントの「再認証」ボタン
(Google の OAuth フローを起動) は変更していない — 認証方式によって
ボタンの文言と動作を分ける、という方針。使われなくなった
`AppEnvironment.retryPendingCredential(for:)`/`RetryPendingCredentialError`
は削除した (自動リトライ側の `retryPendingCredentialIfAvailable` だけが
残る)。

### 検証

- `KeychainCredentialStore` は `apps/Otegami/Sources` 側にあり
  `swift test` から到達できないため (Security framework の実 Keychain
  が必要)、既存のパターン通りシミュレータでの XCUITest で検証した:
  `OtegamiCredentialRecoveryUITests` — 実アカウントを追加した後、
  `OTEGAMI_UITEST_MOVE_CREDENTIALS_TO_LEGACY_KEYCHAIN_SERVICE` フラグ
  付きで再起動し (`KeychainCredentialStore
  .relocateToLegacyServiceForUITesting` で、保存済みパスワードを
  レガシー `service` へ実際に移動させて `52df393` 以前の端末の状態を
  再現する)、通常起動の自動同期 (`OtegamiApp.startIdleLoops` →
  `AppEnvironment.auth(for:)`) だけで資格情報が回復し、「資格情報を
  待っています」バナーが出ないこと、メール本文が「資格情報がありません」
  エラーにならず取得できることを確認した。
- `AccountDuplicateMergerTests` に上記の回帰テスト2件を追加し、
  `swift test` で確認 (`make test`)。
- `make mac` / `make ios` のビルドが通ることを確認。

## 続報: 上記の修正自体が未完了のままコミットされていたバグ、および孤児 Keychain エントリの救済

上記「Keychain のレガシー `service` 文字列からの自動回復」を追加した
コミット時点のワーキングツリーには、**検証用に一時的に入れた早期
`return nil` が revert されないまま残っていた**
(`KeychainCredentialStore.password(forAccountId:)` に
`// TEMPORARY-FOR-REPRO-ONLY: ... Revert immediately after.` という
コメント付きで残存)。このため、直前の節で説明したレガシー `service`
フォールバックは実際には**一度も実行されない死んだコードだった** —
`password(forAccountId:)` は常に最初の `if let data = ...` 節の直後で
`return nil` していたため、`AccountDuplicateMerger` に注入される
`hasCredential` クロージャ (`AppEnvironment.init()` 内、
`credentialStore.password(forAccountId:)` を呼ぶ) も含め、レガシー
`service` に残っている実在のパスワードは常に「無い」ものとして扱われ
続けていた。これが実機で「重複統合の生存者選定が資格情報ありを選べない」
「『再接続』を押しても何も起きない」の直接的な原因だった (レガシー
service 自動回復の"実装"自体は正しかったが、有効化されていなかった)。
`return nil` と直前のコメントを削除して復活させた
(`KeychainCredentialStore.swift`)。

### 追加の救済: 資格情報が「孤児」化した Keychain エントリの自動吸着

上記の修正だけでは、**すでにこのバグを踏んで悪い方向に統合されてしまった
端末**は救えない — 統合済みなら重複 `account` 行自体はもう存在せず、
`AccountDuplicateMerger` の生存者選定コードはそもそも実行されない。実際に
残るのは「生存アカウントに資格情報が無い」かつ「削除された側の
`accountId` を鍵とする実パスワードが、どのアカウント行にも紐付かない
まま Keychain に取り残されている」という状態 (`CloudAccountDirectory
.cleanupAfterDuplicateMerge` の資格情報削除は `Task` のため、アプリ終了
と競合して実行し切らないことがある)。

`AppEnvironment.init()` に2段構えの即時救済を追加した:

1. **統合直後 (同一起動内)**: `AccountDuplicateMerger` の返り値
   (`survivorAccountId`/`mergedAccountIds`) を使い、生存者に資格情報が
   無く、負け側のいずれかに資格情報があれば、`cleanupAfterDuplicateMerge`
   が削除する前に生存者の `accountId` へ付け替える
   (`KeychainCredentialStore.adoptOrphanedPassword`)。`.oauth2` 側の
   `hasCredential` は依然として `!needsReauth` フォールバックのままな
   ので (`TokenStore` が `async` のため同期処理内でライブチェックできない
   制約は変わらず)、この経路が万一悪い生存者を選んでしまっても資格情報
   自体は失われない安全網になる。
2. **過去の起動で既に悪い統合が終わっている場合**:
   `AppEnvironment.adoptOrphanedCredentialIfUnambiguous` が毎起動時、
   「`.password` アカウントで資格情報が無いものがちょうど1件」かつ
   「どの `AccountRecord` にも対応しない Keychain エントリ (孤児) が
   ちょうど1件」のときに限り、その孤児エントリをそのアカウントへ
   付け替える。件数が0件・2件以上のどちらでも「どれがどれに対応するか
   分からない」として何もしない (誤って別アカウントへ資格情報を付け替える
   方が、バナーを出し続けるより悪いため)。**ユーザーがすでに手動で
   `AccountEditView` からパスワードを再入力していた場合は no-op**
   (`adoptOrphanedPassword` は宛先に既に資格情報がある場合は上書きしない)。

孤児 Keychain エントリの「掃除」については、上記の吸着処理自体が
唯一の安全な当てはめ先を見つけた場合にのみ移動 (実質的に掃除) する設計
とし、それ以外の曖昧なケースでの削除は行わないことにした — 使われて
いない Keychain エントリが多少残り続けるコストは、間違った資格情報を
消してしまうリスクより小さいと判断した。

### 検証 (このセッション)

- `KeychainCredentialStore` の `allStoredAccountIds()`/
  `adoptOrphanedPassword(fromAccountId:toAccountId:)`、
  `AppEnvironment.adoptOrphanedCredentialIfUnambiguous` は Keychain 実体
  に依存するため、既存パターン通りシミュレータの XCUITest で検証した。
  `OtegamiCredentialRecoveryUITests` に
  `testOrphanedCredentialIsAdoptedOnNextOrdinaryLaunch` を追加:
  実アカウントを追加 → `OTEGAMI_UITEST_RELOCATE_CREDENTIAL_TO_ORPHAN_ACCOUNT_ID`
  フラグで資格情報を合成の孤児 `accountId` へ退避 (「悪い統合が既に
  完了した後」の終着状態を再現) → 通常起動 (フラグ無し) だけで
  「資格情報を待っています」バナーが出ないこと、本文が取得できることを
  確認 (パス済み、スクリーンショット `credential-recovery-02-orphan-
  adoption-inbox.png`)。
- `testPasswordRecoversFromLegacyKeychainServiceOnRelaunch` (上記の
  `return nil` を戻したことで初めて実際に意味のある検証になった) も
  再実行しパスを確認 (スクリーンショット `credential-recovery-01-legacy-
  service-inbox.png`)。
- `OtegamiMissingCredentialUITests` に、バナーの「パスワードを入力」
  ボタンをタップして `AccountEditView` のパスワード欄まで実際に到達
  できることを確認するステップを追加し、パスを確認 (この節の後半
  「再接続ボタンの UI 修正」は今回のセッション開始時点で既に実装済み
  だったが、実際に押下して遷移することまでは自動検証されていなかった)。
- `AccountDuplicateMergerTests`・`swift test`・`make mac`・`make ios`
  は全てグリーン。
- `scripts/verify-ios-credential-recovery.sh` を新規作成し、上記2つの
  XCUITest をシミュレータ erase → dev mailstack seed → ビルド → 実行
  の一連の流れとしてまとめた (既存の `verify-ios-icloud.sh` と同じ形)。

### このセッションで見つかった既知の制約 (このセッションの変更が原因では
### ないことを切り分け済み)

`OtegamiDuplicateAccountUITests` (前節の重複統合バグ自体の回帰テスト、
3フェーズ構成) を、ホストの `sqlite3` で重複行を注入しながら
フェーズ2・3を再実行しようとしたところ、erase 直後のシミュレータでも
「フェーズ1 (`xcodebuild test` 単体実行) → 端末 terminate → sqlite3 で
重複行 INSERT → フェーズ2 (別の `xcodebuild test` 単体実行)」という
複数回に分けた `xcodebuild test` 呼び出しの組み合わせで、フェーズ2が
`sqlite3` で直接読めば確かに2行ある App Group コンテナ内の DB を、
アプリ自身は「アカウントがありません」(0件) として観測する現象を再現
した。この API 呼び出し順序自体は今回何も変更していない
(`AppDatabase`/`AppEnvironment` のこのセッションでの変更を一時的に
無効化した状態でも同一の症状が再現することを確認済み — 原因はこの
セッションの変更ではない)。App Group コンテナの UUID 自体は
`xcrun simctl get_app_container ... groups` で確認する限り
`sqlite3` で編集した DB ファイルと一致しており、DB ファイルは編集直後
も編集後の内容のまま残っていた (アプリが消したわけでもない) ため、
`AppDatabase.makeShared` が `DatabasePool` のオープンに失敗し
`AppEnvironment.init()` の catch 節 (アサーション失敗 + インメモリ
DB へのフォールバック) を静かに踏んでいる可能性が高いと見ている
(この Xcode-beta / iOS 27 beta シミュレータで、直前の
`xcodebuild test` 呼び出しがインストールした直後のプロセスに対して
別の `xcodebuild test` 呼び出しが立て続けにインストール・起動する
という、通常の単発検証では起きない操作順序に起因する可能性が高い)。
`PENDING.md` に恒久調査の課題として記録した。この制約により、
`OtegamiDuplicateAccountUITests` のフェーズ2/3 は本セッションでは
自動実行での再確認ができなかったが、フェーズ1 (実アカウント追加) は
複数回パス済みで、かつ本セッションの変更 (`AccountDuplicateMerger`
自体は無変更、`AppEnvironment` の新規コードは上記の通り分離検証済み)
がこの挙動の原因でないことは切り分け済み。

## 開発用アカウントの除外と実機汚染インシデント

実機の設定に、削除したはずの開発用アカウント (`test1@otegami.test`) が
**2つ** (表示名「Dovecot Test1」と「test」、いずれも資格情報待ち) 復活し
続ける、という報告があった。ユーザーが削除 → tombstone push しても、
しばらくすると (別の verify 実行のたびに) 再出現する。

### 根本原因: 開発機のシミュレータ/ネイティブビルドが実 iCloud と通信していた

この機能の実装当初、「iOS シミュレータの `NSUbiquitousKeyValueStore` は
実 iCloud に接続せずローカルフォールバック動作をする」という Apple の
ドキュメント上の記述を前提にしていた (旧「制限」節)。今回の調査で、
**この開発環境ではその前提が成立していない**ことが実測で確認された。

**アーキテクチャ上の理由**: `com.apple.developer.ubiquity-kvstore-identifier`
entitlement の値は `$(TeamIdentifierPrefix)$(CFBundleIdentifier)` — つまり
Team ID + bundle id の組で決まる。この開発機の `apps/Otegami/Config
/Local.xcconfig` は開発者本人の Team ID と bundle id を設定しており、
これは `scripts/deploy-ota.sh` が
Ad Hoc 配布 IPA をビルドする際と**まったく同じ** Team ID / bundle id
である。つまり、この Mac 上のあらゆるローカルビルド (シミュレータ・
macOS ネイティブ・実機への Ad Hoc 配布) は、**同一の iCloud KVS
コンテナ**を指す同一の entitlement を持つ。そしてこの Mac 自体は
(開発機として当然) 開発者本人の実 Apple ID にサインイン
している。つまり「シミュレータ専用の隔離された iCloud」は最初から
存在せず、この Mac 上のどのビルドも実ユーザーの実 iCloud KVS
(`accounts.v1`) を直接読み書きしていた。

**実測による裏付け**: この Mac の `cloudd` (Apple 標準の iCloud デーモン)
の統一ログ (`log show`) を確認したところ、`xcodebuild test` (verify
スクリプト経由でのシミュレータ実行) のタイミングと完全に一致して、
以下のようなログが実際に記録されていた:

```
cloudd[...] [com.apple.cloudkit:CK] TCC approved access for container
containerID=iCloud.com.mtkg.otegami:Sandbox, applicationID=<...
applicationBundleID=com.mtkg.otegami>
```

これは「シミュレータのプロセスが、ホスト Mac の実 `cloudd` 経由で実
iCloud コンテナへのアクセス許可を得た」ことを示す直接的な証拠である。
`docs/verify.md` の M11 節がこれまで「シミュレータの KVS はシミュレータ
単位でローカル永続化されるだけ」と記録していた現象 (`simctl uninstall`
を跨いでアカウントが復活する) は、実際には「シミュレータの KVS 書き込みが
実 iCloud に届き、実 iCloud から読み戻されている」ことの観測結果だった
可能性が高い — ローカルキャッシュとリモート同期は外部から見分けが
つきにくく、当時は誤って前者と結論づけていた。

2つ並んで復活していたのは (旧トラブルシューティングの推測通り) 過去の
複数回の verify 実行が異なる IMAP ホスト表記 (`192.168.0.2` など) で
同じ `test1@otegami.test` を別々の `accountId` で push したものが、
重複統合ロジックの対象外 (このアカウント自体が実機にはローカル行として
存在しない、cloud のみに残った「負けエントリ」) のまま cloud payload に
残り続けていたため。

### 多層防御

上記の根本原因は「シミュレータ固有の抜け穴を塞ぐ」だけでは不十分
(`make mac` によるこの Mac 上でのネイティブ実行は、シミュレータの
話ではなく最初から普通に実 iCloud と通信する) と分かったため、2層の
独立した防御を実装した。

**層1: シミュレータのビルドはデフォルトで cloud sync に一切参加しない**
(`AppEnvironment.isCloudSyncPermittedOnThisBuild()`)。`#if
targetEnvironment(simulator)` でガードし、`AccountCloudSyncEngine` への
push (`pushLocalChange`/`pushLocalDeletion`) だけでなく reconcile の
pull (cloud → ローカル挿入) 側も止める — シミュレータに実アカウントが
降ってくるのも逆方向の汚染であるため。`-otegamiEnableCloudSyncInSimulator`
launch argument で明示的にオプトインすれば、開発者が意図的にシミュレータ
上で実 cloud sync 挙動を検証することもできる。UI テストプロセス向けに
`OTEGAMI_UITEST_DISABLE_CLOUD_SYNC` という独立した強制無効化フラグも
用意した (`targetEnvironment(simulator)` の外で UI 自動化するケースへの
保険)。`AccountCloudSyncEngine`/`AccountCloudSyncTests` は Fake
`UbiquitousStoring` を直接使うため、この層の影響を一切受けない。

**層2: 開発用ホストのアカウントは cloud payload に一切乗らない**
(`CloudAccountSnapshot.isDevelopmentAccount`/`.isDevelopmentHost(_:)`,
`packages/OtegamiKit/Sources/AccountCloudSync/CloudAccountSnapshot.swift`)。
IMAP ホストが以下のいずれかに一致するアカウントを「開発用」と判定する
純関数:

- `localhost`
- ループバック (`127.0.0.0/8`)
- プライベート LAN (`10.0.0.0/8` / `172.16.0.0/12` / `192.168.0.0/16`,
  RFC 1918)
- `.test` / `.local` ドメイン (末尾一致、大文字小文字を無視)

`AccountCloudSyncEngine.reconcile()`/`pushLocalChange` の両方がこの
判定を使う:

- ローカルのみにある開発用アカウントは、そもそも `reconcile()` の
  対象集合から除外される (cloud に「無い」とみなされて push される
  ことがない)。
- `pushLocalChange` (アカウント追加/編集直後の即時 push 経路) も同じ
  判定で早期リターンする。
- **既存の汚染データの掃除**: cloud payload 側に既に乗っている開発用
  アカウントのエントリは、`reconcile()` のフェーズ4 (cloud のみに
  存在するアカウントの挿入判定) で見つかり次第、ローカルには挿入せず、
  payload からもそのエントリ自体を削除する (tombstone は使わない —
  tombstone は「削除された」という意味を他デバイスに伝播させてしまうが、
  このエントリは「そもそも存在すべきでなかった」ものなので削除の伝播は
  不要かつ不適切)。これは**一度きりの移行処理ではなく**、`reconcile()`
  が実行されるたびに毎回チェックする設計 — この Mac だけでなく、修正版が
  入った実デバイスが次に `reconcile()` を実行した時点でも同じ掃除が働く
  (冪等・自己修復的)。この Mac に既に存在するローカルの開発用アカウント
  行自体はこの層では一切触らない (ユーザーが Settings から手動削除する
  必要がある) — 削除後に cloud 側の汚染エントリが既に掃除されていれば、
  二度と復活しない。

層2は層1と独立に効く。層1がガードするのはこの Mac のシミュレータ
ビルドのみだが、層2は macOS ネイティブビルド・実機ビルドを含む
**すべてのプラットフォーム**で、IMAP ホストが開発用アドレスかどうかだけ
を見て判定するため、`make mac` を含むあらゆる実行経路を防御する。

### 検証

- 単体テスト (`packages/OtegamiKit`, `swift test`):
  - `CloudAccountSnapshotDevelopmentFilterTests`: `isDevelopmentHost(_:)`
    の境界値 (LAN 3レンジ・ループバック・`.test`/`.local`・大文字小文字・
    172.16.0.0/12 の上下境界・"otegami.testing" のような部分一致誤検知
    防止など) を網羅。
  - `AccountCloudSyncEngineTests` に新規4件: `pushLocalChange`が開発用
    アカウントを無視すること、`reconcile()` がローカルの開発用アカウント
    を push しないこと、cloud のみにある開発用アカウントを挿入せず
    payload から除去すること (`ReconcileSummary
    .purgedDevelopmentAccountIds`)、既にローカル行が存在する開発用
    アカウントについてはローカル行を一切触らずに cloud 側のエントリだけ
    を掃除すること。
  - 既存の重複挿入バグ回帰テスト群が `imapHost: "imap.otegami.test"` を
    汎用フィクスチャとして使っていたため (`.test` ドメインのため今回の
    層2フィルタに引っかかってしまう)、本題ではないこれらのテストのホスト
    を `imap.otegami-mail.example` に差し替えた (テストの意図・アサーション
    は無変更)。
- シミュレータでの実機相当検証: `scripts/verify-ios-cloud-sync-isolation.sh`
  (新規) — シミュレータを `erase` してクリーンな状態にし、
  `OtegamiCloudSyncSimulatorIsolationUITests` (新規、
  `-otegamiEnableCloudSyncInSimulator` を付けない通常起動で dev
  mailstack の Dovecot アカウントを追加) を実行しつつ、ホスト側の
  `log show` でその時間窓に `cloudd` が `iCloud.com.mtkg.otegami`
  コンテナへのアクセスを一切ログしていないことを確認する — 「シミュレータ
  からの cloud sync トラフィックがそもそも発生しない」ことを、アプリ内部
  ではなくホスト OS のデーモンログという外部の事実で検証する設計 (この
  節の根本原因調査で使ったのと同じ手法)。実行結果: `docs/verify.md`
  「実行時の環境ノート」に既に記録されている既知の flake (`simctl erase`
  直後の1回目のテストは IMAP 接続が不安定になることがある) を1回踏んだ
  ため、その回だけ接続テストが `connectionFailed` で落ちた (このテスト
  自身は cloud sync とは無関係な、erase 直後のシミュレータのネットワーク
  スタック初期化タイミングの既知の問題)。同じフェーズを単体で再実行して
  成功し、その成功した実行の開始〜終了の実時刻について `log show` を
  実行した結果、`cloudd`/CloudKit の `iCloud.com.mtkg.otegami` コンテナ
  アクセスは**0件**だった (`PASS`) — シミュレータの cloud sync ゲートが
  効いていることを確認。
- `make test` / `make ios` / `make mac` がグリーンであることを確認。
- OTA 配信後、ユーザーが実機で既存の2つの復活アカウントを手動削除すれば
  (今回の修正により cloud 側の汚染エントリも同時に掃除されるため) 再発
  しなくなるはず — これは実機でのユーザー自身の最終確認が必要
  (`PENDING.md` 参照)。

## 表示設定の同期 (Task #89)

実機報告: アプリを再インストールすると、スレッド表示などの表示設定が
既定値 (ON) に戻ってしまう — 原因は単純で、`UserDefaults` はアプリの
アンインストールとともに消えるため、再インストール後は初回起動と区別が
つかない。これまでの account 同期 (`accounts.v1`) はアカウントの接続設定
だけを対象にしており、UI の表示設定はそもそも同期対象外だった。この節は
その隙間を埋める、`accounts.v1` の隣に置く2本目の KVS ペイロード。

### 何が同期され、何が同期されないか

`AppSettingsCloudDirectory` (`apps/Otegami/Sources/Support/`) の
allowlist が唯一の情報源:

| 同期される | 同期されない |
|---|---|
| 一覧: スレッド表示・未読のみ・フラグ付きのみ (Task #142)・アカウントでグループ化 (`ListDisplaySettingsStore`) | 通知系のうちデバイス固有の部分 (`PushSettingsStore` の device id・per-account watch map・enabled フラグ・deviceSecret — Keychain) |
| ビューア: 背景を常に白・ダーク反転オプトイン (`HTMLDisplaySettingsStore`)、画像自動表示2種 (`ImageSettingsStore`) | UITest/verify 系フラグ (`OTEGAMI_UITEST_*`/`-otegami*` は環境変数・起動引数であり、そもそも `UserDefaults` キーではない) |
| — | Task #171 の registrationSecret、Task #173 follow-up でリレー URL 自体も同じ扱いに変更: どちらもビルド時埋め込み (`RelayRegistrationSecretConfig`/`RelayURLConfig`) になり、ユーザーが入力する値そのものが存在しなくなったため同期対象から除外 (Task #121 は撤回 — `PushSettingsStore.relayURLKey` は旧値の一度きりの後始末用にのみ残っている) |
| スワイプ割り当て4スロット (`SwipeActionSettingsStore`)、フッターツールバーの表示/非表示・並び順 (`MessageToolbarSettingsStore`、Task #100 で表示/非表示を追加 — 詳細は `docs/settings.md`)、ハンバーガーメニューのカテゴリ並び順 (`FolderCategoryOrderStore`) | `CloudSyncSettingsStore.isEnabled` 自身 (この同期に参加するか自体がデバイスごとの選択 — その doc comment参照) |
| アバターソース4種 (`AvatarSourceSettingsStore`)、翻訳自動実行・一覧要約表示 (`TranslationSettingsStore`)、AI 機能マスタースイッチ (`AIFeaturesSettingsStore`) | ピン留め (`PinSettingsKeys` — 端末ごとの一時的な整理という性質が強く、複数デバイスで強制する意味が薄い) |

### KVS スキーマと reconcile ロジック

キー `settings.v1` に `SettingsCloudPayload` (`packages/OtegamiKit/Sources/AccountCloudSync/`)
を1個保存する:

```json
{
  "values": { "listDisplay.threading": { "bool": false }, "swipeActions.leadingShort": { "string": "toggleRead" }, "...": "..." },
  "updatedAt": "ISO8601"
}
```

account 同期と違い、これはアカウントごとの配列ではなく1つのフラットな
`[key: value]` バッグで、**ペイロード全体に対して `updatedAt` が1つ**
だけ — 個々の設定同士に整合性の制約はなく、「どちらか新しい方が全体を
勝つ」で十分という設計判断 (`SettingsCloudPayload`のdoc comment)。

`SettingsCloudSyncEngine.reconcile()` は毎回この3択で決める:

1. **このデバイスの前回同期時点 (`lastSyncedSnapshot`) から値が変わって
   おらず、かつ cloud 側がそれより新しい** → pull (他デバイスが後から
   push した)。
2. **このデバイスが一度もこの機能で同期したことがなく
   (`lastSyncedSnapshot == nil`)、かつ cloud に既に何か入っている** →
   pull (push しない)。**これが再インストールバグの直接の修正点**:
   `lastSyncedSnapshot` 自体も `UserDefaults` に保存する端末ローカルの
   目印なので、再インストール直後はこれも消えており「一度も同期して
   いない」に見える。この状態で自分の既定値を push してしまうと、他の
   デバイスが選んだ本当の値を黙って上書きしてしまう — それを避けて
   常に「まず cloud を信じて pull」を優先する。
3. **それ以外** (前回同期時点から値が変わっている = ローカルで変更が
   あった、または本当にこの端末が最初の1台で cloud も空) → push。

account 同期の `pushLocalChange`/`pushLocalDeletion` のような書き込み箇所
フックは採用していない — 対象キーは `MailListSettingsView`/
`MailViewerSettingsView`/`MessageToolbarSettingsView`/スワイプ設定ピッカー
など十数箇所のビューが直接 `@AppStorage` で読み書きしており、単一の
チョークポイントが存在しないため。代わりに `OtegamiApp
.handleScenePhaseChange` がフォアグラウンド/バックグラウンド遷移のたび
(`.active`/`.background`/`.inactive`) に `reconcile()` を呼び、
`UserDefaults` の現在値と前回同期時のスナップショットを比較した差分だけ
書き出す/取り込む、という低コストな方式を採用した。起動時と
`didChangeExternallyNotification` (他デバイスの push を検知) でも
`accountCloudSync` と同じタイミングで呼ばれる。

トグルは既存の「iCloud でアカウントを同期」1本を共用する — 表示設定も
「この端末の `UserDefaults` は信頼できないことがある」という同じ問題の
一種であり、別トグルを増やす理由がないため。シミュレータ/開発ビルド汚染
ガード (`AppEnvironment.isCloudSyncPermittedOnThisBuild()`) も
`accountCloudSync` と全く同じ関数を共有する。

### 検証

- 単体テスト (`packages/OtegamiKit`, `swift test --filter SettingsCloudSyncEngineTests`):
  `FakeUbiquitousStore`/`FakeLocalSettingsDirectory` を使い、上記3択の
  各分岐 (初回 push、再インストール相当の pull-not-push、既存 snapshot
  からの push/pull、`isSyncEnabled == false` での短絡) を検証。
  `make test` で他の既存テストと合わせて全件グリーンを確認 (`packages/OtegamiKit`
  配下、9パッケージ・35以上のスイート)。
- `make ios` / `make mac` のビルドが通ることを確認。
- **実機での確認はこのセッションでは未実施** — 「再インストール後に
  設定が復元されるか」は実機で OTA インストール→設定変更→アプリ削除→
  再インストールという手順を踏まないと確認できない。`PENDING.md` に
  確認依頼を記載。

## スレッド表示トグルが再起動で戻るバグ (Task #101)

実機報告: スレッド表示をオフにしても、アプリを再起動すると再びオンに
戻る。#89 (表示設定の同期、上の節) 導入後に出た症状。

### 原因

ユーザー提示の2つの仮説のうち、コードレビューと再現テストで実際に
突き止められたのは2つ目のもの — **`reconcile()` の3択判定自体に、
判定に使った値が古くなる (stale) レースがあった**:

`reconcile()` は `cloudPayload`/`localValues`/`snapshot` を読んでから
push/pull を決めるが、`localValues`/`snapshot` の読み出しはどちらも
`await` を挟む本物のサスペンションポイントで、しかも `reconcile()`
自体、**他デバイスの push が `didChangeExternallyNotification` 経由で
届くたびに新しく呼ばれる** ため、この一連の判定処理はユーザーの
ちょうどそのタイミングの操作 (トグル) と平行して走りうる。

具体的な再現シーケンス:

1. このデバイスの `snapshot`・`localValues` がまだ一致している (前回
   同期以降ローカル変更なし) 状態で、たまたま他デバイスの新しい push
   が届き、`reconcile()` が「pull しよう」と決める。
2. その判定の直後・実際に `apply()` でローカルに書き込むまでの
   わずかな窓で、ユーザーがスレッド表示トグルをオフにする
   (`UserDefaults` へ即書き込み)。
3. 修正前の `reconcile()` はこの窓を一切見ておらず、判定時に読んだ
   (トグル前の) 値のまま `local.apply(cloudPayload)` を実行 — ユーザー
   のオフ操作をそのまま黙って上書きしてしまう。UI 上は「オフにしたのに
   何もしていないのに勝手にオンへ戻った」としか見えない。

もう1つの仮説 (バックグラウンド遷移の `reconcile()` が push 前に kill
される) は、コードを辿った限りでは **`reconcile()` 単体では実際には
安全**だと確認した — `snapshot != localValues` である限り、push が
1回失敗しても次回起動時の `reconcile()` が必ずローカルの最新値を
再度 push する (このパスは `localChangeSinceLastSyncIsPushedEvenWhenA
CloudPayloadAlreadyExists` テストが既にカバーしており、Task #101 でも
壊していない)。とはいえ「ローカル変更が push されるまでの時間窓」を
縮めておくこと自体は無駄ではないため、下記の (2) は保険として追加した。

### 修正

1. **`SettingsCloudSyncEngine.reconcile()` の pull 直前再チェック**
   (`packages/OtegamiKit/Sources/AccountCloudSync/SettingsCloudSyncEngine.swift`):
   pull すると決めた2分岐 (「ローカル変更なし・cloud が新しい」「未同期
   デバイス・cloud に何かある」) はどちらも共通の `pull(_:becauseOfReason
   :observedLocalValues:snapshot:)` を通るようにし、そこで
   `apply()` する直前にもう一度 `local.currentValues()` を読み直す。
   判定時に見た値と食い違っていれば (=判定中にローカルへ書き込みが
   あった)、pull を中止してその最新のローカル値を push する側に倒す
   — 「判定中に見つかった新しいローカル変更は、古い判定に基づく pull
   より常に勝つ」という保証を関数の構造として持たせた。
   再インストール時の「cloud 優先で復元」(#89 の要点) 自体は変えていない
   — 通常時 (再チェックで食い違いが出ない) は完全に元の3択のまま。
2. **`UserDefaults.didChangeNotification` のデバウンス push**
   (`apps/Otegami/Sources/AppEnvironment.swift` の
   `settingsChangeNotificationObserver`/`scheduleDebouncedSettingsPush()`):
   `UserDefaults.standard` へのあらゆる書き込みを監視し、3秒デバウンス
   した上で `settingsCloudSync.reconcile()` を叩く。これまでは
   フォアグラウンド/バックグラウンド遷移でしか push の機会がなく、
   ユーザーが設定を変えたままバックグラウンドに一度も回らず使い続けた
   場合、その変更がセッション中ずっと未 push のままになり得た —
   この仕組みで「変更してから数秒後には push 済み」に近づけ、上記の
   レース (もう1つの仮説) が実際に起きる確率もあわせて下げている。
   `AppSettingsCloudDirectory.swift` は変更していない (他エージェントが
   並行して同ファイルを編集中だったため、エンジン側で完結する設計を
   優先した)。
3. **OSLog 計装** (`SettingsCloudSyncEngine` の
   `Logger(subsystem: "com.mtkg.otegami", category: "SettingsCloudSync")`):
   `reconcile()` の呼び出しごとに push/pull/no-op/disabled の結果・理由・
   ローカルとクラウドで食い違っているキー・`snapshot`/`cloud` それぞれの
   `updatedAt` を1行で出力する。実機で切り分けるときは:

   ```sh
   xcrun simctl spawn booted log stream \
     --predicate 'subsystem == "com.mtkg.otegami" && category == "SettingsCloudSync"' \
     --style compact
   # 実機の場合: Console.app で同じ subsystem/category を検索、または
   # log stream --predicate '...' をデバイスに対して実行。
   ```

### 積み残し (v2 移行) → Task #144 で解消

当時見送った「ペイロード全体を1つの `updatedAt` で丸ごと上書きする
現行方式から、キー単位の `updatedAt` (per-key last-writer-wins、
`settings.v2`、v1 読み取り互換) へ移行する」案は、iPhone/iPad/Mac の
複数デバイス運用を見据えて Task #144 で実施した。詳細は下の
「Task #144」節参照。

### 検証

- 新規ユニットテスト (`SettingsCloudSyncEngineTests`):
  - `concurrentLocalChangeDuringAPullDecisionIsNotDiscarded`: 上記の
    レースそのものを `AsyncGate`/`FakeLocalSettingsDirectory
    .onLastSyncedSnapshot` フックで決定的に再現。修正前のコードに
    戻すと実際に失敗する (`.pulled` になり、トグルがロールバックされ、
    クラウドの値も上書きされない) ことを確認してから修正を適用した。
  - `twoDevicePingPongConvergesOnTheNewestValue`: デバイス A (最初に
    push)・デバイス B (pull → ローカルでオフに変更 → push) ・
    デバイス A が再度 reconcile、という順序で、最終的に一番新しい
    変更 (デバイス B のオフ) に両デバイスとも収束することを確認。
  - 既存6本 (`firstDeviceEverPushesItsCurrentValuesAsTheInitialPayload`
    ほか) は無改修のまま全件グリーン。
- `make test` (`packages/OtegamiKit`) 実行、`AccountCloudSyncTests`
  37件全件グリーンを確認。既知の無関係 flake
  (`MessageBuilderTests` の日本語ラウンドトリップ) のみ発生、無視可。
- `xcodebuild ... -destination 'platform=macOS' build` /
  `-destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build`
  (`make mac`/`make ios` 相当) をそれぞれ直接実行し、`BUILD SUCCEEDED`
  を確認。
- **実機での確認はこのセッションでは未実施** — iCloud KVS 自体が
  シミュレータで不安定なため (`docs/verify.md`)。ユーザー側の確認手順:
  1. 実機でスレッド表示をオフにする。
  2. すぐ (デバウンス猶予の3秒以内) にアプリスイッチャーからスワイプ
     して kill し、再起動する — オフのままであることを確認。
  3. 上記の `log stream` コマンドで `reconcile -> pushed`/`pulled` の
     行と `diffKeys`/`updatedAt` を見て、押し戻す挙動が実際に無いか
     継続的に確認できる。
  4. 複数デバイスがある場合、片方でオン⇔オフを繰り返しても、最終的に
     全デバイスが同じ値に収束することを確認 (`docs/icloud-sync.md`の
     この節が指す「last write wins」の既知の制約自体は変わっていない
     ので、同時刻に近い操作は最後に reconcile したデバイスの値が勝つ)。

## Task #144: 設定 iCloud 同期の settings.v2 化 (キー単位マージ)

### 動機

上の Task #101 の「積み残し (v2 移行)」— iPhone/iPad/Mac を並行して
使うユーザーが、2台それぞれで*別々の*設定を同時期に変えると、後から
reconcile した方の push がペイロード全体を丸ごと上書きし、片方の変更が
無かったことになる (`SettingsCloudPayload`の旧 doc comment が既知の
設計限界として明記していた)。#101 の対症療法 (pull 直前再チェック、
デバウンス push) はこの限界そのものを直してはいなかったため実施した。

### 修正

1. **`SettingsCloudPayload` のペイロード形式変更**
   (`packages/OtegamiKit/Sources/AccountCloudSync/SettingsCloudPayload.swift`):
   `values: [String: SettingsCloudValue]` + 1つの `updatedAt` という
   旧形式 (v1) から、`entries: [String: SettingsCloudEntry]` (キーごとに
   `value` + `updatedAt`、新設した `SettingsCloudEntry`) という形式
   (v2) へ変更。`Codable` は手書きの `init(from:)`/`encode(to:)` で
   **読み取りは `entries` (v2) → 無ければ `values`/`updatedAt` (v1、
   全キーが同一 `updatedAt` を持つものとして `entries` へ変換) の順に
   フォールバック、書き込みは常に v2 のみ**。既存コード/テストとの
   後方互換のため、`values`/`updatedAt` は entries から導出する
   computed property として残した (`values` = 各エントリの value を
   集めた辞書、`updatedAt` = 全エントリ中最新の値) — `SettingsCloudPayload
   (values:updatedAt:)` という v1 形式の初期化子も、全キーに同じ
   `updatedAt` を割り当てる形で残してある。
2. **KVS キー自体も `"settings.v1"` → `"settings.v2"` へ**
   (`SettingsCloudSyncEngine.payloadKey`/`legacyPayloadKeyV1`):
   同じキーのままスキーマだけ変えると、この変更が入った端末と
   まだ入っていない端末 (同一ユーザーが iPhone だけ先にアップデート
   した場合など) が同じキーを取り合い、互いのペイロードをデコード
   できず「クラウドは空」と誤認してデフォルト値を push し合う恐れが
   あったため、物理的なキーも分けた。`loadPayload()` は `"settings.v2"`
   キーが無い場合のみ `"settings.v1"` を読む (`v1` キーへは二度と
   書き込まない — 読み取り専用のフォールバック)。
3. **`SettingsCloudSyncEngine.reconcile()` のキー単位マージ**
   (`merge(cloudPayload:snapshot:)`、新規): これまでの
   「ローカル未変更・クラウドが新しい → pull、それ以外 → push」という
   ペイロード全体の二択を、`snapshot` (この端末が最後に同期した状態)
   が存在する定常状態では**キーごとの last-writer-wins マージ**に
   置き換えた。各キーについて:
   - ライブ値が `snapshot` のそのキーと一致していれば「未変更」——
     候補タイムスタンプは `snapshot` がそのキーに持つ `updatedAt`
     (無ければ `.distantPast`)。
   - 一致していなければ「この端末で変更された」——`UserDefaults`の
     書き込みには per-key のフックが無い (`AppSettingsCloudDirectory`
     のdoc comment) ため、正確な変更時刻は分からず、`now()` (=この
     reconcile の実行時刻) を割り当てる。
   - クラウド側のそのキーの `updatedAt` と比較し、新しい方が勝つ
     (同点はローカル優先、タイブレーク)。
   マージ結果は「ローカルの値と食い違うキーがあれば `local.apply(_:)`」
   「クラウドの値/タイムスタンプと食い違うキーがあれば push」を
   それぞれ独立に判定するため、**同じ1回の reconcile で pull と push が
   両方起きうる** —— 新設した `SettingsReconcileResult.merged` がその
   ケースを表す (両方=`.merged`、pullのみ=`.pulled`、pushのみ=`.pushed`、
   どちらも無し=`.inSync`)。「一度も同期したことが無い端末」(再
   インストール直後など、`snapshot == nil`) は従来どおりペイロード
   全体の pull/push のまま (キー単位で比較する基準となる `snapshot` が
   そもそも無いため) — #89 の「再インストール時はクラウド優先」は
   無変更。
   Task #101 の「pull 直前再チェック」は `merge(cloudPayload:snapshot:)`
   自身が `local.currentValues()` を**関数の唯一の情報源として**その場で
   読み直す形に一般化された (`reconcile()`が事前に読んだ値は一切信用
   しない) —— 個別の再チェック分岐が要らなくなった。「一度も同期して
   いない端末」の pull 経路 (`pull(_:becauseOfReason:observedLocalValues:)`)
   は元々の再チェックのまま維持。
4. **OSLog**: `log(_:reason:local:cloud:snapshot:)` の `diffKeys` は
   `SettingsCloudPayload.values` (entries から導出) を経由するため
   無改修で動作。`reason` にキー単位マージの適用キー一覧を含めるよう
   `merge(cloudPayload:snapshot:)` 内で組み立てるようにした。

### 検証

- `SettingsCloudSyncEngineTests` に新規3本追加:
  - `neverSyncedUnderV2FallsBackToReadingTheLegacyV1Payload`: `"settings.v1"`
    キーだけに旧形式 (`values`/`updatedAt` の生 JSON、`SettingsCloudPayload`
    経由ではなく手書きのミラー型でエンコード) を仕込み、新コードが
    それを正しく読んで pull し、以後は `"settings.v2"` 側にだけ書く
    ことを確認。
  - `simultaneousChangesToDifferentKeysOnDifferentDevicesAreBothKept`:
    2台がそれぞれ別々のキーを変更 → 後から reconcile した側が
    `.merged` を返し、両方の変更が生き残ることを確認 (修正前の
    ペイロード全体上書き方式に戻すと、どちらか一方が消えて失敗する)。
  - `perKeyPingPongAcrossTwoKeysConvergesOnBothLatestValuesIndependently`:
    2キー × 2ラウンドの往復で、両キーとも独立に最新値へ収束すること
    (`twoDevicePingPongConvergesOnTheNewestValue`の複数キー版) を確認。
  - 既存9本 (`firstDeviceEverPushesItsCurrentValuesAsTheInitialPayload`
    ほか、Task #101 分含む) は `"settings.v1"` → `"settings.v2"` の
    キー名をテストの assertion 側で置き換えただけで、シナリオ・
    期待結果は無改修のまま全件グリーン。
- `make test` (`packages/OtegamiKit`) で `AccountCloudSyncTests` 含め
  全件グリーンを確認。
- **実機での確認はこのセッションでは未実施** — iCloud KVS 自体が
  シミュレータで不安定なため (`docs/verify.md`)。ユーザー側の確認手順:
  1. iPhone と iPad (または Mac) で別々の設定 (例:
     iPhone でスレッド表示、iPad で未読のみ表示) を短時間のうちに
     変更する。
  2. 両方が数秒〜次回起動までに reconcile した後、**両方の変更が
     両方の端末に反映されている**こと (どちらか一方が消えていない
     こと) を確認 —— これが #144 の主眼で、#101 までの実機確認手順
     (単一キーのオン/オフが揮発しないこと) とは別に見るべき観点。
  3. `log stream --predicate 'subsystem == "com.mtkg.otegami" &&
     category == "SettingsCloudSync"'` で `reconcile -> merged` の行が
     実際に出ること、`diffKeys` が想定どおりのキーになっていることを
     確認。

## macOS: iCloud で同期されたパスワード型アカウントの認証が切れて再認証できないバグ (2026-07-29 実機報告)

実機報告:「mac 版において、iCloud で同期されたアカウントの認証が切れて
いるが再認証できない」。背景 (このドキュメントの前提どおり): アカウント
本体は iCloud KVS で同期されるが、資格情報 (パスワード/OAuth token) は
Keychain 所在で、`kSecAttrSynchronizable` 経由の iCloud キーチェーン同期
に委ねられる — 別端末で先に追加したアカウントが Mac に「アカウントは
あるが認証が無い (`needsReauth`)」状態で現れるのは元々正規の一時状態
(この文書の「突き合わせのルール」フェーズ3) だが、Mac 側でこの状態から
抜け出す手段が実質無かった。

### 真因: iOS と macOS の Keychain Access Group 不一致 (パスワード型のみ)

`.password` 種別 (iCloud/その他IMAP/Yahoo 等) のアカウントは
`KeychainCredentialStore` がパスワードを保存する。この store は
`kSecAttrAccessGroup` を問い合わせに使えるが:

- **iOS**: `Otegami-iOS.entitlements` の `keychain-access-groups` により
  明示的なグループ文字列 `$(DEVELOPMENT_TEAM).$(OTEGAMI_BUNDLE_ID).shared`
  を渡していた (M9: `NotificationService` Extension と共有するため)。
- **macOS (このバグ修正前)**: `Otegami-macOS.entitlements` にこの
  entitlement 自体が無く、`OtegamiAppGroup.keychainAccessGroup` は
  macOS で常に `nil` を返していた (M9 当時、macOS には共有すべき
  `NotificationService` が存在しないという理由だけで iOS 限定にされて
  いた)。`accessGroup: nil` は「グループ指定なし」ではなく「プロセスの
  既定グループ」を意味する。

`kSecAttrAccessGroup` はACLの権限チェックではなく**完全一致の属性
フィルタ**なので、iOS が明示グループ付きで書いたパスワードアイテムは、
たとえ iCloud キーチェーン経由で実際にこの Mac のキーチェーンへ物理的に
同期されていても、グループ指定の無い macOS 側のクエリには**絶対に見え
ない**。これが「認証が切れているのに再認証(=資格情報の到着待ち)が
永遠に終わらない」の実体だった。

一方、**OAuth (Gmail/Microsoft) の再認証はこのバグの影響を受けない** —
リフレッシュトークンを保存する `RefreshTokenStoring`
(`KeychainRefreshTokenStore`) はそもそもどちらのプラットフォームも
明示グループを指定しない実装のままだったため、iOS/macOS とも同じ
「プロセスの既定グループ」に書く/読むという一貫した挙動になっており、
今回の不一致は生じていない。Gmail/Microsoft アカウントの「再認証」ボタン
(`ASWebAuthenticationSession` 経由、`AuthPresentationContextProvider`は
既に macOS 分岐 `NSApplication.shared.keyWindow` を持っている) は、この
節のバグとは無関係に元から動作するはず — 認証切れ自体は「トークンが
実際に失効/取り消された」という正当な理由である可能性が高い。

### 修正

1. `apps/Otegami/Config/Otegami-macOS.entitlements` に
   `keychain-access-groups`(`$(OTEGAMI_KEYCHAIN_GROUP)`、iOS と同じ文字列)
   を追加。
2. `OtegamiAppGroup.keychainAccessGroup` の macOS `nil` オーバーライドを
   撤去 — 両プラットフォームとも Info.plist の値 (`OTEGAMI_KEYCHAIN_GROUP`)
   をそのまま返す。`identifier` (App Group、`NotificationService`専用) は
   macOS `nil` のまま — この節の対象外。
3. **後方互換の移行**: この修正**以前**の macOS ビルドで、この Mac上で
   直接追加していたパスワード型アカウント (iCloud KVS 経由でなく) は、
   当時の `accessGroup: nil` (= プロセスの既定グループ、`.shared`接尾辞
   無し) で書かれている。修正後、`accessGroup`が非nilになった新しい
   クエリだけではこれらの既存アイテムが**逆に見えなくなる**回帰リスクが
   あったため、`KeychainCredentialStore.password(forAccountId:)` に
   「グループ指定を外した問い合わせでも探し、見つかればそれを新しい
   グループへ書き直す」フォールバックを追加した (`legacyServices`の
   サービス名リネーム救済と同じ「次に読んだときに移行する」形)。

### 検証

`make test`/`make mac`/`make ios` は緑 (`make mac`のビルド成功は、
macOS 自動署名がこの新しい Keychain Sharing capability を問題なく
解決できたことも意味する)。**実機での確認は未実施** — 具体的には:

- パスワード型 (iCloud/generic/Yahoo) アカウントについて: iOS で
  アカウントを追加 → iCloud キーチェーンが同期 → Mac 側の同じアカウントで
  「資格情報を待っています」バナーが自動的に消え、同期が再開すること。
- 上記の後方互換フォールバックが実際に機能すること: 修正前のビルドで
  Mac 上に直接追加していたパスワード型アカウントが、修正後のビルドに
  更新してもパスワードを再入力せずに済むこと。
- Gmail/Microsoft の「再認証」ボタンが Mac の設定画面から実際に
  `ASWebAuthenticationSession` の同意画面を開き、完走できること
  (この開発環境ではブラウザでの実ログインまでは検証できない)。
- 万一「再認証できない」がまだ再現する場合、それはこの節のバグとは
  別の原因 (実際にトークン/パスワードが失効している等) である可能性が
  高い — その場合は改めて切り分けが必要。

### 別端末での再認証手順 (ユーザー向け)

Mac の設定 → アカウント一覧で、あるアカウントに「資格情報を待って
います」(パスワード型) または「再認証が必要です」(Gmail/Microsoft) が
出ている場合:

- **パスワード型 (iCloud/その他IMAP/Yahoo)**: 上記の修正後は、iOS/iPad
  側で同じ Apple ID の iCloud キーチェーンが有効なら、多くの場合しばらく
  待つだけで自動的に解消する (`retryPendingCredentialIfAvailable`が
  アカウント一覧の更新のたびに自動チェックする)。すぐに使いたい場合は
  「パスワードを入力」から手動でパスワードを再入力して保存すれば即座に
  解消する。
- **Gmail/Microsoft (OAuth)**: 「再認証」ボタンから対話的なサインイン
  フローが開く。これは端末ごとに独立しており、iCloud 同期に依存しない
  — 別端末で再認証済みでも Mac 側では改めてこのボタンからサインインが
  必要。

## macOS は設定 (settings.v2) を同期対象から除外、アカウントのみ同期 (2026-07-29)

ユーザー指示「mac では、アカウント以外の情報は iCloud 同期しなくて良い」
に対応。**アカウント本体の同期 (`accounts.v1`、このドキュメントの本題)
は macOS でも従来どおり有効** — 変更したのは表示・操作設定
(`settings.v2`、Task #89/#144、上の「表示設定の同期」節) だけ。

### 実装

`AppEnvironment.init()` が `SettingsCloudSyncEngine` に渡す `isEnabled`
クロージャを `#if os(macOS)` で分岐し、macOS では無条件に `false` を
返すようにした:

```swift
self.settingsCloudSync = SettingsCloudSyncEngine(
    store: SystemUbiquitousStore(),
    local: AppSettingsCloudDirectory(),
    isEnabled: { [cloudSyncSettings] in
        #if os(macOS)
        false
        #else
        cloudSyncSettings.isEnabled && AppEnvironment.isCloudSyncPermittedOnThisBuild()
        #endif
    }
)
```

`SettingsCloudSyncEngine`のpush/pull双方の経路 (`reconcile()`・
`pushLocalChange`相当) はどれもこの`isEnabled`を毎回読み直してから
動くため (`docs/icloud-sync.md`の他の節が既に前提にしている挙動)、
ここ1箇所のゲートだけで「macOSは読みも書きもしない」を達成できる —
呼び出し側 (`setCloudSyncEnabled`のOFF→ON即時reconcileなど) は無改造
のままで良い。`accountCloudSync`(アカウント本体)は別のエンジン
インスタンスで、このゲートの影響を受けない。

### スコープ外だったもの

- 「iCloud でアカウントを同期」トグル (当時は`AccountSettingsCategoryView`
  の`settings.cloudSyncToggle`、Task #189 で`GeneralSettingsView`へ移設
  — 上の「「iCloud でアカウントを同期」トグル」節の追記参照) はラベルど
  おりアカウント同期 (`accountCloudSync`) 専用のまま — この変更で意味が
  変わったわけではない。
- Task #121 でプッシュリレー URL を「設定」側の同期対象に含めていたが、
  Task #173 follow-up でリレー URL 自体がビルド時埋め込み
  (`RelayURLConfig`) に変わり、同期対象から除外済み — この節はもはや
  macOS 固有の話ではなく iOS 間でも同期しない。

### 検証

`make test`/`make mac`/`make ios` は緑。**macOS で設定を変更しても
他端末 (iOS/iPad) に伝播しない/他端末の設定変更が macOS 側に反映
されないことの実機確認は未実施** (iCloud KVS はシミュレータで不安定
なため、`docs/verify.md`) — ユーザー側の確認手順:

1. macOS でスレッド表示・スワイプ割り当てなど「設定」側の項目を変更
   する。
2. iPhone/iPad 側でその変更が**反映されない**こと (今までどおり
   iOS/iPad 間だけで同期されること) を確認。
3. 逆に iPhone/iPad 側で同種の設定を変更しても、macOS 側は変わらない
   ままであることを確認。
4. アカウントの追加・削除・編集は、この変更後も引き続き macOS ⇔
   iOS/iPad 間で同期されることを確認 (今回のゲートの対象外)。

## macOS でも設定を同期する (Task #186、方針の反転)

ユーザー要望 (2026-07-30〜31)「iCloud でアカウントの設定以外も全て
同期して欲しい」。上の「macOS は設定 (settings.v2) を同期対象から除外」
節がまさに実装した挙動そのものを、ユーザー自身が明示的に覆した —
**意図的な方針転換であり、バグ修正ではない**。今回の変更:

- `AppEnvironment.init()` の `settingsCloudSync` の `isEnabled` から
  `#if os(macOS) { false }` 分岐を削除し、`accountCloudSync`/
  `templateCloudSync` (後述) と全く同じ `cloudSyncSettings.isEnabled &&
  isCloudSyncPermittedOnThisBuild()` に統一した。macOS も iOS/iPadOS と
  同じ条件で「iCloud でアカウントを同期」トグル1本にぶら下がる。
- 上の節の実装・検証内容自体は削除・訂正しない (このセッションが実際に
  何をどう直したかの記録として残す) — この新しい節が最新の挙動を上書き
  する形。「アカウントのみ同期」節の「検証」項目にある確認手順 (macOS の
  変更が他端末に伝播しないことの確認) は、今回の反転により**もはや
  期待される挙動ではない**ので、実機確認時は無視してよい。

### なぜ反転したか

以前の指示は macOS の操作体系再設計 (ハンバーガーメニュー中心の新画面
構成) の文脈で、「mac は元々ウィンドウが大きく複数アカウントを常時
一覧できるので、iOS 側の細かい表示設定 (スレッド表示・スワイプなど)
を持ち込む必要はない」という当時の判断だった。今回のユーザー要望は
その判断自体を再検討した結果で、「同じ Apple ID なら Mac でも iPhone
でも同じ見た目・同じ操作感であってほしい」を優先する方針に変わった。
両立しない2つの指示が時系列で存在するので、**このドキュメントは両方の
節を残し、どちらが最新かをこの節の位置 (ファイル末尾に近いほど新しい)
と日付で判断できるようにする**。

## Task #186: 設定全般の同期範囲の棚卸しと拡張

### 棚卸し (ローカルに永続化されている設定・状態の全件)

`apps/Otegami/Sources/Support/*SettingsStore.swift` の全ストア (App
Group にミラーする `NotificationContentSettingsStore` を含む)、
`packages/OtegamiKit/Sources/OtegamiStore/Records/` の signature/mail
template テーブル、`CloudSyncSettingsStore.isEnabled` 自身、Keychain
(資格情報)、GRDB のメール本体キャッシュを対象に洗い出した結果:

| 項目 | ストア/テーブル | 同期 | 根拠 |
|---|---|---|---|
| スレッド表示・未読/フラグ付きのみ表示・アカウントでグループ化 | `ListDisplaySettingsStore` | 既に同期 (#89) | 表示の好み |
| ビューア背景固定・ダーク反転 | `HTMLDisplaySettingsStore` | 既に同期 (#89) | 同上 |
| 画像自動表示 (埋め込み/リモート) | `ImageSettingsStore` | 既に同期 (#89) | 同上 |
| アバターソース4種 | `AvatarSourceSettingsStore` | 既に同期 (#89) | 同上 |
| 翻訳自動実行・要約表示 | `TranslationSettingsStore` | 既に同期 (#89) | 同上 |
| AI機能マスタースイッチ | `AIFeaturesSettingsStore` | 既に同期 (#89) | 同上 |
| ツールバー表示/非表示・並び順 | `MessageToolbarSettingsStore` | 既に同期 (#89/#100/#113) | 同上 |
| フォルダのカテゴリ並び順 | `FolderCategoryOrderStore` | 既に同期 (#89) | 同上 |
| スワイプ割り当て4スロット | `SwipeActionSettingsStore` | 既に同期 (#89) | 同上 |
| 通知の表示内容 (差出人/件名/本文プレビュー、Task #176) | `NotificationContentSettingsStore` | 既に同期 (#89フォローアップ) | コンテンツのプライバシー選好であり端末固有の秘密ではない |
| **メール内リンクを開くブラウザ** | `LinkBrowserSettingsStore` | **今回追加** | 表示の好みと同種、iOS専用は表示条件の話でありUserDefaultsの値自体を切り分ける理由にならない |
| **削除・アーカイブ後の挙動 (一覧に戻る/次のメールを開く)** | `MessagePostActionSettingsStore` | **今回追加** | 同上 |
| **送信取り消しの猶予秒数** | `SendCancelSettingsStore` | **今回追加 (Int→文字列変換が必要、後述)** | 同上 |
| **デフォルトのアカウント (新規作成時に選択される accountId)** | `DefaultAccountSettingsStore` | **今回追加** | 古い/存在しない id でも `ComposerView.prepare()` が先頭アカウントへフォールバックするため無害 |
| **署名テンプレート本体 (名前・本文・対象アカウント)** | `SignatureTemplateRecord` (GRDB) | **今回追加 (新エンジン)** | ユーザー作成コンテンツ、資格情報でもキャッシュでもない |
| **作成テンプレート本体 (C8, 名前・件名・本文・対象アカウント)** | `MailTemplateRecord` (GRDB) | **今回追加 (新エンジン)** | 同上 |
| **アカウントごとの最後に選んだ署名** | `LastSignatureSettingsStore` (アカウントIDごとの動的キー) | **今回追加 (settings.v2 の動的キー機構)** | UXの継続性のための小さな好み。迷ったら同期に倒す方針どおり |
| account のメタデータ全般 | `AccountRecord`/`accounts.v1` | 既に同期 (M11) | このドキュメントの本題 |
| — | — | — | — |
| IMAP/SMTP パスワード・OAuth リフレッシュトークン | Keychain | **同期しない (Keychain 自体が iCloud キーチェーンで別途同期)** | 資格情報。この同期機構の対象外という前提自体が本タスクの前提条件 |
| デバイスの push トークン・per-account watch map・enabled フラグ・`deviceSecret` | `PushSettingsStore` | **同期しない** | 端末固有 (APNs トークンは端末ごとに別物、他端末に持たせても無意味) |
| `registrationSecret`/リレー URL | ビルド時埋め込み設定 (`Config/*.xcconfig`) | **元から対象外** | ユーザーが入力する値自体が存在しない (Task #173) |
| `CloudSyncSettingsStore.isEnabled` (このトグル自身) | `UserDefaults` | **同期しない** | 「この端末が同期に参加するか」自体が端末ごとの選択 |
| ピン留め (`isPinnedLocal`との連動含む) | `PinSettingsStore`/`PinSettingsKeys` | **同期しない** | 一時的な端末ローカルの整理用の印という性質が強い (既存の判断を踏襲) |
| メール本文・添付ファイルのキャッシュ | GRDB `messageBody`/`attachment` 等 | **同期しない** | IMAP から再取得できる、容量が大きい |
| メールボックス一覧・フラグ・スレッド | GRDB `mailbox`/`message`/`thread` | **同期しない** | 同上、各端末が IMAP と直接同期する対象 |
| `icloudSync.*LastSyncedSnapshot`/`lastSyncedSnapshot` 系のブックキーピングキー | `UserDefaults` | **同期しない (定義上不可能)** | 「この端末が最後に同期した時点」という値自体が端末ごとに異なって当然 |
| ウィンドウ位置・サイドバー折り畳み状態 | (該当なし) | — | このコードベースは現在どちらも独自の `UserDefaults` キーを持たない (OS 標準のウィンドウ/シーン復元に委ねている) — 除外すべき対象自体が実在しないことを確認した |

**分類の基本方針**: ユーザー確認済みの「同期しない」バケット (資格情報・
キャッシュ・端末固有状態) に明確に該当するもの以外は同期する側に倒した。
`CloudSyncSettingsStore.isEnabled`/ブックキーピングキーは定義上「この
端末の同期参加状態そのもの」を表すため、これを同期対象に含めると
自己言及的な矛盾になる (同期を切ったことを同期する、という無意味な
操作になる) ので除外が妥当と判断した。

### 実装: 3種類の対象それぞれに異なる同期粒度を採用

1. **既存の固定キー (`AppSettingsCloudDirectory.boolDefaults`/
   `stringDefaults`/新設の`intDefaults`)**: 今回追加した4項目は既存の
   キー1個=設定1個という形にそのまま乗せた。`SendCancelSettingsStore
   .windowKey`だけ`UserDefaults`上の実体が`Int` (`SendCancelWindow
   .rawValue`) で、既存の`stringDefaults`(`UserDefaults.string(forKey:)`
   で読む) には乗せられない — 新設した`intDefaults`辞書で`Int`として
   読み書きしつつ、ワイヤー上は既存の`SettingsCloudValue.string`に
   `String(Int)`として載せる (`AppSettingsCloudDirectory.intDefaults`の
   doc comment に、`.int`ケースを素直に追加しなかった理由 — 未知の
   enum caseがあると`[String: SettingsCloudEntry]`全体のdecodeが失敗する
   ため — を書いた)。
2. **`LastSignatureSettingsStore`の動的キー (`signature.
   lastSelectedId.<accountId>`)**: アカウントIDの数だけキーが増減する
   ため固定辞書に載らない。`AppSettingsCloudDirectory
   .dynamicStringKeyPrefixes`にプレフィックスを登録し、
   `currentValues()`/`apply(_:)`が`UserDefaults`の実キーをプレフィックス
   一致で都度スキャンする方式にした。この機構を安全に使うために
   `SettingsCloudSyncEngine.merge()`に一般化を1つ入れた: 従来は
   `freshLocalValues`(この端末が今持っている値) にしか無いキーだけを
   マージ後のペイロードに残していたため、**この端末が知らない動的キー
   をcloudペイロードが持っていた場合、次にこの端末が何か別の理由で
   pushした瞬間そのキーが黙って消える**という潜在バグがあった (固定
   キーだけの世界では全端末が同じキー集合を常に持つため顕在化しな
   かった)。`merge()`に「`freshLocalValues`に無いcloud側のキーはその
   まま素通しで残す」ループを追加して解消した — 既存の固定キーだけの
   テストには一切影響しない (対象になる差分が元々発生しないため)。
3. **署名/作成テンプレート本体 — 新しい `templates.v1` エンジン**:
   後述。

### 署名・作成テンプレート本体の同期 (`TemplateCloudSyncEngine`)

`account`同期(`AccountCloudSyncEngine`/`accounts.v1`)を**アーキテクチャ
ごと再利用**する形で実装した (新しい仕組みを並立させない、というタスク
の指示どおり): 同じ`UbiquitousStoring`抽象、同じ`isEnabled`注入 (この
端末のトグル + シミュレータ/開発ビルドガード)、同じ`maxPayloadBytes`
サイズガード、同じactor再入防止ロック、同じtombstoneベースの削除伝播。
account同期との違いは識別子だけ:

- `SignatureTemplateRecord`/`MailTemplateRecord`はどちらも`id`が
  端末ローカルの`AUTOINCREMENT`で、`AccountRecord.id`のような作成時に
  生成される安定UUIDを持っていなかった (v24移行の旧コメントが「同期は
  将来課題」と明記して見送っていた理由そのもの)。v37移行で両テーブルに
  `syncId`(UUID文字列、作成時に1回だけ生成、以後不変) を追加し、これを
  `accountId`の代わりの同一性キーとして使う。
- ペイロードは`accounts.v1`と同様1キー1JSONだが、`"templates.v1"`という
  別のKVSキーの下にsignature/mail templateの両方の配列+tombstone配列を
  同居させた (2つ目のKVSキーを増やすより、`didChangeExternally
  Notification`のハンドラをもう1つ増やさずに済む方を選んだ)。
- 突き合わせロジック自体は純粋関数`TemplateReconciler.plan(...)`に
  切り出した (`packages/OtegamiKit/Sources/AccountCloudSync
  /TemplateReconciler.swift`) — actor/GRDB/KVSに一切触れず、signature用
  ・mail template用の両方が同じジェネリック関数を通る。
  `TemplateReconcilerTests`がこの純粋関数だけを対象に、push/pull/
  競合解決/tombstone削除/重複検出の全分岐を検証している
  (「同期ロジックの純粋な部分を切り出してユニットテストを書く」という
  タスクの指示に対応する部分)。`TemplateCloudSyncEngineTests`は
  actorの配線 (フェイクの`LocalTemplateDirectory`/`UbiquitousStoring`
  経由でreconcile/即時push/即時削除を一通り) だけを薄く確認する。

**重複防止**: account同期の「重複挿入バグ」修正 (このドキュメント前半)
と同じ設計を最初から組み込んだ — 2台の端末が同期前に独立して「同じ
署名」(名前とbodyが一致) を作ってしまった場合、`identityKey`
(signatureは`name.lowercased() + body`、mail templateは
`name.lowercased() + subject.lowercased() + body`) で一致を検出し、
2件目は挿入しない (cloud payload側のエントリ自体は消さない — account
同期と同じ「データ喪失回避を優先」判断)。

**即時push**: `SignatureTemplateEditView.save()`/`TemplateEditView
.save()`はGRDBへの書き込み直後に`AppEnvironment.pushSignatureToCloud`/
`.pushMailTemplateToCloud`を呼ぶ (accountの`pushAccountToCloud`と同じ
パターン)。`SignatureTemplatesSettingsView.deleteSignature(_:)`/
`TemplatesSettingsView.deleteTemplate(_:)`も同様に削除直後へ即時
tombstone pushを追加した。

### 競合解決方針 (端末Aと端末Bが同時に設定を変えた場合どうなるか)

このタスクでは**項目の粒度によって解決方針が異なる**。それぞれの理由:

1. **固定キーの表示・操作設定 (`AppSettingsCloudDirectory`の
   boolDefaults/stringDefaults/intDefaults)**: Task #144で導入済みの
   **キーごとの last-writer-wins** (`SettingsCloudSyncEngine.merge()`)。
   端末Aが「送信取り消し」を、端末Bが「削除後の挙動」を同時に変えても
   両方残る (`SettingsCloudEntry`が値ごとに`updatedAt`を持つため)。
   同じキーを両端末が同時に変えた場合のみ、新しい`updatedAt`の方が勝つ
   (どちらの端末で見ても最終的に同じ値に収束する)。
2. **`LastSignatureSettingsStore`の動的キー**: 同じ機構に乗るので同じ
   ルール — アカウントごとに独立したキーなので、端末Aがアカウント1の
   署名選択を、端末Bがアカウント2の署名選択を同時に変えても両方残る。
3. **署名/作成テンプレート本体 (`TemplateCloudSyncEngine`)**: **項目
   (=1つの署名/テンプレート) ごとの last-writer-wins**、account同期と
   全く同じ粒度。端末Aが署名Xを、端末Bが署名Yを同時に編集しても両方の
   変更が残る。**同じ署名Xを両端末が同時に編集した場合のみ**、
   `updatedAt`が新しい方が全体 (name/body/accountIds全フィールド) で
   勝つ — フィールド単位のマージはしない (例: 端末Aが名前だけ、端末Bが
   本文だけ変えても、勝った方の編集全体で負けた方の編集は失われる)。
   これはaccount同期が最初から採用している粒度と同じであり、「項目
   単位のマージはするが、1項目の中のフィールド単位までは踏み込まない」
   という一貫した設計判断。フィールド単位のマージは検出可能な「本当の
   競合」なのか「たまたま同時に別フィールドを触っただけ」なのかをUIで
   説明するのが難しく、素朴な自動マージは意図しない組み合わせを生みうる
   ため見送った。
4. **アカウント削除**: `account`同期は資格情報付きの削除連鎖まで扱う
   ため引き続き独自 (このドキュメント前半)。

まとめると: **「値1個」に対しては値ごとのlast-writer-wins、「レコード
1件」に対してはレコードごとのlast-writer-wins** — 粒度が違うだけで、
どちらも同じ「最後に書いた方が勝つ、ただし単位を可能な限り細かく
保って無関係な変更を巻き込まない」という一貫した思想。

### 検証

- 純粋ロジック: `TemplateReconcilerTests` (push/pull/新→旧・旧→新の
  上書き/同時刻の扱い/tombstoneの即時削除と期限切れ後の掃除/重複検出
  ×2パターン)。
- actor配線: `TemplateCloudSyncEngineTests` (signature/mail template
  両方のreconcile往復・即時push/即時削除・無効化時のno-op)。
- `SettingsCloudSyncEngine.merge()`の一般化自体は既存の
  `SettingsCloudSyncEngineTests`が全件グリーンのまま (新規の差分が
  出るのは動的キーを使うテストのみで、今回は追加していない — 動的
  キー自体の直接テストは`AppSettingsCloudDirectory`がアプリ層のため
  `swift test`から到達できず、次点の`make ios`/`make mac`ビルドグリーン
  と手動レビューで担保)。
- `make test`/`make mac`/`make ios`/`make check-localization`全て緑。
- **実 iCloud を使った2端末間の実地確認はこのセッションでは未実施**
  (`PENDING.md`「Task #186」節に確認手順を追記)。
