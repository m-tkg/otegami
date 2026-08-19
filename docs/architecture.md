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

### `server/otegami-relay-go/`

otegami の push 通知は、セルフホストする「push リレー」が対象アカウントの
IMAP を監視 (IDLE、または非対応サーバーへの polling) し、新着を検知すると
APNs 経由でデバイスへ通知を送る構成で動く (OSS ビルドで Apple Developer
アカウント/APNs 認証情報を配布できないため、ビルド元が自分でこのサーバー
を運用する前提)。

`server/otegami-relay-go/` が HTTP API、SQLite 永続化、資格情報暗号化、
IMAP IDLE、APNs 配信を実装する。デプロイ手順・環境変数は
[`docs/relay-deployment.md`](relay-deployment.md) 参照。

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
`.claude/skills/verify/SKILL.md` から呼ばれる) を置く。検証スクリプトが
共有する処理は `scripts/lib/` にある — シミュレータ起動/xcodebuild の
共通ヘルパー (`simulator.sh`/`build.sh`)、`verify-screen.sh` のシナリオ
定義テーブル (`verify-screen-scenarios.sh`)、macOS QA 用 CGEvent
ドライバ (`verify-macos-qa-driver.swift`)。新しい検証スクリプトを書く
ときは、まずここの既存関数を再利用する。

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

### テストターゲット

- `packages/OtegamiKit` の各モジュールのテストは `make test`
  (`swift test`) で走る。複数テストターゲットが共有するテストダブル・
  ヘルパーは `OtegamiKitTestSupport` ターゲットに集約されている
  (2026-08-01 に重複定義を統合)。
- apps 層にも単体テストターゲットがある: `OtegamiAppTests` (アプリ本体
  のロジック) と `NotificationServiceTests` (通知拡張)。
  `make ios-apptests` で実行する (シミュレータ向け `xcodebuild test`)。

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
- アーカイブ/削除/迷惑メール化/アーカイブ解除/迷惑メール解除は、移動先メールボックスが
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

**追記 (Task #215): 上記の `pollWait`/`PollKeepAliveInterval` (NOOP
キープアライブで接続を張りっぱなしにする設計) はその後廃止した。** Task
#206 の「維持のための通信量そのものがレート制限の原因になる」という
問題が、Task #208 のデバイス統合後もなお時間窓ベースで再発することが
判明したため — 「維持しつつレート制限も避ける」は同じ接続を保持し続ける
設計では両立しないという結論に至った。非 IDLE サーバーの polling は
現在「`PollInterval` ごとに接続→SELECT→LOGOUT を繰り返す」設計
(`runPollCycle`) に置き換わっている。詳細と実測根拠は下記 i. の
「追記 (Task #215)」参照。

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

**追記 (実クラッシュ調査、TestFlight v1.14.1、iPad): 通知アクション背景
起動での再発と追加対策。** 上記の scenePhase 駆動の対策 (Task #192) は
入っていたが、実クラッシュログでは通知アクション (`MARK_READ`/
`ARCHIVE`、`options: []` なので背景起動) がアプリをバックグラウンド
冷間起動し、起動 3.3 秒後にメインスレッド発の同期 DB write
(`AppEnvironment.init()`) のままサスペンドされて `0xDEAD10CC` に至って
いた。根本原因は以下の穴の組み合わせ:

1. `OtegamiApp.swift`の`@State private var environment = AppEnvironment()`
   は scenePhase ハンドラより**前に**メインスレッドで同期実行される —
   `AppEnvironment.init()`自体が DatabasePool 生成・マイグレーション・
   `mergeDuplicateAccounts`の同期 write を含む。
2. `PushNotificationActionHandler`が通知アクションのたびに**2本目の
   `DatabasePool`**を毎回開いていた — 同じ共有ファイルへの重複コスト。
3. AppDelegate の `didFinishLaunchingWithOptions`に背景起動時の保護
   (`beginBackgroundTask`) が無かった。
4. suspend の post が `Task { await ... }` 経由で非同期 — scenePhase の
   `.background`遷移からpostまでにスケジューラのラグがあった。
5. scenePhase が一度も張られない背景起動パスでは、suspend が一度も
   post されないままだった。

対策 (いずれも既存の suspend/resume の仕組みを壊さず追加):

- **通知アクションの背景実行保護**: `PushTokenCenter.swift`の
  `AppDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)`
  が `PushNotificationActionHandler.handle(...)` の呼び出しを
  `withPushActionBackgroundTask(name:_:)`(`UIApplication
  .beginBackgroundTask`/`endBackgroundTask`)で包む。expiration handler は
  `Database.suspendNotification`を post してから安全に打ち切る。
  `didFinishLaunchingWithOptions`自体も`beginLaunchBackgroundTaskIfNeeded
  (application:)`で背景起動時 (`applicationState == .background`)に固定
  タイムアウト付きの背景タスクを張り、`AppEnvironment.init()`から最初の
  scenePhase ハンドラまでの区間を保護する。
- **2本目の`DatabasePool`を廃止**: `SharedAppDatabaseCenter`
  (`apps/Otegami/Sources/Support/SharedAppDatabaseCenter.swift`) が
  `AppEnvironment.database`への`weak`参照を保持し (`PushDatabaseChangeObserver`
  と同じ二段階wiringパターン)、`PushNotificationActionHandler.handle(...)`
  はプロセス内に既に`AppEnvironment`があればその`database`を再利用、
  無ければ (通知アクション単独でのコールド背景起動) 従来どおり自前で開く。
- **suspend post の即時化**: `OtegamiApp.swift`の
  `.onChange(of: scenePhase, initial: true)`が、`.background`/`.inactive`
  を観測した瞬間に`Task { }`を挟まず`NotificationCenter.default.post(name:
  Database.suspendNotification, object: nil)`を同期的に呼ぶ。
  `AppEnvironment.suspendSharedDatabaseIfNeeded()`(dedup付き) 自身のpostは
  従来どおり`handleScenePhaseChange`内でも走る — 二重postはGRDBの
  suspend()/resume()が冪等なので無害。
- **`didEnterBackground`フォールバック**: `AppDelegate`が
  `UIApplication.didEnterBackgroundNotification`を購読し、scenePhase 経由
  で suspend が飛ばなかったケースでも同じ post が飛ぶようにする。
- **通知アクション自身の書き込みの再試行**:
  `PushNotificationActionExecutor.execute`のローカル DB write (通知
  アクションが実際に起きたことを示す唯一の永続記録) は、上記の積極的な
  suspend post と自分自身が同じ背景起動レース条件に巻き込まれうる —
  `applyWithSuspensionRetry`が`DatabaseSuspensionSupport
  .isSuspensionError(_:)`を検知した場合に数回だけ短い間隔で再試行する
  (`PushNotificationActionExecutor.swift`のdoc comment参照)。**既知の
  残存制限**: このリトライは、この起動中に一度も`.active`にならない
  純粋な背景起動 (通知アクションの通常ケース) では resume が来ないため
  救えない — `docs/push-notification-actions.md`「既知の制限」参照。
- **`NotificationService` Extension は suspend post しない (意図的な
  据え置き)**: この Extension は Phase 1/Phase 3 で実際に write する
  (以前のこの節の記述は「read-only」としていたが誤り — 今は
  `apps/Otegami/NotificationService/NotificationService.swift`の
  `lookupAccount(id:)`のdoc commentが最新の判断根拠を持つ)。それでも
  suspend post が不要なのは、この Extension が「凍結されたまま長時間
  ロックを握り続ける」リスクを持たないため — OS はハードな約30秒の
  実行予算超過で**強制終了**する (サスペンドして後で再開、ではない) の
  で、GRDB の suspend/resume が守ろうとしている「凍結中のロック保持」の
  シナリオがそもそも成立しない。

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
   自分ではキューを処理しない。ただし単純な no-op ではなく
   `trailingAccountIds` に積んで、進行中の replay の完了後にもう1周
   trailing pass を実行させる (2026-08-01 の "Drain queued operations
   after replay overlap" — 進行中の replay がスナップショットを取った
   **後**に積まれた op が、次のフォアグラウンド遷移や IDLE wake まで
   取り残される穴を塞ぐため)。
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

**追記 (Task #211: 実機バグ4、通知の内容が Yahoo! JAPAN アカウントだけ
出ない)。** Task #208 配信後の実機報告: 通知自体は Gmail/iCloud/Yahoo!
JAPAN いずれも届くようになったが、**Yahoo! JAPAN だけ**差出人・件名が
「新着メールがあります」という汎用文言のまま出ない (Gmail/iCloud は
正常)。`NotificationService.swift`(`apps/Otegami/NotificationService/`)
の `enrich(payload:)` は、この push を受け取った端末自身が別途 IMAP
接続を張って最新メッセージのエンベロープ(と、設定が on なら本文)を
取りに行く — つまり、この Extension の接続はリレーが watch のために
持っている接続とは**別の**接続。Task #201 でリレーが Yahoo! への接続を
張りっぱなしにするようになり (それ以前は2〜5分で切れていた)、
Task #208 で同一アカウントの watch を1本に統合した後もなお症状が続いて
いる。上記 i. の `[LIMIT]` (コマンドレート制限) に加えて、Yahoo! JAPAN
は同時接続数の制限も持つ疑いがある — リレーの常時接続1本 + この
Extension の一時接続がぶつかっている可能性。**現時点では未検証**
(実機のログを取っていない)。

**当面の対策はログの追加に留めた。** `enrich(payload:)` の各段階
(preferences 判定/account lookup/credential 解決/IMAP connect/select/
envelope fetch/body fetch) の成否を OSLog (`Logger(subsystem:
"com.mtkg.otegami", category: "NotificationService")`, `.notice`
以上) に記録するようにした — 特に IMAP 側の失敗は
`NotificationServiceDiagnostics.summarize(category:underlyingDescription:)`
(`packages/OtegamiKit/Sources/PushRelayClient/
NotificationServiceDiagnostics.swift`、ユニットテスト済み) が
`MailTransportError` の種別を分類し、`underlyingDescription` に
`[LIMIT]` を含むかどうか (`looksRateLimited`) を判定する。
`authenticationFailed` の `underlyingDescription` は意図的にログへ
出さない (サーバーがログイン名をエコーし返す実装があり得るため —
本文・件名・差出人・資格情報は一切ログに出さない、という既存の方針
と同じ)。実機で再現した際に Console.app (Mac に接続して
`log stream --predicate 'subsystem == "com.mtkg.otegami" &&
category == "NotificationService"'`、または sysdiagnose) で
`enrich:` 系のログを見れば、どの段階で・どのカテゴリ (`connectionFailed`
/`authenticationFailed`/`serverError`/タイムアウトなら
`serviceExtensionTimeWillExpire` が先に出る) で止まっているかが分かる
はずで、**それを見てから初めて対策 (Extension 側の短い再試行/フォール
バック文言の改善/リレー側の接続の持ち方の見直し、のいずれか) を選ぶ**。
先に対策を決め打ちしなかったのは、上記 i. の教訓 (「サードパーティの
報告値」より「自分の本番ログでの実測値」を優先すること) と同じ理由。

**追記 (Task #213: 端末内診断画面「プッシュ通知の診断」の追加)。**
Task #211 のログは Mac に有線接続して Console.app/`log stream` を操作
しないと読めず、実機での即時切り分けができなかった (このアプリの
「翻訳の診断」画面と同じ課題感 — F15 の教訓どおり、Mac 無しでスクリーン
ショット1枚から原因を確認できることが決め手になった前例がある)。
そこで `NotificationService.enrich(payload:)` の各段階
(`recordStage(_:outcome:since:)`) を、上記 OSLog への書き込みに加えて
インメモリの `stageRecords` にも積み、`deliver()` の最後に **1回だけ**
共有 App Group の `UserDefaults` (`PushDiagnosticsHistory
.appending(_:toSuite:)`) へ JSON で書き出すようにした。アプリ側の
設定 → 一般 → プッシュ通知 → 「プッシュ通知の診断」
(`PushDiagnosticsView`) がそこから読む
(`packages/OtegamiKit/Sources/PushRelayClient/PushDiagnosticsStore.swift`)。

**共有領域に `UserDefaults` を選んだ理由 (共有 `AppDatabase` への書き込み
は選ばなかった理由)**: この機能を追加した当時、この Extension は
`dbWriter.read` のみで一切 `.write` しないという前提があった (現在は
Phase 1/Phase 3 の実装で `runIncrementalSync`/`writeBackRelaySnippetIfNeeded`
が実際に write する — `NotificationService.lookupAccount(id:)` の doc
comment (Task #192) 参照、上の Known pitfalls e. の追記も参照。「診断記録
のためだけに新しい `.write` 経路を追加すると 0xDEAD10CC を起こすロックを
持つ前提を壊しかねない」という当時の懸念自体は前提が変わった今でも別の
理由で妥当なままなので、この節の結論 (`UserDefaults`のまま) は変えて
いない) — 記録する内容 (各段階の分類文字列・bool・整数、最大20件) は
スキーマ管理の要る RDB を持ち出すには小さすぎることもあり、
`BadgeCenter.setBadge(count:)`と同じ`UserDefaults(suiteName:)`前例に
倣った。

**保持件数は20件** (`TranslationDiagnosticsStore`の5件より多い) —
複数アカウントがこの1つの履歴を共有するため、Yahoo! JAPAN 以外の
アカウントのプッシュが間に挟まっても目的の記録が押し出されにくいよう
余裕を持たせた。

**書き込みが本来の処理を圧迫しないこと**: 各段階の結果はメモリ上の配列に
追記するだけ (I/O なし)、実際の JSON エンコード + `UserDefaults` 書き込み
は `deliver()` で1回だけ、`contentHandler`を呼ぶ直前に行う。

**検証状況**: `scripts/verify-screen.sh push-diagnostics`/
`push-diagnostics-populated` でシミュレータの画面自体 (空状態・
`PushDiagnosticsRun.Outcome`の全ケース) の見た目は確認した
(`docs/verify.md`の「シミュレータの既知の不調」3. 追記参照 —
通知許可ダイアログが画面下部を覆うが主要要素は確認できた)。**共有
`UserDefaults`への実際の書き込み・読み出しの往復 (`NotificationService`
が本当に書き、アプリが本当に読む一連の流れ) は実機でしか検証できて
いない** — シミュレータは実際の APNs push を一度も受け取らないため
`NotificationService`自体が起動しない。実機で Yahoo! JAPAN アカウントの
通知内容が出ない事象を再現した際、Mac 無しでこの画面を開いて段階・
カテゴリ・レート制限の疑いを確認できるかどうかが、この機能自体の
最終確認になる。

**追記 (Task #215: Task #206 の対処後もなお断続的な認証エラーが継続、
設計を「維持しながら待つ」から「維持せず短時間だけ繋ぐ」へ変更)。**
Task #206 適用後の本番ログに、次のパターンが繰り返し出た:

```
05:35:28  watch connected (Yahoo, idle=false)
06:35:31  WARN watch rate limited by server, waiting on the same connection instead of reconnecting
          wait=5m0s serverResponse="A87 NO [LIMIT] STATUS Rate limit hit."
06:41:16  WARN watch connection error, reconnecting
          error="write tcp ...: write: broken pipe"
06:41:21  WARN watch authentication failed
          serverResponse="A1 NO [AUTHENTICATIONFAILED] Incorrect username or password."
07:11:21  watch connected              (30分の認証バックオフ後)
08:11:27  WARN rate limited, wait=5m0s (再び、接続からちょうど1時間後)
08:17:12  WARN broken pipe → reconnecting
08:17:17  WARN authentication failed
```

**判明した2つの問題:**

1. **「同じ接続で待つ」対処 (Task #206) 自体が機能していなかった。**
   `[LIMIT]` を受けて `RateLimitInitialWait` (5分) 待つ実装
   (`sleepCtx(ctx, rateLimitWait)`) が、待っている間に一切 IMAP コマンド
   を送っていなかった。Yahoo! JAPAN の無通信タイムアウトは上記 c. の実測
   で2分未満と分かっている。結果、待機中に接続が死に (`broken pipe`)、
   `runWatchLoop` がそれを「接続エラー」として即座に再接続 = 再 LOGIN
   した — Task #206 が防ごうとした「再ログインの連鎖」に結局戻っていた。

2. **「維持のための通信」自体が別の制限に当たっていた。** ログを見ると
   `06:35:31` と `08:11:27` — **接続からちょうど1時間**で `[LIMIT]` が
   出ている (差はそれぞれ1時間0分3秒、1時間0分6秒)。この間の実際の
   コマンド量は 45秒ごとの NOOP (80回/時) + 5分ごとの STATUS (12回/時)
   = 約92回/時。「ちょうど1時間で毎回再現する」という再現性の高さは、
   接続開始 (または LOGIN) を起点とした時間窓ベースの予算制であることを
   強く示唆する。**ただし** この観測だけでは「時間窓ベースの予算」と
   「一定間隔のコマンドを一定回数打った結果として同じ経過時間で閾値に
   達する回数ベースの予算」を完全に区別できない — 本テストで実装した
   `RateLimitWindow`/`RateLimitWindowBudget` はどちらの仮説の下でも安全
   側に倒すよう、**設計選択そのものは「まず総コマンド量を大きく減らす」
   ことを軸にした**ため、この曖昧さは実害を生まない (根拠の限界を
   正直に書く: これ以上の切り分けにはサーバ側の非公開仕様が要る)。

いずれにせよ結論は同じ: **「接続を維持するための通信」自体が「レート
制限に当たる原因」になっている。同じ接続を保持し続ける設計のままでは
「制限を避けつつ維持もする」の両立ができない。**

**検討した選択肢:**

- **(a) 維持通信をやめ、問い合わせの間隔を延ばす。** `PollInterval`
  ごとに接続→SELECT→LOGOUT を繰り返す。ロックを引き起こした当時
  (`c.`の実測: 5分間隔で288回/日 = 12回/時、さらに2分間隔の誤設定で
  720回/日 = 30回/時) より大幅に少ないログイン頻度に抑えられる。代償は
  通知が最大 `PollInterval` 分遅れること。
- **(b) 維持通信の間隔を大幅に延ばす。** Yahoo の無通信タイムアウトが
  2分未満 (`c.`の実測) と分かっている以上、NOOP 間隔をそれより延ばすと
  即座に接続が切れる。「維持しつつ間隔を延ばす」は物理的に両立しない
  ため不採用。
- **(c) `[LIMIT]` を受けたら待つ間も接続を維持する (問題1だけの対処)。**
  必要だが単独では不十分 — 維持通信そのものが時間窓予算を食い潰す構図
  (問題2) は残る。
- **(d) サーバごとに戦略を変える (IDLE 対応はそのまま、非対応だけ
  (a))。** 実装上は自然に得られる: 非 IDLE の polling 経路と IDLE 経路
  はもともとコード分岐が別なので、「非 IDLE 側だけ (a) の設計にする」
  だけで新しい設定を増やさずに (d) を満たせる (IDLE 対応サーバ
  iCloud/Gmail/Outlook は元々この分岐を通らない)。

**選んだ設計: (a) + (d) を、既存の分岐構造だけで実現。** 新しい
Options フィールド (サーバ種別を選ぶような値) は追加していない —
`Options.PollInterval` の意味を「STATUS 待機の間隔」から「接続サイクル
の間隔」に変更しただけで、IDLE 対応/非対応の分岐自体は既存のまま。

**実装 (`server/otegami-relay-go/internal/watcher/pool.go`):**

- `connectAndWatch` は SELECT/CAPABILITY 後、非 IDLE サーバーなら
  `runPollCycle` を呼んで即座に LOGOUT し、`errPollCycleComplete` を
  返す。`runWatchLoop` はこれを見て `PollInterval` だけ寝てから再接続
  する。`PollKeepAliveInterval` と `pollWait` は削除した (この設計には
  もう存在しない概念のため)。**`PollInterval` のデフォルトは当初 12分
  (10〜15分の範囲の中間) で実装したが、下記「追記: 実装中に app 側の
  認証まで巻き込むロックが発生」を受けて最終的に 20分に引き上げた** —
  1サイクルの通信は LOGIN+CAPABILITY+SELECT+LOGOUT の4コマンドなので、
  20分間隔なら**1時間あたり3ログイン・約12コマンド**。実測でレート制限
  に当たった約92コマンド/時に対して約7.7倍、Task #187 のロックを招いた
  約24ログイン/時に対して約8倍の余裕を見た数値。
- 直前の poll サイクルの UIDNEXT (`lastKnownUIDNext`) は、IDLE 経路の
  `baselineUIDNext` と違って**接続をまたいで**保持する必要があるため、
  `connectAndWatch` のローカル変数ではなく `runWatchLoop` に置いて
  ポインタで渡している。
- IDLE 対応サーバー (iCloud/Gmail/Outlook) はこれまで通り1本の接続を
  保持し、`Idle()` でブロックし続ける — Task #215 はこの経路の挙動を
  変えていない (レート制限の実測は全て Yahoo! JAPAN = 非 IDLE)。

**問題1 (待つなら維持する、維持しないなら切断を前提に扱う) の対処:**

- **非 IDLE の polling 経路**: 設計 (a) により、待ち時間の間そもそも
  接続を保持しない — 毎サイクル明示的に LOGOUT/切断するため、「維持の
  つもりが実は死んでいた」という事態自体が起きなくなる。切断は
  `errPollCycleComplete` という正常系の値として扱われ、`backoff` も
  `RecordWatchError` も一切触らない (`runWatchLoop` の対応する `case`
  参照)。
- **IDLE 対応経路の `[LIMIT]` 待ち (Task #206 が入れたコード、非 IDLE
  では使われなくなった)**: こちらは引き続き同じ接続で待つ設計を維持する
  ため、「維持する」を選んだ以上ちゃんと維持するよう修正した —
  `sleepCtx` の生スリープを `sleepWithKeepalive` に置き換え、待機中も
  `IdleRateLimitKeepAliveInterval` (デフォルト45秒、`c.`の実測を再利用)
  ごとに NOOP を送るようにした。Yahoo! JAPAN は IDLE 非対応なのでこの
  分岐を実際には通らず本番証拠は無いが、「保持する接続は必ず生かしておく」
  という原則をコード全体で一貫させるための修正。
- **LOGIN 自体が `[LIMIT]` を受けた場合の誤分類も修正した**: 再接続後の
  LOGIN が偶然レート制限の時間窓に重なって拒否されるケースを本テスト
  (`TestPollDesignBacksOffWithoutRepeatedLoginsWhenRateLimited`) で発見
  した。従来のコードはこれを `classifyAuthFailure` 経由で「パスワードが
  違う」系の認証失敗として扱い、Task #187 の30分バックオフに入ってしまう
  — 誤りではあるが安全側 (再ログインの連打にはならない) だったものの、
  意図とは異なる遅い回復だった。`connectAndWatch` の認証失敗パスの先頭で
  `isRateLimited(err)` を先にチェックし、真なら
  `RateLimitInitialWait`/`RateLimitWaitCap` の経路 (即座リトライ、
  待ち時間は倍々) に回すよう修正した。

**追記: 本タスクの実装中に、リレー接続だけでなく app 自身の IMAP
ログインまで巻き込むロックが実際の本番アカウントで発生した。** 上記の
`[LIMIT]` → 再接続 → `AUTHENTICATIONFAILED` の悪循環 (Task #206 適用後
もなお発生していたもの、本追記冒頭のログ参照) が続いた結果、Yahoo! 側の
ロックがこのリレーの接続だけでなく**同一アカウントに対する app 自身の
直接 IMAP 接続の認証まで失敗させる**状態に発展し、ユーザーが app から
Yahoo! のメールを受信できなくなった。オーケストレータが緊急対応として
リレー側の Yahoo! watch を削除し (Gmail 3件・iCloud 1件のみ監視する状態
に縮退)、Yahoo! への接続を完全に止めることでユーザーの受信を回復させる
試みを行った。

これは「通知が遅れる」対「通知が断続的に止まる」という当初のトレード
オフの前提を変える — 正しくは**「通知が遅れる」対「メールが受信できなく
なる」**という比較であり、後者の方がはるかに悪い。これを踏まえて
`PollInterval` のデフォルトを 12分から**20分**に引き上げた (詳細は上記
「実装」節)。それでも「絶対に安全」という保証は無い — Yahoo! 側の
ロック条件は非公開であり、かつ今回の事象は「頻度」だけでなく「認証
失敗を伴う再接続そのものの発生」がロックの引き金だった可能性を示唆して
いる (本追記冒頭のログでは接続からの平均頻度は必ずしも高くなかったにも
関わらずロックに至っている)。**問題1の修正 (意図しない再ログインの
根絶) の方が、単なる間隔延長より本質的な対策**という位置づけであり、
20分という数値そのものは実測に基づく安全マージンの見積もりに過ぎない。

**さらなる保険が要る場合の逃げ道**: 今回の縮退運用 (Yahoo! watch を
完全に削除し、app のフォアグラウンド同期だけに頼る) が示す通り、
「非 IDLE サーバーには push を提供しない」という選択肢も現実的にあり
得る。本番反映後もなお問題が再発するようなら、`PollInterval` をさらに
延ばす前に、この設計そのもの (非 IDLE サーバーでの push watch 登録を
やめるかどうか) をユーザー・オーケストレータと相談すべき — 通知を無理に
成立させてメールが受信できなくなる方が明らかに悪い。

**通知の即時性とのトレードオフ:** 非 IDLE サーバー (現状 Yahoo! JAPAN
のみ) の通知は最大 `PollInterval` (デフォルト20分) 遅れる。断続的に
数分〜数十分単位で完全に止まっていた従来の状態 (Task #206 適用後もなお
1時間ごとに認証エラーへ転落し、最終的には app 自身の受信まで止まった)
と比べれば、「確実に20分以内には届く」方がユーザー体験としては上と
判断した。**設定として公開する項目は増やしていない** —
`PollInterval` は既存の Options フィールドの意味を変えただけで、
新しいユーザー向け設定は追加していない。

**偽サーバでのテスト (`server/otegami-relay-go/internal/imaptest/
fakeserver.go` に `RateLimitWindow`/`RateLimitWindowBudget` — 時間窓
ベースのレート制限を追加、既存の `InactivityTimeout` と組み合わせ可能):**
`server/otegami-relay-go/internal/watcher/pool_test.go` に以下を追加。

- `TestPollDesignReconnectsEachCycleAndSurvivesAggressiveInactivityTimeout`:
  無通信で切断するサーバ (`InactivityTimeout` をどんなコマンド往復より
  短い50msに設定) の下で、新設計が複数回の再接続を続け、切断が
  `.stopped` に落ちないことを確認。
- `TestPollDesignStaysUnderHourlyRateLimitBudget`: 時間窓レート制限
  サーバの下で、新設計のコマンド総量が予算内に収まり (`RejectedCount()
  == 0`)、複数の擬似「1時間」を跨いでも新着メールを検出できることを
  確認。
- `TestPollDesignSurvivesRateLimitAndInactivityTimeoutTogether`:
  上記**両方**を同時に持つサーバ (実際の Yahoo! JAPAN の状況を模す)
  の下で watch が停止しないことを確認。
- `TestPollDesignBacksOffWithoutRepeatedLoginsWhenRateLimited`: 予算を
  極端に絞って毎サイクル `[LIMIT]` を受ける状況を作り、連続する LOGIN
  試行の間隔が `RateLimitInitialWait` 以上空くこと (連打しないこと) を
  検証 — 上記の LOGIN 誤分類バグを見つけたテスト。
- `TestIdleRateLimitWaitKeepsConnectionAliveViaNoop`: Task #206 の
  元テストを IDLE 経路向けに書き直し、`[LIMIT]` 待機中に NOOP
  キープアライブが送られていること (無通信タイムアウトを生き延びる
  ことで間接的に証明) を確認。

**反映後にログで確認すべきこと (メインセッションが本番反映後に行う):**

- **最重要**: Yahoo! JAPAN の watch が**1時間経っても `[LIMIT]` を出さ
  ないこと**。これが出れば、今回の設計変更 (コマンド総量を1時間あたり
  約92回→約12回に削減) が実際に効いている一次証拠になる。
- **さらに重要**: **app 自身が Yahoo! アカウントで正常にログイン・受信
  できること** — 今回の事象はリレーの watch だけでなく app 自身の認証
  まで巻き込んだため、リレーのログが正常に見えても油断しないこと。
  ユーザーに app からの受信を確認してもらうこと。
- `watch connected` (LOGIN) の頻度が `PollInterval` (20分) ごとに
  なっていること — Yahoo! JAPAN の watch について `watch connected` の
  間隔を見れば確認できる。
- `watch authentication failed` (`[AUTHENTICATIONFAILED]`) が
  Task #206 適用後より明確に減っていること。理想は0件。
- 通知が実際に20分以内の遅延で届いていること (ユーザー体感での確認が
  必要)。
- 万一 `[LIMIT]` や `AUTHENTICATIONFAILED` が今回の設計後も観測された
  場合は、その時刻と直前の `watch connected` からの経過時間を記録する
  こと — 上記「時間窓ベースか回数ベースか」の切り分けに使える一次データ
  になる。**その場合は `PollInterval` をさらに延ばす前に、上記「さらなる
  保険が要る場合の逃げ道」(非 IDLE サーバーへの push 提供自体をやめる) を
  検討すること。**

**追記 (Task #216: 訂正 — この節の「Yahoo のレート制限/同時接続数」という
当初の仮説は、少なくとも1件の実機報告には当てはまらなかった)。** Task #211
の追記は「`NotificationService` の Yahoo! 通知だけ差出人・件名が出ない」
症状の原因候補として、この節で調べてきたレート制限・同時接続数の疑いを
挙げていた。ところが端末内診断画面 (Task #213) が実際に記録した失敗は
`Resolving Credential 0ms 失敗: noCredential` — **IMAP 接続を一度も試みる
前の失敗**だった。レート制限も同時接続数の制限も IMAP サーバーとの通信が
実際に発生して初めて起こり得る問題なので、この時系列の失敗にはそもそも
当てはまらない (0ms という所要時間自体が「ネットワークに一切触れていない」
ことの一次証拠)。**真因は全く別の場所 — 通知拡張の Keychain クエリの
不備 — だった。** 詳細は下記 j. 節参照。この訂正の教訓: 「別の bug 調査で
Yahoo! 関連の問題が続けて報告された」からといって同じ原因を疑い続けるのは
早計で、診断画面 (Task #213) のような一次データが無ければ「症状は同じでも
原因は毎回違う」を見落とす。

### j. 通知拡張 (`NotificationService`) の Keychain クエリは `kSecAttrSynchronizable` 抜けで同期済みパスワードが見えない

**実機で確定した事実 (Task #216)。** あるアカウントの通知が「新着メール
があります」の汎用文言のまま出ない事象で、端末内診断画面 (Task #213) の
記録:

```
2026/07/31 18:42:03                          36ms
  Parsing Notification    0ms   成功
  Reading Settings        0ms   成功
  Resolving Account      33ms   成功
  Resolving Credential    0ms   失敗: noCredential   ← ここ
```

同日の他アカウントの記録は本文取得まで全段階成功していた。アカウントの
行は引けている (`Resolving Account` 成功) のに、対応する資格情報が
拡張プロセスから見えていない — しかも `Resolving Credential` の所要時間が
`0ms` で、これは IMAP 接続はおろか OAuth のネットワーク往復すら一切
発生していないことを意味する (上記 i. 節の「訂正」参照 — レート制限・
同時接続数はどちらもネットワーク通信が起きて初めて顕在化する問題であり、
この失敗の説明にはならない)。

**当初は Yahoo! 固有の事象に見えたが、調査中にユーザーから訂正が入った:
同じ端末で iCloud アカウントも同じ症状 (`noCredential`) だった一方、
Gmail (OAuth) は正常だった。** 整理すると症状は「プロバイダ」ではなく
**「認証方式」で分かれていた** — `.password` 認証 (iCloud・Yahoo!) は
全滅、`.oauth2` 認証 (Gmail) だけ正常。この訂正で「編集画面で再保存した
Yahoo! アカウントだけ」という当初の見立ては外れたが、真因の特定自体は
むしろこの訂正でより強く裏付けられた (下記)。

**真因: `NotificationService.password(forAccountId:)`
(`apps/Otegami/NotificationService/NotificationService.swift`) の
`SecItemCopyMatching` クエリが `kSecAttrSynchronizable` を一切指定して
いなかった。** Apple のドキュメント上、このキーを省略した場合の既定動作は
「**非同期化 (non-synchronizable) の項目しか返さない**」——一方アプリ本体の
`KeychainCredentialStore` (`apps/Otegami/Sources/Support/
KeychainCredentialStore.swift`) は、M11 (iCloud Keychain 同期) 以降
`setPassword` が書くすべての項目を `kSecAttrSynchronizable = true` にする
(`addSynchronizable`/`migrateToSynchronizableAndWrite`) —
**新規アカウント作成時の最初の1回の保存からすでにそうなる**、編集画面の
再保存に限った話ではない。つまり:

- **M11 以降にセットアップされた `.password` 認証のアカウントは、
  プロバイダを問わず最初から (初回保存の時点で) この Extension から
  見えなくなっていた。** 「以前は届いていた」という体感があるとすれば、
  それは pre-M11 のビルドで作成されて以来一度も再保存されていない、
  たまたま非同期化のままの項目が残っていたケースだと考えられる。
- **この仮説を直接裏付ける対照実験がコードベース内にすでにあった。**
  OAuth のリフレッシュトークンを保存する `GoogleOAuth
  .KeychainRefreshTokenStore`/`MicrosoftOAuth.KeychainRefreshTokenStore`
  (`packages/OtegamiKit/Sources/GoogleOAuth(Microsoft)/
  RefreshTokenStoring.swift`) は、アプリ本体とこの Extension の**両方から
  全く同じ型を経由して**読み書きされる (`oauthAccessToken(for:)` が呼ぶ
  `GoogleOAuth.TokenStore`/`MicrosoftOAuth.TokenStore` のデフォルト実装が
  これ) — そしてその `read(accountId:)` は最初から一貫して
  `anySynchronizableQuery` (`kSecAttrSynchronizableAny`) を使っている。
  **これが Gmail/Outlook の通知だけ正常だった理由そのもの**:
  OAuth 側はこの Extension 専用の手書きクエリではなく、最初から同期状態を
  問わずマッチする既存の共有実装を使っていたから、そもそも壊れようが
  なかった。一方 `.password` 側の `password(forAccountId:)` は
  `KeychainCredentialStore` を使わず独自に手書きされたクエリで、その
  widening だけが漏れていた。
- 検討した他の仮説 (保存時のアクセシビリティが `kSecAttrAccessibleAfterFirstUnlock`
  以外/アカウント識別子の不一致/`authType` 判定違い/Keychain Access
  Group の不一致) はいずれも否定できた — 特に Access Group は
  `project.yml` の `OtegamiKeychainAccessGroup: $(OTEGAMI_KEYCHAIN_GROUP)`
  がアプリ本体 (`Otegami` target) とこの Extension (`NotificationService`
  target) の両方に同じ非 `nil` の値を渡しており、iOS では一致している
  (かつ OAuth 側の `KeychainRefreshTokenStore` はそもそも Access Group を
  一切指定していないのに正常に動いている時点で、Access Group の不一致が
  今回の説明になり得ないことも分かる)。

**修正は読み取り側だけで完結する。** `password(forAccountId:)` のクエリに
`kSecAttrSynchronizable: kSecAttrSynchronizableAny` を追加し、同期化・
非同期化どちらの項目にもマッチするよう広げた。Keychain に保存されている
パスワード自体は最初から正しい値だったので、**ユーザーがパスワードを
入れ直す必要は無い** — 次回の push 到達時から即座に直る。合わせて、
アプリ本体の `KeychainCredentialStore.legacyServices` (`52df393` の
サービス名リネームバグ) 相当のフォールバックもこの Extension に初めて
追加した (元々一切無かった)。

**クエリ構築の純粋なロジックはユニットテスト済み。** `SecItemCopyMatching`
自体は `swift test` から呼べず、`NotificationService.swift` は
Extension target で `swift test` 到達不能なため (`KeychainCredentialStore`
のクエリ構築ロジックが同じ理由で「inspection で検証する」に留まっている
前例と同じ制約)、「どのサービス名を・どういう順で・同期状態を問わず
一致させるかどうか」という事実だけを `Security` に依存しない値として
`PushRelayClient.NotificationServiceKeychainQuery`
(`packages/OtegamiKit/Sources/PushRelayClient/
NotificationServiceKeychainQuery.swift`) に切り出し、
`NotificationServiceKeychainQueryTests.swift` でテストした。
`NotificationService.password(forAccountId:)` はこの型が返す
`Attempt` を実際の `[String: Any]` CFDictionary に変換するだけの薄い
グルーになっている。

**診断画面の失敗カテゴリも合わせて詳細化した (Task #216)。** それまで
`credential` 段階の失敗は常に `noCredential` 一色で、Keychain 項目が
無いのか・OAuth のクライアント ID が未設定なのか・トークン取得に失敗
したのかを画面から区別できなかった。`resolveAuth(for:)`/
`oauthAccessToken(for:)` の戻り値をそれぞれ `CredentialResolution`/
`OAuthTokenOutcome` という列挙型にし、`passwordNotFound`/
`passwordKeychainError`/`oauthNoClientId`/`oauthTokenUnavailable`/
`oauthUnsupportedAccountKind` のいずれかを診断画面のカテゴリとして
記録するようにした (資格情報そのものは相変わらず一切記録しない)。

**実機での確認手順 (通知拡張はシミュレータで検証できない)。影響範囲が
`.password` 認証のアカウント全部だったため、**iCloud・Yahoo! 双方**で
確認すること (Gmail は元々正常だったので確認優先度は低い):**

1. この修正を含むビルドを実機にインストールし、`.password` 認証の
   各アカウント (iCloud・Yahoo! など) の push が実際に届く状態であること
   を確認する (設定 → 一般 → プッシュ通知 → 「プッシュ通知の登録状況」で
   `.stopped`/`.notRegistered` なら再登録する)。
2. iCloud・Yahoo! それぞれに新着メールを実際に送るか待ち、通知が届いた
   際に差出人・件名 (設定に応じて本文プレビュー) が表示されることを
   確認する。
3. 念のため設定 → 一般 → プッシュ通知 → 「プッシュ通知の診断」を開き、
   iCloud・Yahoo! 双方の直近の実行が `Resolving Credential` を含む全段階
   で成功していること、万一まだ失敗する場合はその `category` (今回追加
   した詳細な文字列) を確認する。

### k. mailcore2 の `syncMessages` は modseq==0 で CHANGEDSINCE を丸ごと省略する

mailcore2 (`MCIMAPSession.cpp` の `syncMessages`) は、渡された modseq が
`0` のとき `CHANGEDSINCE` 句を**付けずに**素の `UID FETCH` を発行する。
`UIDRange.all` (`1:*`) と組み合わさると、大きなメールボックスでは
**全メッセージの FLAGS を 1 本のコマンドで取得**することになり、応答が
返り切るまで数分単位でブロックする (上記 d. 節と同じく、open-ended
range なのでチャンク化もキャンセルの checkpoint も効かない)。

これが厄介なのは自己再現ループになる点: ローカルの
`MailboxRecord.highestModSeq` は同期パスの**最後** (step 3、メタデータ
コミット) でしか保存されないため、この巨大 FETCH が途中でキャンセル・
タイムアウトすると modseq は `0` のまま残り、**次のパスも同じ全件 FETCH
から始まる**。「pull-to-refresh が何分も終わらず、忘れた頃 (たまたま
1 回完走したとき) にだけ反映される」という形で顕在化した。

対策として `MailboxSyncer.incrementalSync` のフラグ同期は、CONDSTORE
対応サーバーでも **stored `highestModSeq == 0` (未確立) または
`status.highestModSeq == 0` (NOMODSEQ) のときは CONDSTORE 経路に入らず
`refetchAndDiffFlags` にフォールバック**する (既知 UID 窓に有界化した
チャンク付き FLAGS 再取得。進捗・キャンセル・削除検出込み)。この
ベースラインパスが完走すると step 3 が SELECT 時点の `HIGHESTMODSEQ` を
保存し、次回から本来の `CHANGEDSINCE` 差分同期になる。

**`sinceModSeq: 0` で `condstoreFlagChangeSync` (ひいては mailcore2 の
`syncMessages`) を呼ぶコードを新しく書かないこと** — 「0 = 最初から
全部」ではなく「0 = CHANGEDSINCE 無しの全件 FETCH」になる。modseq が
未確立ならフラグ同期は必ず有界化された経路 (`refetchAndDiffFlags`) を
使う。

### l. 未読件数・検索結果は「その端末がどこまで取り込めたか」に依存する

実機報告「『すべてのメール』の未読件数が iOS と macOS で違う。iOS だと
11 なのに macOS では 99+」の調査結果。**表示ロジックのバグではなかった。**

未読件数の計算式は両プラットフォームで同一 (iOS のヘッダは
`MessageQuery.unifiedInboxUnreadCount(accountIds:role:)`、macOS の
サイドバー見出しは `MailboxCategoryGrouping.unreadCountForAllMailCategory`
— 同じ DB に対して両方を実行すると同じ値になる)。違っていたのは
**ローカル DB に取り込み済みのメール量**で、macOS 側は全メールボックスの
バックフィル (`BackfillSyncer`、`mailbox.backfillLowerBound` が `1` に
達した状態) が完了しており、iOS 実機はまだ途中だった。差分の実体は
数か月前の未読メールで、iOS 側の DB にはその UID 範囲がまだ存在しな
かった。

同じ理由で**ローカル検索も端末ごとに結果が違う** (検索は完全にローカル、
この文書の「同期エンジンの設計」節を参照)。

この挙動自体は設計どおりだが、当時は**進捗を確認する手段がアプリのどこ
にも無かった**のが問題だった。「操作同期の診断」画面 (設定 → 一般 →
`OpQueueDiagnosticsView`) が出す「完了」は `OpQueueProcessor.replay`
(この端末の操作をサーバーへ送る処理) の結果であって、メール取得とは
無関係なのに、そう読めてしまう。現在は同じ画面に
**「メール取得の進捗 (操作同期とは別)」** セクションがあり
(`MailboxBackfillProgressQuery`)、アカウントごとに取り込み済み件数・
まだ遡り切れていないメールボックスとその割合が見える。端末間で件数が
食い違う報告が来たら、まずこのセクションを両方の端末で見比べること。

割合は UID 範囲ベースの目安であって件数比ではない (UID は削除・expunge
で歯抜けになる)。バックフィルは非表示メールボックスを対象にしないため、
この集計も同じ条件で除外する — 対象外のものを「未完了」として並べると
永久に減らない残件に見えてしまう。

**追記 (2026-08-08): 未読件数だけはこの依存から外した。** 実機報告「まだ
ローカルにない未読メールが検出できない」— 会社の Gmail アカウントで未読
件数が実際より少ない、という報告への対処。バックフィルは 1 パス 2 バッチ・
500 UID・5 分間隔なので、大きいアカウントでは事実上いつまでも追いつかず、
「いつか合う」に任せられる話ではなかった。

`UnseenSweeper` が `UID SEARCH UNSEEN`
(`IMAPSessionProtocol.searchUnseenUIDs`) の結果とローカルの行を突き合わせ、

1. ローカルに行が無い未読を**新しい順に**取り込む (1 回 500 件まで)
2. 取り切れなかった残りを `MailboxRecord.unseenNotFetchedCount` に残し、
   未読バッジはローカル集計にこれを足す (`MessageQuery.unreadCounts` /
   `unifiedInboxUnreadCount`)

`MailboxSyncer.incrementalSync` の最後で 15 分間隔 (`UnseenSweeper
.sweepInterval`) を上限に走る。`SEARCH UNSEEN` はサーバー側でメールボックス
全体を走査させるので毎回は投げられない。

設計上の注意点:

- **`STATUS` では代替できない。** MailCore2 の `folderInfoOperation`
  (`IMAPSession.status(_:)` の実体) が返すのは
  `UIDVALIDITY`/`UIDNEXT`/`HIGHESTMODSEQ`/メッセージ数だけで、`UNSEEN` は
  含まれない。`SEARCH` なら件数と「取るべき UID」が同時に得られる。
- **保存するのは「サーバーの未読総数」ではなく「未取得の残り」。** 総数を
  持つとローカルにある分を二重に数え、しかもユーザーが既読にしても減らない
  (減らないバッジは、少なく出るバッジより体験が悪い)。残りだけを足せば、
  ローカルでの既読は今までどおりそのままバッジを減らす。
- **Gmail の All Mail には足さない** (`MessageQuery
  .unseenNotFetchedIsCountableSQL`)。そこのバッジは「All Mail の未読」では
  なく「**アーカイブ済みの**未読」(`GmailArchiveFilter.excludeUnarchivedSQL`
  が受信トレイ等との重複を引く) なのに、`SEARCH UNSEEN` はその区別ができず
  受信トレイの未読まで数えてしまう。スイープ自体は All Mail でも走る —
  取り込めばローカル側の正しいフィルタが効くようになるので、抑えるのは
  取り込み前の推定値だけ。
- **未送信 op に守られている UID は残りに数えない** (実機報告「Gmail の
  メールを既読にしてアーカイブしたのにバッジが 1 のまま消えない」の修正)。
  既読化 (`setFlags`) とアーカイブ (`archive`) の op が replay されるまで、
  サーバーの受信トレイにはそのメールがまだ未読で居るので `SEARCH UNSEEN` が
  返す。一方ローカル行は `MessageRemoval.commit` が消しており、落とし穴 (m)
  の `PendingOpTargets` が作り直しもブロックする — つまり「行が無い」状態が
  op の replay まで続く。ここで数えると `unseenNotFetchedCount` が張り付き、
  **対応するメッセージ行がどこにも無いのでユーザーには消しようがない**
  バッジが残る (op が恒久失敗すれば永久に)。落とし穴 (m) の原則「未送信の
  ローカル変更がある UID については、サーバー側の状態はまだ古いと分かって
  いるので取り込まない」に対して、件数の側だけサーバーを信じる理由は無い。
- **op が消えたらスイープのゲートを開ける。** 上の裏返しで、op が replay
  されれば残数は測り直す価値がある。ところが `ReplayResult
  .affectedMailboxIds` は移動系の**移動元**を意図的に外している (直後に
  再同期するとサーバーの結果整合性で楽観的更新が巻き戻るため) ので、
  アーカイブ元の受信トレイは targeted resync に載らない。`OpQueueProcessor`
  は op を消すとき、その op がガードしていたメールボックスの
  `lastUnseenSweepAt` を `nil` に戻す (`PendingOpTargets.targetMailboxIds`)。
  外すのは 15 分ゲートだけで、`unseenNotFetchedCount` には触らない —
  実測は次の `incrementalSync` の仕事。
- **`uidValidity` が変わったら測定値ごと捨てる。** フル再同期は UID を全部
  振り直すので、旧世代の UID について測った残数は意味を失う。しかも
  `needsFullResync` 分岐はスイープに到達せず `return` するため、捨てないと
  古い値がそのまま書き戻される (`MailboxSyncer.performWindowedResync`)。
- **スイープの失敗は握り潰す。** 件数表示の補正であって同期そのものでは
  ないので、`SEARCH` を拒否する/未対応のサーバーで通常の同期まで落とさない。
  ただしその場合 `lastUnseenSweepAt` も `unseenNotFetchedCount` も更新され
  ないので、**残数は永久に古いまま**になりうる。定義を変えたときに既存端末を
  救う手段はマイグレーションしかない (v51 がその実例)。
- 検索結果が端末ごとに違う点 (この節の本文) は**変わっていない**。直したのは
  未読件数だけ。

### m. ローカルの変更は `opQueue` から消えるまでサーバー状態より優先する

実機報告 (2026-08-07)「受信箱のグループの画面で一括で Gmail をアーカイブ
した後、Gmail に移動して再読み込みするとまだ復活してしまう」の修正で
確立した規則。同期パスは `PendingOpTargets` を通し、**未送信の `opQueue`
op が対象にしている `(mailboxId, uid)` はサーバー由来のエンベロープ/
フラグで上書きしない**。

それまで同期は `opQueue` を一切見ていなかったため、次の順序で復活が
成立していた:

1. アーカイブすると `MessageRemoval.commit` が op を積み、ローカルの
   `message` 行を移動先へ仮配置 (pending relocation) するか、移動先が
   分からなければ消す (`MessageRemoval.destinationMailbox` の doc comment
   参照。Gmail は All Mail が移動先 — 下の「p.」節)。
2. その op がまだ replay されていない間、サーバーの受信トレイには
   そのメールがまだ居る。
3. 次の同期の `MailboxSyncer.applyFlagsDiffAndReconcileUnknown` が、
   サーバーにあってローカルに無い UID を「取りこぼし」とみなして
   エンベロープを取り直し `EnvelopePersister.upsert` する → 復活。

既読が未読へ巻き戻るのも同じ形 (`setFlags` op が未送信のうちはサーバーの
`\Seen` がまだ古い)。

**新しくサーバーからエンベロープを取り込むコードを書くときは
`EnvelopePersister.upsert` に `PendingOpTargets` を渡すこと。** 既定値は
`.none` (ガードしない) なので、渡し忘れるとこのバグが再発する。既存の
同期パスはすべて `PendingOpTargets.forMailbox(mailboxId:accountId:db:)`
の結果を、`write` ブロックごとに1回だけ組み立てて渡している (`opQueue`
が数千行溜まっている実機の状態でも、decode がメッセージ件数ぶん繰り返さ
れないようにするため)。

`uidValidity` が一致しない op はガードしない — replay 時に stale として
破棄される運命なので、ガードしてもサーバー状態の取り込みを無駄に遅らせる
だけになる。

恒久失敗した op が残っている間はその UID が復活しないままになるが、これは
「アーカイブしたつもり」というユーザーの意図と一致する側の挙動。取り消す
には設定 → 一般 →「操作同期の診断」の「未送信の操作を破棄」で `opQueue`
行を消す (次の同期でサーバーの状態が改めて取り込まれる)。

**この原則は「行を作るか」だけでなく「件数に数えるか」にも及ぶ。** 落とし穴
(l) の `UnseenSweeper` は当初、ここでブロックした UID を「ローカル行が無い」
として未読の残数に数えており、既読化 + アーカイブ直後のバッジが 1 のまま
消えないという実機バグになった (メッセージ行はどこにも無いので、ユーザーには
消す手段が無い)。サーバー由来の**状態**を信じないなら、サーバー由来の**数**
も同じ条件で信じないのが筋。逆に op が消えたときはガードが外れたということ
なので、`OpQueueProcessor` がその場でスイープのゲートを開ける
(`PendingOpTargets.targetMailboxIds`)。

**関連: 一括操作は「もう対象外」のスレッドを外す。** グループ行の一括
アーカイブ/既読は、既にアーカイブ済み/既読のスレッドを対象から外す
(`AccountDigestPresentation.bulkActionTargets`) — サーバーへ送っても何も
変わらない op を積むだけで、未送信 op が数千件まで膨らむ一因になっていた。

**フラグ系の未送信 op は、同一物理メッセージの*すべての行*を守る。**
Gmail の二重ラベルでは同じメールが INBOX と All Mail の2行として同期
される。`\Flagged`/`\Seen` はラベルではなく**メッセージ**に付くので、
片方の行に未送信の `setFlags` op があるなら、もう片方の行についても
サーバー報告のフラグは古い。`PendingOpTargets.forMailbox` は
`ThreadQuery.duplicateSiblingUIDs` で兄弟行を辿ってガードを広げる。

**移動系 (`archive`/`move`/`delete`/`junk`) は広げない** — 所属はラベル
ごとの性質で、Gmail のアーカイブは INBOX ラベルだけを外し All Mail 側の
行は残るのが正しい。ここまで広げると正しい行を消してしまう。この非対称は
`PendingOpTargetsTests` で明示的に固定してある。

### n. Liquid Glass のボタンは `contentShape` を明示する

実機報告 (2026-08-07)「右下の … ボタンを押しても何も出なくなっている」。

Liquid Glass Phase 1 で `OtegamiFloatingButtonChromeModifier` の `Circle()`
塗りを廃止した結果、speed-dial FAB (`MailScreenView.SpeedDialFAB`) には
不透明な背景が1つも無くなった。`.buttonStyle(.plain)` のヒットテストは
**描画された内容の形にそのまま従う**ため、当たり判定が「…」の点3つだけに
縮み、円の余白をタップしても何も起きなくなっていた。`glassEffect` が描く
ガラスは装飾であって、ヒットテストには寄与しない。

**`glassEffect(_:in:)` でボタンの見た目を作るときは、同じ形状を
`contentShape` にも与えること。** 見えている範囲とタップできる範囲は
自動では一致しない。

回帰テスト (`OtegamiSpeedDialFABUITests`) は**グリフに重ならない円の縁**
(正規化座標 0.2, 0.2) を突く — 円の中心はバグのある実装でも当たって
しまい、回帰を検出できない。

### o. Gmail の重複行はローカル状態も両方揃える

実機報告 (2026-08-07)「メールの unpin が反映されない」。**ピン留めは効く
のに解除だけ効かない**という非対称なバグだった。

Gmail の二重ラベルでは同じメールが INBOX と All Mail の2行として同期
される (`ThreadQuery.deduplicate(_:db:)` の doc comment)。行アクションの
対象解決 (`ThreadQuery.actionTargets(for:db:)` → `messages(threadId:db:)`)
は **dedup 済みの代表行しか返さない**一方、`ThreadRecord.isPinned` の
集約は **dedup 前の全行の OR** (`ThreadAssigner.recomputeAggregates`、
SQL 側も `MAX(message.isPinnedLocal)`) — 代表行だけ解除しても All Mail
側の行が `isPinnedLocal == true` のまま残り、OR が `true` を返し続けて
いた。付ける側は OR なので代表行だけで `true` になり、ちゃんと効いて
いるように見える。

**ローカル状態 (`isPinnedLocal`/`\Seen`) は物理メッセージの属性なので、
重複行にも同じ値を書くこと** — `MessagePinReadState` が
`ThreadQuery.duplicateSiblings(of:db:)` を使って揃える。サーバーへ送る
op は代表行のぶんだけでよい (Gmail のフラグはラベルではなくメッセージに
付くので、どちらのラベル経由で STORE しても両方に反映される)。

**追記 (2026-08-07、2度目の修正)**: 上のローカル整合だけでは実機で
直らなかった。同期側のガード (`PendingOpTargets`) が兄弟行をカバーして
いなかったため、揃えた直後にサーバーの `\Flagged` が All Mail 側の行を
`true` へ戻していたため。3つの層が同時に壊れていて、1つでも生きていると
ピンが残る:

1. **同期ガード** — All Mail の `(mailboxId, uid)` を守る op が存在しな
   かった (兄弟行の更新は意図的に op を積まないので)。→ §m の「フラグ系
   の未送信 op は同一物理メッセージのすべての行を守る」で解決。
2. **書き込み側** — `MessagePinReadState` が代表行の状態だけを見て早期
   `continue` していたため、「代表行は解除済み・兄弟行だけピンが残る」
   状態になると解除タップが**完全に no-op** になっていた。打ち切りの
   条件を「実際に DB を書いたか」へ変えた。
3. **集約** — 下記。

**スレッド集約 (`ThreadRecord`) の列は必ず dedup 後に計算する。**
`messageCount`/`unreadCount` は元から dedup 済みだったが、`isPinned` だけ
「MAX ベースなので重複に対して安全」という判断で生の OR だった。それは
二重カウントしないという意味であって、「片方の行だけ古い」状態には安全
ではない — 行アクションが触るのは dedup 済みの代表行だけなので、生の OR
はユーザーの操作を無効化する。`ThreadAssigner` の Swift パスと一括 SQL
パスの両方を dedup 済みへ揃え、既存 DB の値は v49 マイグレーション
(`recomputeAllAggregates`) で計算し直した (v35 が `messageCount`/
`unreadCount` に対して行ったのと同じ手順)。

### p. Gmail のアーカイブは「消す」のではなく All Mail へ仮配置する

実機報告 (2026-08-07)「iOS で Gmail のさっき受信したメールをアーカイブ
したらどこにも表示されなくなった」の修正で確立した規則。macOS では同じ
メールが正常に見えていた — サーバー側は正しくアーカイブされており、
**iOS のローカル DB からだけメールが消えていた**。

Gmail には `\Archive` 相当のフォルダが無く、「アーカイブ済み」の表示は
All Mail (role `.all`) 側の行が `GmailArchiveFilter.excludeUnarchivedSQL`
を通過することで成立している。そのため以前は INBOX の行を物理削除するだけ
だった。**この前提は「All Mail 側の行がローカルに存在する」ことに依存して
おり、それは保証されていない**:

- All Mail は `SyncScope.inboxOnly` の対象外。起動・フォアグラウンド復帰・
  push・IDLE ループはすべて `.inboxOnly` なので All Mail を触らない。
- All Mail が同期されるのは (a) その画面を開いている間の 5 分ループ
  (`MessageListView.syncSelectedMailboxOnAppear`)、(b) pull-to-refresh、
  (c) 低優先度の `BackfillSyncer` の 3 つだけ。
- 初回同期の窓は 500 通 (`AccountSyncer.initialSyncWindow`) なので、
  **アカウント追加後に届いた新着の All Mail 行は普通ローカルに無い**。

結果、受信トレイの行を消した時点でそのメールの最後の 1 行が消え、受信
トレイからもアーカイブの両ビューからも見えなくなっていた (古いメール、
つまり初回同期の窓に入っているものでは再現しないという非対称もこれで
説明がつく)。

現在は非 Gmail のアーカイブと同じ**擬似 UID 行への移送**
(`MessageRecord.isPendingRelocation`) を Gmail にも使う。ただし重複を
避けるため、移送するかどうかは `MessageRemoval.relocationDestinationId`
が**行ごとに**判断する:

- All Mail に同一メッセージの行が既にあるなら移送しない (物理削除)。
  グループ表示・スレッド詳細・スレッド集計はメッセージ同一性で重複排除
  するが、**フラット表示 (`ThreadQuery.flatSummaries` /
  `unifiedInboxFlatSummaries`) はしない**ので、実在行の隣に擬似行を置くと
  見た目の重複になる。同一性の判定は `ThreadQuery.identityKey` と同じく
  `gmailMessageId` (`X-GM-MSGID`) 優先、無ければ RFC 822 `Message-ID`。
- RFC 822 `Message-ID` を持たない行も移送しない。
  `EnvelopePersister.reconcilePendingRelocation` はこのヘッダでしか擬似行を
  引き当てられず、無いと本物の UID に昇格できないまま残り続けるため。
  Gmail 経由のメールでは極めて稀 (既知の制限)。

あわせて、Gmail のアーカイブ op は `ReplayResult.affectedMailboxIds` に
All Mail を含める。移動を伴わない (source を unlabel するだけ) op なので
以前は空だったが、擬似 UID 行を本物の UID に昇格させられるのは All Mail の
同期だけで、アーカイブ後に走る経路はどれも `.inboxOnly` だった。source
(INBOX) は従来どおり含めない。

**表示クエリに `uid > 0` を足さないこと。** `uid > 0` を要求してよいのは
同期カーソル (`MessageQuery.maxUID`/`minUID`) だけで、表示側に足すと擬似
UID 行が見えなくなりこのバグが即座に再発する。`GmailArchiveFilterTests`
に固定してある。

**同期スコープの role 読み替えを忘れないこと。** `.unifiedRole(role)` の
pull-to-refresh は `MailboxQuery.roleScopedMailboxPaths` を通す — Gmail の
「アーカイブ」の実体は All Mail なので `mailbox.role` を直接引くと 0 件に
なり、全メールボックス同期へフォールバックする。表示クエリ
(`ThreadQuery.unifiedInboxRequest`) と同じ規則を写しているので、**片方を
変えるときはもう片方も変えること**。

### q. `INImage` は `imageData:` ではなく `url:` で渡す — Release/TestFlight でだけ壊れる既知の不具合

Communication Notification (送信者アバター付きプッシュ通知、
`NotificationService/CommunicationNotification.swift`、
`docs/push-notification-actions.md`) の送信者アバターに
`INImage(imageData:)` を使うと、**Debug ビルドでは正常に動くが
Release/TestFlight ビルドではアバターが出なくなる**既知の不具合がある
(Apple Developer Forums thread 692707)。`INImage` が内部で生成する
`intents-remote-image-proxy` という URL の生成が Release ビルドでは
失敗する、という報告が広く一致している。回避策は `INImage(url:)` に
実ファイルの URL を渡すこと。

`SharedAvatarStore`
(`packages/OtegamiKit/Sources/PushRelayClient/SharedAvatarStore.swift`)
がアプリ本体の解決済みアバターを (`UserDefaults` に画像データを積む
のではなく) わざわざファイルとして App Group 共有ディレクトリへ書き
出しているのは、この既知の不具合を最初から踏まないため — `INImage` を
新しく使うコードを書くときは、必ず `url:` イニシャライザを使うこと。
**Debug ビルド/シミュレータでの動作確認だけではこの不具合を検出できない**
(`imageData:` でも Debug では正常に見える) — 実害は Release 署名の
ビルドでしか再現しない、という点が最も踏み抜きやすい落とし穴。

あわせて、この共有ファイルは
`.completeFileProtectionUntilFirstUserAuthentication` で書き込む。
既定の保護クラス (`.none` 相当) のままだと、端末がロックされている間は
`NotificationService` Extension がこのファイルを読めず、「ロック画面の
通知にだけアバターが出ない」という気付きにくい欠落になる —
`KeychainCredentialStore` が資格情報に `kSecAttrAccessibleAfterFirstUnlock`
を使っているのと同じ理由 (Known pitfalls e. の `0xDEAD10CC` とは別の話で、
こちらはファイルの読み取り可否そのものの問題)。

### r. IMAP の同時接続数はアプリ側で数えないと誰も数えていない

Gmail は 1 アカウントあたりの IMAP 同時接続を 15 本に制限しており、
超えると `LOGIN` の応答で `Too many simultaneous connections` を返す。
MailCore2 はこれを `MCOErrorGmailTooManySimultaneousConnections`
(`MailCoreErrorDomain` の code 8) にする。実機で
「本文の取得に失敗しました: serverError: … (MailCoreErrorDomain エラー 8)」
として現れた。

踏み抜きやすいのは次の 3 点。

**1. 独立にセッションを張る箇所が 12 ある。** IDLE ループ、初回同期、
差分同期、opQueue replay、本文/添付/raw source の取得、統合受信トレイの
先読み、古メールのバックフィル、一覧・検索時の先読み、サーバーサイド
SEARCH、プッシュ通知アクション、接続テスト、通知拡張 (別プロセス)。
これらは互いに直列化されていないので、フォアグラウンド復帰の 1 回で
同時に走りうる。とくに `CIDSchemeHandler` は cid インライン画像 1 件
ごとに `Task` を起動するため、画像の枚数がそのまま接続数になった。

**2. `MCOIMAPSession` 1 個は物理接続 1 本ではない。** MailCore2 の
`maximumConnections` の既定は 3 (`MCIMAPAsyncSession.cpp`) で、
放っておくと論理セッション 1 本が物理接続 3 本まで広がる。本数を数える
側から見ると 3 倍ずれる。`MailCoreIMAPSession.init` はこれを 1 に固定
している。

**3. `PooledIMAPSessionFactory` は本数を制限する仕組みではなかった。**
名前に反して、当初の役割は「直近の 1 本を TTL 付きで再利用する」だけで、
`checkout` が空振りすれば無条件に新しい接続を張っていた。現在は
アカウント別のスロット (`defaultMaxConcurrentConnections`、既定 4) と
FIFO の待ち行列を持つ。設計上の要点:

- スロットは「プールが握っている実接続 1 本」。`giveBack` でアイドルに
  戻っただけでは解放しない — サーバーから見れば接続はまだ生きている。
- 使用中のセッションが返却されたとき待ち手がいれば、アイドルに寝かせず
  接続ごと引き渡す。寝かせるとスロットが空かないまま接続が誰にも使われ
  ない、という取り違えが起きる。
- 上限を 4 にしているのは、プールを通らない接続 (IDLE、通知拡張、接続
  テスト) と、ユーザーが他のメールクライアントや Gmail の Web UI で同じ
  アカウントを開いている可能性の分を残すため。

**エラーの分類も分けてある。** code 8 を `.serverError` に丸めると
3 か所が誤った扱いをする — `SyncFailureClass` が per-operation と分類して
op が `attempts` を使い切り恒久失敗する (アーカイブが永久に届かなくなる)、
プールが `[LIMIT]` 文字列にマッチしないので詰まった接続を再利用する、
`BodyFetcher.attemptSelfHeal` が UID の陳腐化と誤認してメッセージを
ローカルから消しうる。`MailTransportError.tooManyConnections` として
切り出してあるので、新しい「接続レベル」のエラーを足すときも
`.serverError` に入れないこと。

### s. スナップショットしたレコードを全列 UPDATE で書き戻さない

`BodyFetcher.performFetch` は本文取得の前に撮った `MessageRecord` を
握り続け、それを `update(db)` で書き戻していた。GRDB の
`MutablePersistableRecord.update(db)` は**全列**を書くので、取得の最中に
別の経路がその行を更新していると、その更新ごと巻き戻る。

実際に起きたのがこれ。本文取得中にユーザーがアーカイブすると
`MessageRemoval.commit` が `mailboxId`/`uid` を仮配置 (`uid = -messageId`、
上記 b.) へ書き換えるが、直後の全列 UPDATE がそれを元に戻して INBOX の行を
復活させていた。`PendingOpTargets` (上記 m.) は同期による復活を防ぐが、
これは同期ではなく直接 UPDATE なのでガードを通らない。

結果として All Mail の行と復活した INBOX の行が同居し、
`ThreadQuery.isThreadArchived` (1 通でも archived なら true) は
「アーカイブ済み」バッジを出す一方、一覧クエリ (1 通でも INBOX にあれば
表示) は消さない。さらに詳細画面のアーカイブボタンは `isThreadArchived` を
見て `.unarchive` に化けるため、押しても逆操作になり「アーカイブできない」
状態が続いた。

規約として:

- 変えたい列が決まっているなら `update(db, columns: [...])` で絞る。
- 複数列をまとめて更新するなら、書き込みトランザクションの**中で**
  `fetchOne` して読み直した行に対して適用する (`BodyFetcher` の成功パスと
  `attemptSelfHeal.repoint` がこの形)。
- 読み直しで行が消えていた場合の後始末も書く — 親行のない本文が残ると、
  同じ `messageId` が再利用されたときに他人の本文を表示しかねない。

### t. MailCore2 セッション破棄のレース (v1.14.2 UAF クラッシュ)

v1.14.2 の実機 TestFlight クラッシュログ (メインスレッドで SIGSEGV、他
3 スレッドが `performMethodOnDispatchQueue` でメイン待ち) から特定した
use-after-free。`MailCoreIMAPSession.swift` の `deinit`/`SessionLingerBox`
にある。

**根本原因**: `~IMAPAsyncConnection` (mailcore2) は `mQueue
->setCallback(NULL)` を呼ばずに自身の callback オブジェクトを解放する。
一方 op queue (`OperationQueue`) は参照カウントで接続本体より長生きし、
`stoppedOnMainThread` で残 op があれば `startThread` →
`queueStartRunning()` を経由してその**解放済み callback** を呼び出す。
このアプリの `MailCoreIMAPSession` は使い捨て接続を毎回
`connect` → 数コマンド → `disconnect` (`Task` 内、fire-and-forget) する
運用なので、`disconnect()` から `Task` が終わった直後に `deinit` が走り
うる — mailcore2 自身の非同期な teardown コールバックが届く前に、
それを受け止める `MCOIMAPSession` が消えてしまう。

**v1.3.4 の対策 (`SessionLingerBox`) がなぜ不十分だったか**: deinit で
`MCOIMAPSession` への強参照を握り続け、`DispatchQueue.main.asyncAfter
(deadline: .now() + 5)` で 5 秒後にメインキューから解放する、という「賭け」
だった。`OperationQueue::stoppedOnMainThread` は `dispatch_sync` で
メインキューへ来るため、メインスレッドが輻輳しているとキューに積まれた
順序が保証されない — `asyncAfter` で予約された解放ブロックが、先に積まれた
はずの `stoppedOnMainThread` の `dispatch_sync` を**追い越して**実行され
うる。v1.14.2 の実クラッシュはまさにこの追い越しが起きたケース (メイン
スレッドが混雑、解放が先に走って `MCOIMAPSession` が消えた後に
`stoppedOnMainThread` が届いた)。

**v1.14.2 で入れた対策 (3点、`MailCoreIMAPSession.swift`/
`IMAPSessionPool.swift`/`AccountSyncer.swift`)**:

1. **セッション専用 serial dispatch queue が本命の修正。**
   `MailCoreIMAPSession.init` で per-session の serial `DispatchQueue` を
   作り、`session.dispatchQueue` に設定する (`MCOIMAPSession` は既定で
   メインキューに全コールバックを流す — ここを空けるだけで v1.3.4 の
   バグの土台ごと無くなる)。**必ず init 内・最初の接続前に**セットする
   必要がある — `IMAPAsyncSession::session()`
   (`MCIMAPAsyncSession.cpp`) が接続オブジェクト生成時に
   `mDispatchQueue` を**その時点の値をコピー**するため、後から差し替えても
   間に合わない。`SessionLingerBox` の解放も同じキューの `asyncAfter` に
   乗せる — serial queue は投入順に実行されるので、`deinit` で積む解放
   ブロックは、その時点までにキューに積まれていた mailcore2 自身の
   teardown 処理より**構造的に必ず後**に実行される。メインキューを経由
   しなくなる副作用として、`MCOIMAPOperation` の completion callback が
   メインスレッド以外から呼ばれるようになるが、`runCancellable`/`runVoid`
   はスレッド非依存の `withCheckedThrowingContinuation` を使っているので
   影響しない。
2. **quiesce ポーリング + linger 延長 (保険)。** 解放前に
   `MCOIMAPSession.isOperationQueueRunning` を確認し、`true` ならさらに
   5 秒後に再確認 (最大 3 回) してから解放する。初回待ちも 5 秒 → 15 秒に
   延長した。対策 1 が入っていればこの分岐はほぼ発火しない想定 — per-
   session queue 自体が異常に詰まっている場合のみの保険。
3. **`disconnect()` の取りこぼしを塞ぐ。** `MailCoreIMAPSession
   .disconnect()` は以前「成功した接続」(`connected == true`) だけを
   `disconnectOperation()` にかけていたため、`connect(auth:)` が
   TCP/TLS まで進んで `LOGIN` で失敗したケースは一度も明示的な
   `disconnectOperation()` を通らず `deinit` 任せになっていた。
   `connectAttempted` (接続を試みたかどうか、成否を問わない) をゲートに
   変更し、接続試行が一度でもあれば必ず切断を試みるようにした。加えて
   `IMAPSessionPool.swift` (`fresh.connect` 失敗時、再利用セッションの
   張り替え時) と `AccountSyncer.swift` (IDLE ループが `connectWithRetry`
   成功後に `listMailboxesCached`/`select`/IDLE ストリームのどこかで
   失敗する経路) それぞれで、それまで `disconnect()` を一度も呼ばずに
   セッション参照を手放していた箇所に明示的な `disconnect()` 呼び出しを
   足した。呼び出し元の `Task` が既にキャンセルされている経路
   (`stopIdleLoop()` など) から呼ばれると、素直に `await
   session.disconnect()` と書いても内部の `runVoid` がキャンセルを継承
   して disconnect オペレーション自体が送信されずに終わる
   (`MCOperation::cancel()` はフラグを立てるだけで送信済みでない
   オペレーションを握り潰す) — これを避けるため、これらの追加
   disconnect 呼び出しはすべて `Task.detached` から行っている。

**実機 UAF はユニットテストでは再現できない** (mailcore2 の C++ 側の
参照カウント/スレッドタイミングに依存するため)。ユニットで検証したのは
挙動の周辺 (`PooledIMAPSessionFactoryTests`: 接続失敗時・張り替え時に
`disconnect()` が呼ばれること、`AccountSyncerAuthFailureCooldownTests`:
IDLE ループが `connect` 後の失敗でもセッションを disconnect すること) —
per-session queue と quiesce ポーリングそのものは実機での長期運用でしか
確認できない、既知の限界として残る。

### u. mailcore2 の quoted-printable エンコーダは裸 CR で出力を壊す

pin している mailcore2/libetpan の quoted-printable エンコーダは、LF を
伴わない裸 CR (`\r` 単独) の直後で出力を壊す。実測 (2026-08、CR 改行の
本文を転送した実メールで発覚・ローカル再現も確認済み):

```
入力:  ...\r</p><p>高木...          (高 = E9 AB 98)
期待:  ...=0D</p><p>=E9=AB=98...
実際:  ...=0D/p><p>\xE9=E9=AB=98... (直後の '<' を落とし、
                                     マルチバイト先頭バイト \xE9 を
                                     生のまま複製挿入)
```

生の `\xE9` の次のバイトは UTF-8 の継続バイトにならないため、HTML パート
全体が不正 UTF-8 になる。受信側 (このアプリ自身を含む多くのクライアント)
は charset=utf-8 のデコードに失敗して Latin-1 にフォールバックし、**本文
全体が文字化けする** (1 バイトの破損が全文に波及する)。

防御は 3 層 (すべて 2026-08 の同じ修正で導入):

- `MailCoreMessageBuilder` — 送信境界で `htmlBody` の CRLF/CR を LF に
  正規化してから mailcore2 に渡す (最終防衛線。`MessageBuilderTests
  .bareCarriageReturnsInHtmlBodyStayValidUTF8` がピン留め)。
- `ReplyQuoter` (OtegamiCore) — 返信・転送の `> ` 引用組み立てで、行分割
  前に改行を LF に正規化 (CR 改行の本文だと引用が先頭行にしか付かない
  バグの修正を兼ねる)。
- `RichTextAttributedString.makeDocument` — `paragraphRange(for:)` は
  LF 以外に CR / CRLF / U+2029 でも段落を区切る (U+0085 / U+2028 は
  区切らない — 実測) のに終端除去が LF のみだったのを修正。

メール本文以外で mailcore2 に文字列を渡す経路を新設するときは、裸 CR が
混入しないことを送信境界で保証すること。
