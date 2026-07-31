# 動作検証 (verify)

人間の手を借りず、シミュレータ/実ビルドに対する自動検証で挙動を確認する
方針。日々のオペレーション手順は `.claude/skills/verify/SKILL.md` に
まとまっている — このファイルはその前提となる「今のシミュレータ環境の
既知の不調」と「今ある検証スクリプトが何をカバーしているか」を記録する。
過去の調査セッションのログ (「Task #NN でこう調べた」という時系列の
narrative) は置かない — ここにあるのは現在も成り立つ事実だけ。

## 標準の検証手段: `scripts/verify-screen.sh` (タップ不要スクリーンショット)

「この画面はどう見えるか」を確認したいときの既定の手段。XCUITest ランナー
(`xcodebuild test`) を一切起動しない:

1. `xcodebuild build` (`build-for-testing` ではない — テストバンドル不要) で
   アプリだけをビルド。
2. 毎回 `simctl uninstall` してから `simctl install`。
3. `xcrun simctl launch` で起動。フィクスチャ選択は `AppEnvironment.init()`
   が読む DB 直接注入フラグ (`OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE` 等) を
   `SIMCTL_CHILD_OTEGAMI_UITEST_*` 環境変数として、画面遷移は
   `-uiTestsAutoAdvanceToContent`/`-uitestsOpenSettingsDirectly` を起動引数
   として渡す。
4. 数秒待って `xcrun simctl io screenshot`。

タップは一切経由しない。既定で `OTEGAMI_UITEST_DISABLE_AVATAR_SOURCES=1` /
`OTEGAMI_UITEST_DISABLE_NOTIFICATION_PERMISSION_REQUEST=1` も付与するので、
連絡先/通知の許可ダイアログもそもそも発生しない。

```sh
scripts/verify-screen.sh html-3        # フィクスチャ本文画面の例
scripts/verify-screen.sh list          # 統合受信トレイ
scripts/verify-screen.sh settings      # 設定画面
APPEARANCE=dark scripts/verify-screen.sh html-1   # ダークモードで開く
```

シナリオ一覧 (`html-0`〜`html-9`、`calendar-invite`、`quote-history`、
`message-source` 等、機能追加のたびに増える) と環境変数
(`SKIP_BUILD`/`ERASE_SIMULATOR`/`WAIT_SECONDS`/`APPEARANCE`/`SCREENSHOT_DIR`/
`BUNDLE_ID`/`IOS_SIMULATOR`) の詳細はスクリプト自身のヘッダコメント参照。

**画面の見た目を確認するときはまずこれを使うこと。** `xcodebuild test
-only-testing:OtegamiUITests` は「UI テストターゲットがビルドできること」
の確認と、アカウント/タップを必要としない一部テストの実行に留め、新しい
画面の見た目確認の主手段にはしない — 理由は次節の不調 (2)。

なぜ tap-free がデフォルトなのか: 下記の既知の不調 (2)(3) が、XCUITest の
タップ操作そのものとタップ後の許可ダイアログに起因するため、タップと
ダイアログの両方を経路から除けば両方とも自動的に回避できる。IMAP 接続不能
(不調 1) の対象外でもある — フェイクフィクスチャの DB 直接注入のみで、
実 IMAP 接続を一切経由しない。実際の同期挙動を確認したいときは、後述の
Dovecot 統合テストか、`make deploy-ota`/deploy-worktree 経由の実機確認に
頼ること。

## シミュレータの既知の不調 (4種)

この開発機 (Xcode-beta.app + iOS 27 beta シミュレータランタイム) では、
以下4種類の環境不調が繰り返し自動検証の足を引っ張ってきた。いずれも
**アプリのコードバグではない** — この開発機のシミュレータ/ツールチェーン
固有の問題と切り分け済み。エージェントがこのアプリの画面を確認するときは、
まずこの節を読むこと。

1. **シミュレータ内からの IMAP 接続が全滅する**
   (`接続に失敗しました: サーバーに接続できません。...
   MailCoreErrorDomain error 1.`)。ホスト macOS プロセスからの直接接続や
   シミュレータの Safari 経由の HTTP 接続は同じ `localhost` へ問題なく
   到達できるのに、アプリの `mailcore2` ソケット接続だけが一貫して失敗する
   (新規 `simctl create` した別デバイスでも再現)。iOS の「ローカル
   ネットワーク」プライバシー許可がこの beta ランタイムでは
   `simctl privacy grant local-network` によるプリオーソライズが効かない
   まま静かに拒否している線が最有力 (未確定)。`simctl privacy grant
   local-network`/`grant notifications` はどちらもこのランタイムでは
   `Operation not permitted` で失敗する。
   **回避**: IMAP 接続そのものを検証したいときはシミュレータを介さず、
   後述のホスト macOS プロセスとしての Dovecot 統合テストに寄せる。
2. **XCUITest のタップが一覧行→本文遷移で不達になる** — 未修正の `main`
   でも再現する toolchain 問題 (`messageList.list` の行をタップしても
   `htmlWebView` が現れない)。`row.coordinate(...).press(...)` のような
   ワークアラウンドでも安定しない。
   **回避**: `AppEnvironment.uitestDirectOpenThreadId`
   (`OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX` 環境変数) — DB 直接注入した
   フェイクメッセージへ、タップを経由せず `selectedThreadId` を直接セット
   して遷移する「直接遷移経路」。`scripts/verify-screen.sh` が標準的に使う。
3. **アバター解決の連絡先権限ダイアログが非決定的なタイミングで出て
   XCUITest の待機を潰す** — `simctl privacy grant contacts` による事前
   許可も確実には効かない。同じ理由で、アカウントが1件でもあれば起動直後に
   OS の通知許可ダイアログも出る。
   **回避**: `OTEGAMI_UITEST_DISABLE_AVATAR_SOURCES=1` (連絡先・Google
   プロフィール写真・Gravatar・企業ロゴ(BIMI/favicon) の4つの外部/権限系
   アバター解決を丸ごとスキップ) と
   `OTEGAMI_UITEST_DISABLE_NOTIFICATION_PERMISSION_REQUEST=1`。どちらも
   `scripts/verify-screen.sh` が既定で付与するので手で意識する必要は
   通常ない。
   **追加の不安定さ**: `simctl privacy <udid> grant contacts
   com.mtkg.otegami` というコマンド自体が、即エラーではなく無期限に
   ハングすることが複数回確認されている (30分以上応答なし)。特に他の
   `xcodebuild`/`simctl` ジョブが同じホストで並行実行されているときに
   再現しやすい傾向がある (確証は無い)。上記の回避フラグを付与していても
   `push-settings`/`settings` 系シナリオでこの `grant` 自体を呼ぶ経路が
   残っていると踏み得る — 発生したら次節の「粘らない」運用に従う。

   **裏付け (Task #213)**: 上記の疑いを裏付ける再現を確認した。新設した
   `push-diagnostics`/`push-diagnostics-populated`シナリオ (`push-settings`
   と同じく設定→一般→プッシュ通知経由) で、`OTEGAMI_UITEST_DISABLE_
   NOTIFICATION_PERMISSION_REQUEST=1`を付与済みにも関わらず「"Otegami"
   Would Like to Send You Notifications」ダイアログが2回連続で再現した。
   念のため既存の(未変更の)`push-settings`シナリオでも同条件で再現する
   ことを確認済み — このタスクで追加したコードが原因ではなく、
   「プッシュ通知」設定画面 (`PushNotificationSettingsView`) 配下へ
   タップ無し遷移するシナリオ全般に共通する既存の環境不調。ダイアログは
   画面下部だけを覆い、上部の主要な要素 (ヘッダ・フッタ・最初の数行) は
   隠れないため、スクリーンショットでの見た目確認自体は引き続き可能
   だった (このタスクの`push-diagnostics-populated`のスクリーンショットも
   ダイアログの外側に写った行だけで各`Outcome`ケースの表示を確認できた)。
   根本原因の追跡は行っていない — 「粘らない」運用のとおり。
4. **Foundation Models をシミュレータの `.app` プロセスから呼ぶと
   `LanguageModelError error -1` になる** — エンジン層自体はホスト macOS
   プロセスとしての `swift test` からは正常に動く。詳細・ガードレールの
   話は `docs/translation.md` 参照。
   **回避**: 翻訳 UI の見た目確認には `OTEGAMI_UITEST_FAKE_TRANSLATION=1`
   (`FakeTranslationService` に差し替え) を使う。オンデバイス翻訳が実際に
   成功する様子はシミュレータでは原理的に確認できない — 実機確認に委ねる。

### その他、頻発が確認されている不安定さ (上記4種ほど確定はしていない)

- `scripts/verify-screen.sh` の `xcodebuild build` ステップが、進捗も
  エラーも一切出さないまま数分〜無期限に無応答になることが複数回確認
  されている。他の `xcodebuild`/`simctl` プロセスが同じホストで並行実行
  されている状況 (このリポジトリは複数エージェントが同じ作業ツリー/
  シミュレータを共有して動くため頻繁に起きる) との相関は疑われるものの、
  `xcodebuild` を経由しない `simctl install`/`launch` 直叩きでも同じ症状が
  出た例があり、原因は「`xcodebuild` のビルドロック競合」だけでは説明
  しきれていない。`xcrun simctl list devices` のような軽い問い合わせは
  この間も即座に応答する (デーモン自体は生きている)。
- Simulator 関連のホストプロセス (`PosterBoard` 等) のクラッシュ
  レポーターダイアログがホスト画面前面に出て、`osascript`
  (`System Events`) 越しの自動操作を巻き込むことがある。
  `simctl io screenshot` 自体はその背後のシミュレータ画面を問題なく撮り
  続けるが、Simulator 側のレンダリング/ネットワーキングが不安定化して
  いる兆候として扱ってよい。
- Task #212 (`OtegamiM9PushSettingsUITests`、プッシュ通知トグルを`Toggle`
  化した回): トグルをタップした直後、アプリ自身が表示する `.alert`
  (資格情報送信の同意確認) を `waitForExistence(timeout: 10)` で待っても
  見つからず、そのまま`XCTAssertTrue`が失敗する事象を確認した。ただし
  実装のバグではない可能性が高い — 失敗時の画面録画を1コマ (0.5秒) 単位
  で確認すると、テスト自身がまだ同意アラートの確認ボタンを一度も
  タップできていない最初のポーリング開始時点 (タップから約1秒後) には
  既に**次段階の OS 通知許可ダイアログ**が表示済みだった。通知許可
  ダイアログは`enable()`が実際に走った後にしか出ない (=同意アラートの
  確認ボタンは既に押されていた) にもかかわらず、その確認ボタンをテスト
  コード自身が押した形跡はポーリングログ上に無い — この環境の
  XCTest ランナーが、アプリ自身が出す (Springboard 由来ではない)
  `.alert`を「割り込み」とみなして自動で解決してしまい、テストの明示的
  な`waitForExistence`/`.tap()`より先にボタンを押してしまっている疑いが
  強い。つまり実際の押下→同意→有効化フローそのものは最後まで走って
  いる (通知許可ダイアログの出現がその証拠) が、UITest のアサーション
  タイミングだけがそれに追いつけない。旧「有効にする」ボタン版の同じ
  `.alert`では起きていなかった不調のため、ボタン→トグル切り替えでこの
  自動割り込みを誘発しやすくなった何らかのタイミング差 (`Switch`自体の
  内蔵アニメーション/クイエセンス待ちなど) が疑わしいが未特定。深追い
  はしていない — 次の方針節に従う。

いずれも、この開発機のシミュレータ/ツールチェーン固有の環境不調として
扱い、根治を目指して深追いしない (次節の運用方針に従う)。

## 検証がエラーになったら: 粘りすぎない

**「シミュレータでエラーになる場合は頑張りすぎず人間に確認を任せて
ほしい」** — ユーザーからの明示指示。上記の不調に当たって
`scripts/verify-screen.sh`/XCUITest がエラーになった場合、**リトライは
1〜2回まで**。原因調査や別ワークアラウンドの試行錯誤で長時間沼らない
こと。1〜2回のリトライで直らなければ、それ以上は追わずに次の標準手順へ
切り替える:

1. **ユニットテスト (`make test`) とビルド (`make ios`/`make mac`) が
   緑であることを出荷条件として、OTA 配信はそのまま進める** —
   シミュレータでの見た目確認が取れないことを出荷ブロッカーにしない。
2. **ユーザーへの報告に「未検証」と明記する** — 確認できていないことを
   確認できたかのように書かない。どの画面/シナリオがシミュレータで確認
   できなかったか、何が原因と見られるか (上記のどの分類か) を具体的に
   書く。
3. **実機で何をどう見れば確認できるかを、ユーザー向けに箇条書きで渡す**
   — 画面遷移の手順・見るべき箇所・期待される見た目を、人間がそのまま
   実行できる形にする。

新しい不調に遭遇したときは、1〜2回の調査で追記できる範囲でこのファイルに
記録した上で、上記1〜3の手順に切り替えること。

## 単体テスト

```sh
make test
```

`packages/OtegamiKit` の `swift test`。`OtegamiCoreTests` / `OtegamiStoreTests`
(in-memory GRDB) / `SyncEngineTests` (`FakeIMAPSession` によるシナリオ
テスト) / `GoogleOAuthTests` (PKCE 既知ベクタ、`URLProtocol` スタブに
よる token 交換/refresh、`FakeAuthorizationFlow` — 実 Google サーバにも
実 Keychain にも触れない) / `PushRelayClientTests` (通知許可解決・
watch reconcile の差分計算ロジック) 等は常時実行。`MailTransportMailCoreTests`
は `OTEGAMI_TEST_IMAP_HOST` 環境変数が設定されている場合のみ実行される
opt-in の統合テストで、`make test`/CI には影響しない。

## IMAP 検証: 実 Dovecot 統合テスト (シミュレータを介さない)

上記の不調 (1) により、IMAP 接続そのものの検証はシミュレータを介さず
ホスト macOS プロセスとして行う:

```sh
make mailstack-up
OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter MailCoreIMAPSessionIntegrationTests
# 他にも SyncEngineIntegrationTests / SMTPIntegrationTests / SMTPAuthIntegrationTests /
# AttachmentFetcherIntegrationTests / DraftsSyncIntegrationTests など
make mailstack-down
```

- `packages/OtegamiKit` の `MailTransportMailCoreTests` ターゲット配下。
  同じ `MailCoreIMAPSession`/mailcore2 を使うが、シミュレータの
  プライバシー/ネットワーキング層を経由しないため不調 (1) の影響を
  受けない。
- 開発用アカウント: `test1@otegami.test` / `test1234` (INBOX に seed
  メッセージ数通)、`test2@otegami.test` / `test1234`。`make mailstack-seed`
  は INBOX だけを `doveadm expunge` してから re-seed する冪等処理 —
  Sent/Drafts/Trash 等の他メールボックスへの書き込みはマイルストーンを
  またいで蓄積し続ける (`dev/mailstack/data/` を消さない限り)。
- SMTP は Mailpit (`localhost:1025`、Web UI `:8025`)。AUTH 必須の
  第2 Mailpit (`localhost:1026`、`dev/mailstack/mailpit-auth/users.txt`)
  もある — 詳細は `docs/dev-mailstack.md`。
- `MailTransportMailCoreTests` ターゲット全体を `--filter` なしで並列
  実行すると、同じ実 Dovecot の INBOX を書き換えるスイート同士がレース
  して間欠的に失敗することがある。個別スイートを `--filter` で単独実行
  するか、ターゲット全体を回すときは `--no-parallel` を付けること。

## 検証運用ポリシー: 実機切り分け用の OSLog は `.notice` 以上で書く

実機の不具合を切り分ける目的の `Logger(...)` 計装は `.notice`/`.error`/
`.fault` を使うこと。設定アプリの「解析」→「診断データを共有」で取得する
`sysdiagnose`/`log collect` のログアーカイブには Apple の既定ポリシーで
`.debug`/`.info` レベルのログが含まれない — 実機のログを後から回収する
前提の計装が空振りになる。`.debug`/`.info` は「今まさに `log stream` で
見ている最中」専用と考える。

## macOS の実行時検証

`make mac` はビルド確認のみ。実際に起動して操作する検証
(`scripts/verify-macos-qa.sh`) は、このプロジェクトに macOS 用の
XCUITest ターゲットが無いため、`screencapture`/CGEvent ベースの
自前ドライバで行う:

- `open -n -a` でビルド済み `.app` を起動。
- クリック/ドラッグ/キー入力は CGEvent ベースの小さな `driver.swift`
  (scratchpad にその場でビルド) で駆動。`AXUIElementCreateApplication`
  でウィンドウの実座標を取得できるので、`screencapture -R<x,y,w,h>`/
  `sips --cropOffset` の計算に使う。
- 座標系の変換 (論理点 ⇔ 物理ピクセル、Retina は 2 倍) を毎回丁寧に
  行うこと — 誤ると無関係な場所をクリックし続ける。
- この開発機はユーザーの対話的デスクトップ環境を共有しているため、
  フルスクリーンの `screencapture` はユーザーの他のウィンドウ/ブラウザ
  タブを写し込むリスクがある。対象ウィンドウの位置/サイズを
  `osascript` で取得してから範囲指定キャプチャ (`-R`) を使うこと。

## スクリーンショットの撮り方: 永続状態か、遷移状態か

- **GRDB に永続化された画面** (アカウント一覧・メッセージ一覧など):
  XCUITest プロセス終了後にホストから撮って安全 — 冷起動でも同じ状態が
  再現する。`xcrun simctl launch --terminate-running-process booted
  <bundle id>` → 数秒待つ → `xcrun simctl io booted screenshot`。
- **永続化されない画面** (シート/ダイアログ/検索結果などのナビゲーション
  状態のみ): テスト完了後に撮ると既に閉じている。対象のテストメソッド
  自身が `Thread.sleep(forTimeInterval: 4)` などで画面を数秒保持し、
  ラッパースクリプトがテスト実行と並行するバックグラウンドサブシェルから
  同じ出力パスに1秒間隔で複数回スクリーンショットを上書きする方式を使う
  (単発の固定 `sleep` は xcodebuild/シミュレータ起動の揺らぎで対象画面の
  表示ウィンドウを外すことがある)。`scripts/verify-ios-m6.sh` 以降の
  スクリプトはこのパターンを使っている。

## 検証スクリプトを書く/直すときの現行の注意点

- **`simctl uninstall` は「フレッシュインストール」の代わりにならない
  場合がある**: Keychain と iCloud KVS (`NSUbiquitousKeyValueStore`) は
  アプリのコンテナ外に保存されており、`simctl uninstall` では消えない。
  `AccountCloudSyncEngine` のように起動のたびに iCloud KVS を reconcile
  する機能があると、前回の verify 実行が残したアカウントが「フレッシュ
  な」はずの起動で復元されてしまう。アカウント 0 件の起動を前提にする
  スクリプトは `simctl uninstall` ではなく `simctl shutdown` +
  `simctl erase` (+ 再 boot) を使うこと。
- **シミュレータビルドはデフォルトで iCloud KVS に一切参加しない**
  (`AppEnvironment.isCloudSyncPermittedOnThisBuild`) — 実機汚染
  インシデント (`docs/icloud-sync.md`) の再発防止のためのゲート。
  `scripts/verify-ios-cloud-sync-isolation.sh` はこれをアプリ内部の
  アサーションではなく、ホスト Mac 自身の `cloudd` 統一ログ
  (`log show --predicate 'eventMessage CONTAINS "iCloud.<bundle id>"'`)
  でコンテナアクセスが 0 件であることを確認する形で検証している —
  「アプリ内部からは正常に見えるが実際には実 iCloud に書き込んでいた」
  という汚染インシデントの性質上、アプリ内のログだけを見る検証では
  このクラスのバグを構造的に見逃すため。
- **複数フェーズにまたがる XCUITest は、可能なら1回の `xcodebuild test`
  呼び出し内 (`app.terminate()`/`app.launch()` で再起動) に収めること**
  — フェーズごとに別々の `xcodebuild test` 呼び出しでアプリを再
  インストールする設計だと、直前のフェーズがホスト側 (`sqlite3` 経由)
  で仕込んだ DB の変更をアプリが 0 件として観測する、原因未特定の
  シミュレータ固有の不調を踏むことがある。単一の `xcodebuild test`
  呼び出し内で完結する設計はこの影響を受けない。
- **`OtegamiUITests` の全件実行 (`-only-testing:` で絞らないフルスイート)
  の pass/skip/fail の全体像は現状把握されていない** — アカウント/
  mailstack に依存するテストは上記の不調 (1) を検出すると `XCTSkip` で
  自身を抜けるよう作られているが、実際にどのクラスが skip されるかまで
  棚卸しはできていない。`OtegamiUITests` はビルドが通ることの確認
  (`build-for-testing`) と、下記の個別スクリプトが `-only-testing:` で
  ピンポイントに叩くテストクラスの実行に使う — フルスイートの一括実行を
  検証の主手段にはしない。

## 検証スクリプト一覧 (`scripts/verify-*.sh`)

いずれも `-h`/ヘッダコメントに詳細な使い方・環境変数がある。表は
「何をカバーしているか」の索引。

| スクリプト | カバー範囲 |
| --- | --- |
| `verify-screen.sh` | タップ不要のスクリーンショット取得。標準の見た目確認手段 (上記参照)。 |
| `verify-ios-m1.sh` | 汎用 IMAP アカウント追加 → INBOX 初期同期 → オフライン永続。 |
| `verify-ios-m2.sh` | 本文の遅延取得・HTML 表示 (外部画像バナー)・オフラインでの本文再表示。 |
| `verify-ios-m3.sh` | 差分同期・フラグ同期・オフライン opQueue・フォアグラウンド復帰同期 (host `doveadm` と交互実行)。 |
| `verify-ios-m4.sh` | スレッディング (References/件名フォールバック)・スレッド一括既読・複数アカウント統合受信トレイ。 |
| `verify-ios-m5.sh` | 作成・返信・SMTP 送信・オフライン Outbox・Sent への IMAP APPEND (host は Mailpit REST API/doveadm)。 |
| `verify-ios-m6.sh` | アカウント種別選択・Gmail ボタンの Client ID 未設定時無効化・iCloud プリセットフォーム・「その他」経路の回帰。実 OAuth/iCloud 接続は対象外。 |
| `verify-ios-m7.sh` | FTS5 trigram 全文検索 + 短いクエリの LIKE フォールバック、統合受信トレイでの横断検索、空状態表示。 |
| `verify-ios-m8.sh` | 添付ファイルの受信・QuickLook プレビュー・cid インライン画像・作成画面での添付・送信後の Mailpit 確認。 |
| `verify-ios-m9.sh` | プッシュ通知オプトイン設定 UI (relay URL バリデーション、シミュレータでの `.noDeviceToken` グレースフルデグレード表示)。 |
| `verify-ios-push-simulated.sh` | `xcrun simctl push` で `.p8`/実機なしにペイロード注入し、`NotificationService` Extension の実プロセス起動〜IMAP 参照〜通知内容書き換えを検証。 |
| `verify-ios-icloud.sh` | iCloud KVS アカウント同期: entitlement 付き起動のクラッシュ無し、同期トグルの表示/既定値、トグル OFF→ON でのアカウント消失無し。実2台間の往復は対象外。 |
| `verify-ios-cloud-sync-isolation.sh` | シミュレータビルドが iCloud KVS/CloudKit に一切アクセスしないことを、ホストの `cloudd` ログで検証。 |
| `verify-ios-credential-recovery.sh` | レガシー Keychain service からのパスワード復旧、孤児アカウント ID への資格情報吸着。 |
| `verify-ios-account-edit.sh` | アカウント編集 (表示名変更、誤ったパスワードでの同期エラー表示等)。 |
| `verify-ios-account-reorder.sh` | アカウントの並び替えと、並び順が設定/ハンバーガー/その他の一覧に反映されること。 |
| `verify-ios-avatar-phase1.sh` | 設定の「メール一覧」内アバター関連トグル (連絡先の写真/Gravatar) の表示・操作。アカウント不要。 |
| `verify-ios-drafts-sync.sh` | 下書きの IMAP 同期 (Drafts への保存、`\Draft` フラグ、再開・編集)。 |
| `verify-ios-mailto.sh` | 外部アプリからの `mailto:` URL 起動 (`simctl openurl`) → Composer プリフィル。`com.apple.developer.mail-client` entitlement が無いと `mailto:` 自体が届かない (`lsd` が third-party ハンドラを登録しない) ので、entitlement 有効なビルドが前提。 |
| `verify-ios-b-html-render.sh` / `verify-ios-html-height.sh` | 実機フィードバックで見つかった特定 HTML フィクスチャの描画確認 (幅・高さ)。`verify-screen.sh` の `html-N` シナリオと同じ構造のアドホックスクリプト。 |
| `verify-qa-sweep-offline.sh` | オフライン状態での冷起動・既読化・削除など、雑な操作の組み合わせによる QA スイープ。 |
| `verify-macos-qa.sh` | macOS 実行時 QA (起動確認・sheet 表示・タブ切替など、CGEvent 駆動)。 |
| `verify-relay.sh` | otegami-relay の IDLE watch パイプラインを実 Dovecot に対してエンドツーエンドで検証 (`go run` → `POST /v1/watches` → `doveadm save` → push ログ)。 |

## 関連ドキュメント

- `.claude/skills/verify/SKILL.md` — このファイルの内容を踏まえた実務手順。
- `docs/translation.md` — Foundation Models の既知の制限、ガードレール。
- `docs/icloud-sync.md` — iCloud KVS 同期の設計、実機汚染インシデントの詳細。
- `docs/oauth-setup.md` — Gmail OAuth の実機での最終確認手順。
- `docs/relay-deployment.md` — otegami-relay のセルフホスト手順、実機での push 最終確認。
- `docs/architecture.md` — 同期エンジン等の恒久的な設計知見。
- `docs/dev-mailstack.md` — dev/mailstack (Dovecot/Mailpit) の構成。
