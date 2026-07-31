# アーキテクチャ

otegami (offline-first の iOS/macOS メールクライアント) のコードベース
全体の構造と、同期エンジンの設計を扱うリファレンス。UI の情報設計・
デザイントークンは [`docs/design-system.md`](design-system.md)、検証
手順は [`docs/verify.md`](verify.md)、翻訳機能は
[`docs/translation.md`](translation.md)、アカウントの iCloud 同期は
[`docs/icloud-sync.md`](icloud-sync.md)、push リレーのデプロイは
[`docs/relay-deployment.md`](relay-deployment.md) を参照。

このドキュメントは「今どう動いているか」だけを記述する。特定のバグ調査の
経緯・コミット・日付は記録しない — そうした記録は git の履歴に残っている。

## モノレポ構成

```
apps/Otegami/          SwiftUI アプリ本体 (iOS/macOS)
packages/OtegamiKit/   同期・データモデル・翻訳などの共有ロジック (SwiftPM)
server/otegami-relay-go/  push リレー (Go、現行の本番実装)
server/otegami-relay/     push リレー (Swift、ワイヤ/ストレージ互換の参照実装)
dev/mailstack/          開発用 Dovecot + Mailpit スタック
scripts/                 ビルド・検証・OTA配信スクリプト
```

### `apps/Otegami/`

SwiftUI アプリターゲット本体。画面 (`Sources/Features/`)・デザイン
システムのコンポーネント実装 (`Sources/DesignSystem/`)・アプリ全体の
環境オブジェクト (`AppEnvironment.swift`)・エントリポイント
(`OtegamiApp.swift`) を持つ。iOS/macOS 共通の SwiftUI コードベースで、
`#if os(macOS)` によるプラットフォーム分岐は画面単位ではなく個々の
モディファイア・コンポーネント単位に留めている。プッシュ通知の
`NotificationService` Extension もこの下 (`NotificationService/`)。
`OtegamiKit` に依存するが、依存の向きは常に一方向 — `OtegamiKit` が
`apps/Otegami` の型を知ることはない。

### `packages/OtegamiKit/`

同期エンジン・ローカルストア・認証・翻訳など、UI を持たないロジック全体を
まとめた SwiftPM パッケージ。詳細は次節「パッケージ依存関係」。

### `server/otegami-relay-go/` と `server/otegami-relay/`

otegami の push 通知は、セルフホストする「push リレー」が対象アカウントの
IMAP を監視 (IDLE、または非対応サーバーへの polling) し、新着を検知すると
APNs 経由でデバイスへ通知を送る構成で動く (OSS ビルドで Apple Developer
アカウント/APNs 認証情報を配布できないため、ビルド元が自分でこのサーバー
を運用する前提)。

同じ HTTP API・同じ SQLite スキーマ・同じ暗号化・同じ環境変数で **ワイヤ/
ストレージ完全互換**の実装が2つある:

- **`server/otegami-relay-go/`** — Go 実装。arm64 Docker イメージのビルド
  を QEMU なしで完結させる目的で作られた移植版で、現在の本番デプロイは
  こちら。commit の更新頻度もこちらが高い。
- **`server/otegami-relay/`** — Swift 実装。互換な参照実装として残して
  ある。

新規の機能追加・バグ修正は基本的に `otegami-relay-go` 側に入る。両者の
デプロイ手順・環境変数は [`docs/relay-deployment.md`](relay-deployment.md)
参照。

### `dev/mailstack/`

Docker Compose で Dovecot (IMAP/SMTP) + Mailpit (SMTP 受信・Web UI) を
立ち上げる開発用スタック (`compose.yml`)。フィクスチャメール
(`seed/fixtures/*.eml`) を投入した状態で起動でき、実サーバーが要る統合
テスト (`OTEGAMI_TEST_IMAP_HOST=localhost swift test ...`) や
`scripts/verify-*.sh` の実機シミュレータ検証はこのスタックに対して行う。

### `scripts/`

ビルド (`build-mailcore2.sh`)・OTA 配信 (`deploy-ota.sh`)・ローカライズ
カバレッジ確認 (`check-localizable-coverage.py`)、そして
`verify-*.sh` 群 (機能ごとのシミュレータ実機検証スクリプト、
`.claude/skills/verify/SKILL.md` から呼ばれる) を置く。

## パッケージ依存関係 (`packages/OtegamiKit`)

`packages/OtegamiKit/Package.swift` が正 (このセクションはそこから機械的
に導出したもの)。全体の依存の向きは:

```
OtegamiCore  (Linux 互換・純ロジック、依存なし)
    ↑
MailTransport (IMAP/SMTP のプロトコル抽象、Linux 互換)
    ↑
MailTransportMailCore (MailCore2 実装、Apple 専用)

OtegamiCore
    ↑
OtegamiStore (GRDB ローカルストア)
    ↑
SyncEngine (OtegamiCore + MailTransport + OtegamiStore + OtegamiTranslation)
    ↑
apps/Otegami
```

モジュールごとの役割:

- **`OtegamiCore`** — Linux 互換の純ロジック層。他モジュールに一切依存
  しない。スレッディングの決定ロジック (`Threader`/`BatchThreader`)、
  MailCore2 の日付/Message-ID 自己修復判定 (`EnvelopeDateSentinel`)、
  添付ファイル名サニタイズ、HTML→プレーンテキスト抽出、URL スキーム
  検証など、DB・ネットワークを持たない判定ロジックがここに集まる。
- **`MailTransport`** — IMAP/SMTP トランスポートのプロトコルのみの抽象層
  (`IMAPSessionProtocol` など)。Linux 互換。具体的な実装 (MailCore2) は
  この背後に隠れる。
- **`MailTransportMailCore`** — `MailTransport` の MailCore2 (readdle
  fork、リビジョン pin) バックエンド実装。Apple 専用— MailCore2 自体と
  その C/C++ 依存は、このターゲットを経由するときだけビルドに入る。
- **`OtegamiStore`** — GRDB (SQLite) ベースのローカルストア。スキーマ・
  DAO・FTS インデクサ・スレッド割当の DB 適用層 (`ThreadAssigner`) を持つ。
- **`SyncEngine`** — 同期のオーケストレーション本体
  (`AccountSyncer`/`MailboxSyncer`/`OpQueueProcessor`/`SyncCoordinator`
  ほか)。次節で詳述。
- **`OtegamiRelayAPI`** — アプリと push リレー間で共有する DTO。Linux
  互換。
- **`PushRelayClient`** — push リレーの HTTP API クライアント (`OtegamiRelayAPI`
  + `OtegamiCore` に依存)。Apple 専用。
- **`GoogleOAuth`/`MicrosoftOAuth`** — それぞれ Gmail / Outlook.com・
  Office 365 向けの OAuth2 (Authorization Code + PKCE) クライアント +
  トークンストア。互いに独立 (共有コードなし、意図的な設計)。パッケージ
  内の他ターゲットに一切依存しない。
- **`AccountCloudSync`** — アカウント定義 (メールアドレス・表示名などの
  メタデータ) の iCloud (`NSUbiquitousKeyValueStore`) 同期。資格情報自体
  は iCloud Keychain が別途同期する。`OtegamiStore` にのみ依存。
- **`OtegamiTranslation`** — オンデバイス翻訳のプロトコル抽象
  (`TranslationService`) と言語検出 (`MessageLanguageDetector`、
  `NaturalLanguage`)。Linux 互換 (Apple 専用部分はファイル単位で
  `#if canImport` ガード)。
- **`OtegamiTranslationFoundationModels`** — Apple Foundation Models
  (iOS/macOS 26+) を使う実翻訳/要約エンジン。Apple 専用。
- **`OtegamiTranslationApple`** — `Translation.TranslationSession`
  (Apple 翻訳フレームワーク) を使う専用 NMT エンジン。Apple 専用。
- **`TranslationEngine`** — 翻訳結果のキャッシュ・永続化オーケストレーション
  (`MessageTranslator`)。`OtegamiStore` + `OtegamiTranslation` に依存。
- **`BIMI`** — 送信者ロゴ (BIMI, DNS-over-HTTPS レコード取得 + 安全な
  サブセットの SVG パース/検証)。Linux 互換 (実際のラスタライズは
  `apps/Otegami` 側の `CoreGraphics` コード)。

## 同期エンジンの設計

### エンドツーエンドの流れ

1. **`SyncCoordinator`** がアプリ全体のエントリポイントで、アカウントごと
   に1つの `AccountSyncer` を保持・再利用する。
2. **`AccountSyncer`** が1アカウント分の同期を駆動する。自分自身は長命の
   IMAP 接続を持たず、同期パスのたびに接続を開き・使い・閉じる。初回同期
   (全メールボックス一覧 + 選択可能な全メールボックスの初期取り込み) と、
   差分同期 (`performIncrementalSync`) の両方をここが呼び分ける。
3. **`MailboxSyncer`** が1メールボックス分の差分同期を担当する: 新着
   (`maxUID+1 ... uidNext`)・フラグ変化 (`CONDSTORE` があればそれを、
   無ければ同期済みウィンドウの再フェッチ+diff)・消滅検出、を行う。
4. **`BodyFetcher`**/**`AttachmentFetcher`** が本文・添付を遅延取得する
   (一覧に出た直後に prefetch、または開いたときにオンデマンド)。
5. 取得した内容はすべて **ローカル SQLite (GRDB)** へ書き込まれてから
   画面に反映される — アプリの画面は GRDB の `ValueObservation` 経由で
   ローカル DB だけを見ており、IMAP セッションを直接読むことはない。
6. **オフラインファースト**: ユーザー操作 (既読/未読・ピン・アーカイブ・
   削除・送信 など) はすべてまずローカル DB に即座に反映され、同時に
   `OpQueueRecord` として `opQueue` テーブルに追記される。ネットワークが
   無くても操作は失敗しない。
7. **`OpQueueProcessor`** が接続が確認できたタイミング (フォアグラウンド
   復帰・IDLE wake・スワイプ直後の日和見的リプレイなど、15箇所以上の
   呼び出し元がある) で `opQueue` を FIFO に replay し、実際の IMAP/SMTP
   操作をサーバーへ反映する。成功した op は削除され、失敗は種類に応じて
   リトライ (バックオフ) または pending のまま保持される。

### スレッディング戦略

`Threader` (`OtegamiCore`、DB 非依存の純ロジック) が優先順位付きで決定する:

1. **Gmail の `X-GM-THRID`** があれば常にそれを最優先で使う。
2. **References/In-Reply-To/Message-ID** — 既存のスレッドの中の
   メッセージを指していればそのスレッドに参加する (複数のスレッドを
   橋渡しする場合はマージする)。`BatchThreader` の union-find
   (JWZ 方式) がこの解決を行う。
3. **件名フォールバック** — 正規化した件名が一致し、参加者が重なり、
   時間窓に収まる場合。
4. どれにも一致しなければ新規スレッド。

`OtegamiStore.ThreadAssigner` がこの決定を DB へ適用する側 (`assignThread`
/`recomputeAggregates`/一括バックフィル用の `assignAllUnthreaded`) で、
`message` の upsert と同じトランザクション内で必ず呼ばれる — 同期が
途中でクラッシュしても「メッセージは upsert 済みだがスレッド未割当」
「スレッドの集計だけが古い」という状態が残らない設計。

Gmail はメッセージが物理的に1通でも、所属する特別用途フォルダ (INBOX
など) と「すべてのメール」(`role == .all`) の両方に同時に存在する
(二重ラベリング)。このアプリはメールボックスごとに独立して同期するため、
同じ物理メールが `(mailboxId, uid)` の異なる2行の `message` レコードに
なる — 両者は `gmailMessageId` (`X-GM-MSGID`) で同一性が分かる。この
重複は `ThreadQuery.deduplicate(_:db:)` (`OtegamiStore/ThreadQuery.swift`)
が同一性キー (`gmailMessageId` 優先、無ければ `messageId`) + role 優先の
タイブレークで解決してから返す — スレッド詳細のメッセージ一覧・
`ThreadAssigner` の集計 (`messageCount`/`unreadCount`) の両方がこの
dedup ロジックを通る。

### 何をもって「offline-first」とするか

- すべてのミューテーションはまずローカル SQLite に書き込まれる。UI は
  ローカル DB の `ValueObservation` だけを見る (IMAP の応答を直接 UI に
  反映する経路は無い)。
- サーバーへの反映は `opQueue` の replay に一本化されている — 「今すぐ
  送った/変更した」ように見える UI の裏側でも、実際にサーバーへ届くのは
  replay 経由のみ。
- アーカイブ/削除/迷惑メール化/アーカイブ解除は、移動先メールボックスが
  ローカルに既知なら **仮配置 (pending relocation)** — 対象の `message`
  行を削除せず、同じ行 `id` のまま `mailboxId`/`uid` (`uid <= 0` を仮
  UID のセンチネルとする、実 IMAP UID は常に `>= 1` なので衝突しない)
  だけ書き換えて即座に移動先へ表示する。移動先メールボックスの次回同期が
  実エンベロープを取得した時点で `AccountSyncer.reconcilePendingRelocation`
  が仮 UID を実 UID に付け替えて確定する。これにより「サーバーの確認を
  待たずに一覧へ即座に反映される」体験が成立している一方、後述の
  「Known pitfalls」(b) の衝突リスクを伴う。

## データモデル概要 (`OtegamiStore/Records/`)

GRDB の `Record` 型。主なもの:

- **`AccountRecord`** — 1メールアカウント (IMAP/SMTP ホスト、認証方式、
  Gmail/Outlook/iCloud/汎用 IMAP の種別)。
- **`MailboxRecord`** — 1メールボックス。`role` (inbox/archive/trash/
  junk/sent/drafts/all/none) と、その role が SPECIAL-USE 由来か名前
  推測フォールバック由来かを示す `roleIsAuthoritative` を持つ。
- **`MessageRecord`** — 1メッセージ。`(mailboxId, uid)` に一意制約。
  `date`/`internalDate`、フラグ、Gmail のスレッド/メッセージ ID、
  `threadId` (スレッド割当)、`bodyState` (遅延本文取得のどの段階か) を持つ。
- **`MessageReferenceRecord`** — `References` ヘッダの各トークン。
  `Threader` の JWZ 方式 union-find パスが使う。
- **`ThreadRecord`** — 1スレッド。`messageCount`/`unreadCount`/
  `lastMessageDate`/`isPinned` は `ThreadAssigner` が書き込む集計列
  (トリガーではなくアプリロジック側で維持)。
- **`MessageBodyRecord`** — 本文 (plain/HTML)、遅延取得で埋まる。
- **`AttachmentRecord`** — 受信メッセージの添付/インライン画像。
  `localPath == nil` は未ダウンロードを意味する。
- **`OpQueueRecord`** — オフライン操作のキュー。`payload` は種別ごとの
  JSON blob。
- **`OutboxMessageRecord`**/**`OutboxAttachmentRecord`** — 送信待ちの
  メッセージとその添付 (`opQueue` の不透明な payload とは別に、UI が
  「送信待ち」一覧を出すための人間可読な行)。
- **`DraftMessageRecord`**/**`DraftAttachmentRecord`** — ユーザーが明示的
  に保存した下書き (送信待ちとは別テーブル)。
- **`MessageTranslationRecord`** — 翻訳結果を段落単位でキャッシュ。
- **`SavedSearchRecord`**/**`SearchHistoryRecord`** — 保存済み検索/検索
  履歴。
- **`SignatureTemplateRecord`**/**`MailTemplateRecord`** — 署名/定型文
  テンプレート。
- **`CalendarInviteResponseRecord`** — カレンダー招待 (ICS/iTIP) への
  この端末からの最終応答。

## Known pitfalls

このリポジトリの同期エンジン/ストレージ層を触る前に必ず知っておくべき、
今も有効な設計上の制約・落とし穴。過去のバグ報告の記録ではなく、現在の
コードが前提にしている事実として書く。

### a. MailCore2 は壊れた Date/Message-ID を「自己修復」してしまう

このリポジトリが pin している MailCore2 (readdle fork、
`packages/OtegamiKit/Package.swift` の `revision:` 参照) は、`Date:`
ヘッダのパースに失敗すると `MessageHeader` のデフォルトコンストラクタが
**フェッチ時点の現在時刻**で `date` を無条件に埋める (`MCMessageHeader.cpp`
の `MessageHeader::MessageHeader()` が `init(true, true)` を呼び、
`mDate = time(NULL)` を ENVELOPE パース**前**にセットする — `env_date`
が実際にパースできた場合だけ後から上書きされる)。`Message-ID` の欠落に
対しても同様に、ランダムな UUID ベースの ID を自動生成する。

これは「今取得した」という体裁にしか見えないため、検出しないと **再同期
のたびにデータが壊れ続ける** — 特に非 CONDSTORE の再フェッチ経路は
同期済みウィンドウを毎回丸ごと取り直すため、日付が化けた古いメッセージが
`Threader` の件名フォールバックで無関係な新しいスレッドに紛れ込む
実害がある。

検出/回避のロジックは `packages/OtegamiKit/Sources/OtegamiCore/
EnvelopeDateSentinel.swift` (doc comment に MailCore2 側の該当ソースの
挙動を正確に引用してある) と、それを呼ぶ
`packages/OtegamiKit/Sources/MailTransportMailCore/
MailCoreIMAPSession+Mapping.swift` の `envelope(from:fetchedAt:)`:

- `date` は「`referenceTime`(フェッチ時刻) に近い」かつ「`internalDate`
  (IMAP `INTERNALDATE`、サーバー側で配送時に確定し MailCore2 が
  無条件に上書きする値) と食い違う」の両方を満たすときだけ疑わしいと
  判定し、`nil` に落とす (呼び出し側は既存の `date ?? internalDate`
  という慣用パターンにそのままフォールバックできる)。
- `Message-ID` は MailCore2 自身が `header.isMessageIDAutoGenerated`
  という直接の判定 API を持つため、ヒューリスティックなしで `nil` に
  落とせる。

同じパターンで新しいフィールドを MailCore2 から取り込むときは、「値が
常に非 nil で返る (欠落を表現できない)」型かどうかを疑うこと。

### b. `(mailboxId, uid)` は一意制約があるが、素朴な書き込みは違反しうる

`message` テーブルは `(mailboxId, uid)` に DB レベルの一意制約を持つ
(`AppDatabase.swift` の `t.uniqueKey(["mailboxId", "uid"])`)。通常の
upsert (`AccountSyncer.upsert(envelope:mailboxId:accountId:db:)`) は
`onConflict: ["mailboxId", "uid"]` で正しく更新に倒れるが、**それ以外の
経路でこのスロットへ書き込む場合は、既に埋まっていないかを明示的に
確認する必要がある**。

具体例: アーカイブ/削除などは「仮配置 (pending relocation、上述)」で
`message` 行の `mailboxId`/`uid` を書き換えるが、書き込み先の
`(mailboxId, 実UID)` に**既に本物の行が存在する**ケース (この端末の
別経路の初回同期が先に取り込んでいた、など) を無条件に想定していない
書き換えは一意制約違反で失敗し、しかも自然回復しない (次の同期でも
同じ書き換えを試みて同じ場所で毎回失敗し続ける)。

現在の衝突解決は `packages/OtegamiKit/Sources/SyncEngine/
MessageRelocationConflict.swift` に集約されている。書き込み先に既に別の
行がいる場合は「生き残る側 (survivor) はその既存行、移動しようとした側
(mover) のローカル専用状態 (ピン・フラグ) だけを survivor へマージして
mover を破棄する」というポリシーで解決する (`OtegamiStore/
AccountDuplicateMerger.swift` の `mergeCollidingMailbox` が確立した、
「同じ物理メッセージを表す2行」問題への既存ポリシーと同じ思想)。
`AccountSyncer.reconcilePendingRelocation`(`AccountSyncer.swift`) と
`MessageRemoval.undo`(`MessageRemoval.swift`) の両方がこのポリシーを
経由する。

`(mailboxId, uid)` を書き換える新しいコードパスを追加するときは、
書き込み先が既に占有されていないかを必ず確認し、占有されていた場合の
挙動 (マージ/拒否) を明示的に決めること — 「とりあえず上書きを試みて
DB のエラーに任せる」は、一度衝突すると自然回復しない同期失敗ループを
生む。

### c. IDLE 非対応の IMAP サーバーには NOOP キープアライブが必須

IDLE 非対応サーバー (Yahoo! JAPAN など) 向けの polling 経路で、
「`PollInterval` を丸ごとスリープしてから `STATUS` を叩く」実装 (接続は
張ったまま何も送らずに待つだけ) は、その無通信区間の途中でサーバー側が
接続をタイムアウトさせて切ってしまう。切断は「接続エラー」として扱われ
再接続 = **再 LOGIN** になるため、この実装では polling 対象のサーバーに
対して**毎回のポーリング周期ごとに LOGIN が走ってしまう** (実測: Yahoo!
JAPAN で 5 分間隔、1 watch あたり約 288 回/日)。同じ IP から高頻度に
LOGIN を繰り返すこと自体がプロバイダ側の不正利用保護 (一時ロック) を
誘発し、正しい資格情報のまま断続的に認証エラーになる — というのが実際に
本番で観測された挙動だった。

現在の実装は `server/otegami-relay-go/internal/watcher/pool.go` の
`pollWait` — `PollInterval` を待つ間、`PollKeepAliveInterval` ごとに
IMAP `NOOP` を送りながら小刻みにスリープする。この間隔は最初サード
パーティの報告 (Yahoo IMAP は約5分でアイドル接続を切る、という報告)
を根拠に2分に設定したが、**本番の実測がそれを覆した** — 2分間隔の
NOOP でも「00:35:15 LOGIN 成功 → 00:37:15 接続が既に切れている」が
ちょうど2分の境界で再現し、実際のタイムアウトは2分よりずっと短い
ことが分かった (しかも2分間隔は「5分ごとのLOGIN」を「2分ごとの
LOGIN」に悪化させていた)。現在のデフォルトは、その実測に基づく
**45秒**。**「サードパーティの報告値」より「自分の本番ログでの実測値」
を優先すること** — この手のタイムアウトはプロバイダ固有かつ非公開で
あることが多く、他社製クライアントの報告を鵜呑みにした初期値が本番の
実測で覆ることがある。IDLE 対応サーバー (iCloud/Gmail/Outlook) は
この分岐を通らず、`Idle()` でブロックして `IdleMaxWait`(29分、RFC 2177
の推奨再発行間隔) で自律的に再発行する既存の経路のまま。

**IDLE 非対応のサーバーに対して polling を実装するときは、必ずこの
NOOP キープアライブのパターンに従うこと** — 素朴な「スリープしてから
コマンドを打つ」実装は、接続が長時間持たないサーバーに対して隠れた
高頻度 LOGIN を生み、アカウントロックという形でユーザーに実害が出る。

**追記 (Task #206): 上記の「接続維持を入れれば解決」は不完全だった。**
接続の寿命 (切断→再LOGIN) の問題はこれで解けたが、**コマンドの総量**
という別の問題が残っていた — 45秒ごとの NOOP (80回/時) + 5分ごとの
STATUS (12回/時) を同一アカウントに watch 2本 (デバイス2台) 分実行する
と約184回/時になり、これ自体が Yahoo! JAPAN 側のコマンドレート制限を
誘発した。詳細は下記 i. 参照。

### d. open-ended な UID range は自動でチャンク化されない

`MailCoreIMAPSession+Mapping.chunk(_:size:)`
(`packages/OtegamiKit/Sources/MailTransportMailCore/
MailCoreIMAPSession+Mapping.swift`) の doc comment が明示している通り:
上限を指定しない `UIDRange` (`upperBound == nil`、IMAP の
`lowerBound:*`) は**そのままチャンク化されずに1本の `FETCH` として
発行される** — クライアント側はメールボックスの実際の最大 UID を追加の
往復無しには知らないため、上限の無い範囲を安全に分割する術がないという
設計上の理由による。`batchSize` を渡していても、range が open-ended な
限りそれは無視される。

この状態で大きなメールボックスに対して呼ぶと、1本の巨大な `FETCH` が
完了するまで何もデータが返らない (進捗を出しようがない) 上、
`Task.checkCancellation()` を挟むチェックポイントも無いため途中で
止める手段が無い — 実際に「pull-to-refresh が長すぎて終わらない」と
いう形で顕在化した。

**新しく UID range を渡す呼び出しを書くときは、必ず呼び出し側で
`status.uidNext` などサーバーから得た実際の上限で range を有界化して
から渡すこと** (`MailboxSyncer.refetchAndDiffFlags` の
`serverUpperBound`/`chunkRange` がこのパターンの実例)。有界化した後は
`AccountSyncer.fetchBatchSize` 単位でチャンクし、チャンクの境目ごとに
`Task.checkCancellation()` を挟む。

同じ理由で、サーバー制御の大きな整数 (`HIGHESTMODSEQ` など) を `Int64`/
`UInt32` へ変換する箇所は `Int64(clamping:)` のようなトラップしない
変換を使うこと — 素朴な `Int64(_:)`/`UInt32(_:)` は境界値でクラッシュ
する。同様に、`VANISHED`/`UID SEARCH` の結果セットを実体化するときは
上限件数を設け、上限を超えたら「不明」(呼び出し側が安全なフォール
バック経路 — 例えば `detectAndRemoveVanishedByUIDSearch`
— に倒れる `nil`) を返すこと。**「サーバーが返した集合が空だった」と
「安全に確認できなかった」を絶対に同じ意味として扱わないこと** — 前者
だけがローカルのメッセージ削除を許可してよい条件で、後者は「何もしない」
が唯一の安全な選択肢 (空集合を「全消滅」と誤解すると、メールボックスの
同期済みウィンドウを丸ごと削除しかねない)。

### e. 共有コンテナ DB のロック保持中のバックグラウンド強制終了 (`0xDEAD10CC`)

アプリの DB (`AppDatabase.makeShared`) は App Group の共有コンテナに
置かれている (`NotificationService` Extension と同じ SQLite ファイルを
共有するため)。iOS は、共有コンテナ内のファイル/SQLite のロックを
握ったままバックグラウンドで強制停止されたプロセスを `0xDEAD10CC`
(`RUNNINGBOARD`, `SIGKILL`) で問答無用に終了させる。

対策は GRDB の中断通知の仕組み (`Configuration
.observesSuspensionNotifications`、App Group の共有コンテナへ実際に
解決できたときだけ iOS 限定で有効化— macOS は App Group を持たないため
自動的に対象外) を使う:

- `packages/OtegamiKit/Sources/OtegamiStore/DatabaseSuspension.swift` の
  `DatabaseSuspensionSupport.isSuspensionError(_:)` — GRDB が中断中の
  新規ロック取得を `SQLITE_INTERRUPT`/`SQLITE_ABORT` で失敗させたことを
  判定するヘルパー (GRDB 自身の `DatabaseError.isInterruptionError` の
  薄いラップ)。
- `DatabaseSuspensionTracker` — `.background`/`.inactive` の両方を
  suspend として扱うシーンフェーズ遷移から、二重 post を防ぐための
  dedup 状態機械。
- `AccountSyncer.classify(_:)` と `OpQueueProcessor.replay(account:
  auth:)` は、このエラーを**通常の同期失敗とは明確に分離**して扱う —
  リトライしない・`lastSyncError`/`opQueue.lastError` にも記録しない
  (中断は「本当の失敗」ではなく、フォアグラウンド復帰時に自然に再同期
  されるため、リトライも永続化されたエラー文言もユーザーを混乱させる
  だけ)。

**DB 書き込みを伴う新しいコードパスを `SyncEngine`/`OpQueueProcessor`
に追加するときは、そのエラーハンドリングが `DatabaseSuspensionSupport
.isSuspensionError(_:)` を通常のサーバーエラーと同列に扱っていないか
確認すること** — 中断エラーをそのまま「同期失敗」として記録・リトライ
すると、バックグラウンド遷移のたびに無意味なリトライやユーザー向けの
エラー表示が発生する。

なお `DatabaseQueue.init(named:configuration:)` (インメモリ DB 用の
イニシャライザ、`AppDatabase.makeInMemory()` が使う) は中断監視の
セットアップを一切行わない — `init(path:configuration:)` (ファイル
バックエンド) だけがこれを行う。中断挙動をユニットテストで確認する
場合は、一時ファイルバックエンドの `DatabaseQueue` を使うこと。

### f. `OpQueueProcessor.replay` はアカウント単位の直列化と DB 側の冪等ガードの両方が要る

`replay(account:auth:)` はアプリのほぼ全ての操作 (スワイプ、フォア
グラウンド復帰、IDLE wake、送信カウントダウン満了など) から日和見的に
呼ばれる。`OpQueueProcessor` 自体は `actor` だが、`replay` 本体は
`await` を複数回挟む (IMAP 接続、各 op の適用、DB 読み書き) ため、
actor の reentrancy により同じアカウントに対する2回目の `replay` 呼び
出しが1回目の `await` の隙間に割り込める。「まだ処理していない
`opQueue` 行を読む→適用→成功したら削除」という素朴な手順だけでは、
2つの `replay` 呼び出しが同じ `.send` op を両方とも「まだ削除されて
いない」状態で読み、**両方が実際に SMTP 送信してしまう**二重送信が
起こりうる。

現在の防御は二段構え:

1. **in-process の直列化**: `OpQueueProcessor` が `inFlightAccountIds:
   Set<String>` を持ち、同じアカウントの `replay` が既に進行中なら
   即座に no-op で返す。
2. **DB 永続の冪等ガード**: `outboxMessage.sendStartedAt` を SMTP 送信
   **直前**に `NULL → 現在時刻` へ CAS 的に更新するトランザクションで
   クレームを取得し、失敗したら (既に他の試行がクレーム済み) 送信を
   スキップする — プロセスクラッシュで前回の試行がクレームを残したまま
   終わった場合の再送を防ぐ、1の背後の第二防衛線。

`OpQueueProcessor` に新しい日和見的呼び出し元を追加するときや、
副作用が一度きりであるべき新しい op kind を追加するときは、この
「in-process 直列化 + DB 側の冪等クレーム」の両方が必要かどうかを
検討すること — in-process のガードだけでは、アプリがクラッシュして
別プロセスとして再起動した場合の二重実行を防げない。

### g. iCloud KVS への read-modify-write は actor でも競合する

`AccountCloudSync` の `AccountCloudSyncEngine`(アカウント定義の iCloud
同期) は `reconcile()`/`pushLocalChange`/`pushLocalDeletion` いずれも
「iCloud KVS のペイロードを読む→加工する→書き戻す」という
read-modify-write を行う。`reconcile()` は古い payload を読んだ**あと**
に GRDB アクセスを挟む本物のサスペンションポイントを持つため、普通の
`actor` であっても、その中断中に同じ actor 宛ての別の呼び出しが完全に
実行を終えてしまえる (actor reentrancy)。素朴な実装では、割り込んだ側の
書き込みが `reconcile()` の「古い payload を元にした上書き」で消える
(lost update) — 同じ Apple ID の別デバイスからの通知経由の `reconcile()`
と、ユーザーが立て続けに2つ目のアカウントを追加する操作が競合すれば、
本番でも起こりうる。

対策は `AccountCloudSyncEngine` 内で自前実装した非同期 mutex
(`acquirePayloadLock()`/`releasePayloadLock()`、`CheckedContinuation`
ベースの FIFO キュー) で read-modify-write 区間全体を直列化すること。
`actor` であることは「複数の呼び出しが同時に走らない」ことしか保証
しない — **`await` を挟む read-modify-write を1つの actor メソッド内で
行うときは、途中に別の呼び出しが完全に割り込んで状態を書き換え得る
ことを常に疑うこと**。同種の read-modify-write を新しく書くときは、
明示的な mutex かトランザクションで直列化するか、そもそも
read-modify-write の形を避けられないか検討する。

### h. `ASWebAuthenticationSession` の completion handler はメインスレッド保証がない

`GoogleOAuth`/`MicrosoftOAuth` の `ASWebAuthenticationSessionRunner` が
使う `ASWebAuthenticationSession` の completion handler は、**メイン
スレッドで呼ばれる保証がない**。macOS では `SafariLaunchAgent` の XPC
応答キュー上で同期的に呼ばれることが実機で確認されている (iOS では
主にメインスレッドで配送されるため、この不整合は macOS 対応まで露出
していなかった)。

`@MainActor` なメソッドの内部に、明示的な `@Sendable`/隔離注釈なしで
completion handler クロージャを書くと、Swift 6 のクロージャ隔離推論
(SE-0420) がそのクロージャを「囲むメソッドと同じ `@MainActor` 隔離」と
推論し、**クロージャの入り口に動的な隔離チェックを挿入する**。実際に
メインスレッド外から呼ばれると、クロージャ本体に触れる前の入り口の
時点でトラップする — クロージャ本体の特定の行 (`@MainActor` 状態への
書き込みなど) だけを `Task { @MainActor in ... }` でホップさせても、
入り口のチェック自体は残ったままなので直らない。

対策は completion handler クロージャ自体を明示的に `@Sendable` 化する
こと (`packages/OtegamiKit/Sources/GoogleOAuth/
ASWebAuthenticationSessionRunner.swift` とそのミラーコピーである
`MicrosoftOAuth` 版を参照) — コンパイラに「本当にどのスレッドから
呼ばれても構わない」と伝えることで、入り口の動的隔離チェック自体が
挿入されなくなる。その上で、実際に `@MainActor` 隔離状態へ書き込む
箇所だけを `Task { @MainActor in ... }` で明示的にホップする
(`MainActor.assumeIsolated` は使わない — 実際に非メインスレッドから
呼ばれうるため、使うと同じ誤った前提を別の場所で繰り返すだけになる)。

**Objective-C 由来の「どのスレッドから呼ばれるか分からない」コールバック
型 (`@escaping (...) -> Void` で actor 注釈の無いもの) を `@MainActor`
なメソッドの内部に書くときは、常にこの推論のトラップを疑うこと** — 特に
macOS/iOS でスレッド配送の実際の挙動が異なる API (ネイティブ
Authentication/Web 系の completion handler など) は要注意。

### i. IMAP の `[LIMIT]` 応答は接続エラーではない — 再接続すると別の障害を誘発する

Task #201 で watch 接続の寿命を 2分 → 1時間に伸ばした後、本番ログに
新しいパターンが出た:

```
03:10:18  WARN watch connection error, reconnecting
          error="IMAP command A87 failed: A87 NO [LIMIT] STATUS Rate limit hit."
03:10:23  WARN watch authentication failed
          serverResponse="A1 NO [AUTHENTICATIONFAILED] Incorrect username or password."
03:40:26  WARN watch authentication failed (attempt=2)
```

Yahoo! JAPAN (imap.mail.yahoo.co.jp) が `STATUS` コマンドに対して明示的に
`[LIMIT]` 応答コードを返した — これは**コマンドのレート制限**であり、
接続自体は生きたまま (TCP/TLS も認証も無事) で、拒否されたのはこの1コマ
ンドだけ。ところが Task #206 以前の実装はこれを他のあらゆる IMAP コマ
ンド失敗と同じ「接続エラー」として扱い、`runWatchLoop` が接続を閉じて
再接続 = **再 LOGIN** した。その再 LOGIN が Task #187 の認証ロック
(`AUTHENTICATIONFAILED`) を誘発し、悪循環になっていた:

```
レート制限 (STATUS) → 接続エラー扱いで再接続 → 再LOGIN
  → LOGIN 拒否 (アカウントロック) → 30分+ 待つ → 成功
  → 元と同じコマンド量 → 再びレート制限 → …
```

**対策 (`server/otegami-relay-go/internal/watcher/pool.go`):**
`connectAndWatch` の `STATUS` 呼び出しで `isRateLimited(err)`
(`CommandFailedError.Response` に `[LIMIT]` を含むかで判定) が真なら、
接続を閉じずに**同じ接続のまま** `Options.RateLimitInitialWait`
(デフォルトは `Options.PollInterval` = 5分。連続ヒットで倍々、
`RateLimitWaitCap` = 30分で頭打ち) だけ待ってから `STATUS` をリトライ
する。`RecordWatchError` で `lastErrorKind=connectionError` として
表示用には記録するが `stopping=false` — ステータスは `active` のまま。

**待ち時間を `PollInterval` 自身から導出した理由**:
このレート制限からの回復時間について公開された数値は存在しない
(Task #187 の認証ロックとは違い、Yahoo のサポート文書はコマンドレート
制限の解除時間を明言していない)。本番ログから分かっている唯一の事実
は「5分に1回の STATUS 頻度で制限に達した」ことだけなので、それより
明らかに短い間隔で即座にリトライすることを正当化する根拠がない。
**新しい数値を当て推量するのではなく、既に制限を誘発した頻度そのもの
(`PollInterval`) を初期待機時間として再利用する**のが、実測に基づかな
い決め打ちを避けつつ最も保守的な選択。上限の30分は、このファイル内で
既に「一時的なブロック、期間不明」というまったく同じ状況に使っている
`defaultAuthFailureRetryInterval`/`defaultAuthFailureRetryCap` の前例
(30分/1時間) に合わせた。

**コマンド総量そのものを減らす施策 (NOOP間隔・STATUS間隔のデフォルト
短縮) は Task #206 では見送った。** NOOP の45秒はすでに Task #201 の
実測 (2分間隔だと接続がその境界で切れる) に基づく下限値であり、これを
広げる方向の変更は新たな実測なしには「決め打ち」になってしまう。
上記の適応的バックオフ (`[LIMIT]` を受けた watch だけ、実際に必要な
分だけ間隔が伸びる) の方が、全 watch のデフォルト間隔を当て推量で
変更するより安全で、かつ Task の要求 (「`[LIMIT]` を返したサーバに
対しては自動的に間隔を広げる」) にも直接応える。

**同一アカウントの watch 重複解消 (デバイス2台分 → 1本の監視に統合し
コマンド総量を半減させる) は Task #206 では見送った。** `fire()` が
`WatchRecord.DeviceID` 1対1前提、`CreateWatch`/`DeleteWatch` が
`(id, deviceId)` 単位、アプリ側 `WatchReconciler.swift` が watch を
デバイス所有の資源とみなしている — この3点をまたぐ設計変更かつ、既に
配布済みのアプリとの API 互換性を壊さない移行経路が要る規模のため、
別タスクとして切り出すべきと判断した。

**追記 (Task #208): 上記の統合を実装した。** `server/otegami-relay-go/
internal/store/store.go` の `watch` テーブルを「(imapHost, imapPort,
imapUseTLS, imapUsername, authType, authProvider, mailbox) の接続 identity
1本」を表す行に変更し、`deviceId`/`accountId` は新設した
`watch_subscription` テーブル (`watchId` × `deviceId` に一意制約、各行が
その device 自身の accountId を持つ) に切り出した。`CreateWatch` は
identity が一致する既存 `watch` 行があればそれを再利用し
`watch_subscription` 行を追加するだけ (=2台目以降は IMAP 接続を増やさな
い)。`fire()` はその watch の `watch_subscription` を全件引いて、購読して
いる device 全員に (各自の accountId で) push する。`DELETE
/v1/watches/:id` は呼び出した device の `watch_subscription` 行だけを削除
し、購読者が0件になった時だけ `watch` 行自体を消して
`watcherPool.RemoveWatch` を呼ぶ — 他 device がまだ購読していれば監視は
続行する。

**資格情報の統合条件**: identity が一致しても登録ごとに `auth.secret` が
異なる場合がある (パスワード変更を一部端末にしか反映していない、
OAuth refresh token を端末ごとに別々に取得している、等) ため、
`CreateWatch` は複合を試みず「最後に登録した secret で上書きする」方式
にした (`store.go` の `CreateWatch` doc comment 参照)。上書き時は
`status`/`lastErrorKind`/`lastErrorAt` もリセットし、新しい資格情報に
まっさらな状態で最初の接続を試させる。

**この変更で「通信の形」(wire format: `POST/DELETE/GET /v1/watches` の
リクエスト/レスポンス JSON 形状) 自体は変えていない** — `watchId` が複数
device 間で共有され得るようになった点を除き、既存のエンドポイント契約は
そのまま。そのためアプリ側 (`WatchReconciler.swift` 含む) の変更は不要
で、**リレー単体を更新するだけでよい** (アプリの同時更新は不要)。

**既存 watch 行の扱い**: 旧スキーマ (`watch` に `deviceId` 列がある形) を
起動時に検出したら、行ごとの移行は行わずテーブルごと破棄する
(`dropLegacyPerDeviceWatchTableIfPresent`)。個人のテスト用デプロイで
全端末の再登録が許容できるという前提に基づく判断で、アプリ側
`WatchReconciler` が起動/フォアグラウンド時に `GET /v1/watches` を
ground truth として自動的に watch を再登録するため、ユーザーの手動操作
は不要 — 次にアプリが起動するまでの間、新着メールの push 通知が届かない
空白期間が生じるだけ。運用者がユーザーの操作を必要としない前提を置けない
デプロイでは、この破棄が起きる旨を反映前に把握しておくこと。

**新しい `WatchErrorKind` (wire 値) を安易に追加しないこと** — Swift 側
の `OtegamiRelayAPI.WatchSummary.ErrorKind` は `String, Codable` の
素朴な enum で、`decodeIfPresent` は「キーが無い」場合しか救わず、
「キーはあるが値が未知の文字列」は `DecodingError` で `WatchSummary`
全体のデコードを失敗させる。既に配布済みのアプリが解釈できない値を
リレーが返すと `GET /v1/watches` のレスポンス全体が壊れる。Task #206
がレート制限を `lastErrorKind=connectionError` (既存の値) で記録して
いるのはこのため — 新しい種別が本当に必要なら、先にアプリ側の enum
を `default: .connectionError` 相当のフォールバックを持つ形に変更して
から、リレー側で新しい値を返し始めること。

**追記 (Task #210: 実機バグ3、Task #208 配信で実際に通知が最大24時間
止まった件)。** 上の「**既存 watch 行の扱い**」節が「アプリ側
`WatchReconciler` が起動/フォアグラウンド時に `GET /v1/watches` を
ground truth として自動的に watch を再登録するため、ユーザーの手動操作
は不要」と書いていたのは楽観的すぎた。実際に Task #208 のスキーマ入れ
替えをデプロイしたところ、ユーザーが両デバイスでアプリを開いても
リレー側の `watch` テーブルが0件のまま (通知が届かない状態が継続) に
なった。

原因は `AppEnvironment.reconcilePushWatchesIfNeeded()` 側にあった:
`GET /v1/watches` の呼び出しそのものを `watchReconcileInterval` (1日
1回) で絞っていたため、前回成功した reconcile パスから24時間経つまで
は次のフォアグラウンド復帰でも一切リレーに問い合わせず、結果として
「リレー側で watch が全滅している」という異常状態にすら気づけなかった。
ローカルの `accountWatchMap` (accountId→watchId のキャッシュ) は
Task #208 のようなリレー側だけのスキーマ移行では一切更新されない
ため、「ローカルの記録が空かどうか」だけを見る素朴なチェックでは
この事象を検出できない — 移行後もローカルにはそれっぽい (だが実体は
もう存在しない) watchId が残ったままになるため。

**対策 (`packages/OtegamiKit/Sources/PushRelayClient/WatchReconciler
.swift` の `shouldAttemptReconcile(now:lastFailureDate:
failureBackoffInterval:)`、`apps/Otegami/Sources/AppEnvironment.swift`
の `reconcilePushWatchesIfNeeded()`)**: `GET /v1/watches` の取得自体を
毎回のフォアグラウンド復帰で無条件に行うよう変更し (`WatchReconciler
.plan` は純粋関数でコストは通信1回だけ、`syncAllAccountsOnce()` が
毎回のフォアグラウンドで行っている実作業に比べれば軽い、という判断)、
古い「1日1回」の日次スロットルは撤去した。代わりに導入したのは
「直前の取得が*失敗*した場合だけ」5分間バックオフする仕組み
(`PushSettingsStore.lastWatchReconcileFailureDate`) — リレーが本当に
落ちている間、フォアグラウンド復帰のたびに叩き続けて連打にならない
ようにするための、性質の異なるスロットル。前回の**成功**からの経過
時間はこの判断に一切関与しない (関数のシグネチャに意図的にそのような
パラメータを持たせていない) — それこそが今回の不具合の原因だったため。

**ローカルの `accountWatchMap` が空かどうかだけを見て日次スロットルを
バイパスする」という狭い対策は採用しなかった** — 上述の通り、今回の
実際のインシデントはローカルの記録が空ではなく (Task #208 はサーバ側
だけの移行なので)、この対策では検出できなかったはず。「リレーに直接
聞く」以外に ground truth を得る手段が無い以上、フェッチ自体を条件
付きで省略するアプローチは根本的に同じ不具合を再発させ得ると判断した。

**手動回復導線 (`PushWatchStatusSection`/`PushWatchStatusRow`,
Task #173 由来)** も合わせて拡張した: 従来は `.stopped` 行にしか
「再登録」ボタンが無く、`.notRegistered` (今回のようにリレー側の
watch が全滅した直後、全アカウントがこの状態になる) には手動での
回復手段が画面上に一切無かった。`reregisterWatch(for:)` は
削除対象が無くても安全に動作するため、同じボタンを `.notRegistered`
行にも表示するようにした (ラベルは「再登録」ではなく「登録」—
リレーが一度も watch を持ったことが無い状態に「re-」は不適切なため)。
これは同時に「見える化」も兼ねる: `PushNotificationSettingsView` は
画面を開くたびに `GET /v1/watches` を取得し直して行を再構築するため、
リレー側の watch 全滅は次にこの画面を開いた瞬間に全行が「未登録」と
表示される形で既に可視化されている。
