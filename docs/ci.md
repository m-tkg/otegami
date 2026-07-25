# CI (GitHub Actions)

`.github/workflows/ci-app.yml` (macOS runner) と `.github/workflows/ci-server.yml`
(Linux コンテナ) が `main` への push と全 pull request で走る。両方とも
「ビルドが壊れていないこと」と「ネットワーク/Docker に依存しない単体テストが
通ること」だけを検証する — 実機/シミュレータでの UI 挙動や、実際のメール
サーバーとの結合動作は別の場所 (後述) でしか検証していない。

## ci-app が検証すること

1. `xcodegen generate` でプロジェクトファイルを生成できること。
2. **macOS**: `xcodebuild ... -destination 'platform=macOS' build` が
   `CODE_SIGNING_ALLOWED=NO` (署名なし) で通ること。
3. **iOS**: `xcodebuild ... -destination 'generic/platform=iOS Simulator' build`
   が同じく署名なしで通ること (どの実機/シミュレータにもインストールしない
   ビルドのみの検証 — `generic` destination なのでシミュレータを起動する
   必要すらない)。
4. `packages/OtegamiKit` の `swift test` (`make test` と同じ内容 — 196件
   ほどのユニット/シナリオテスト。`MailTransportMailCoreTests` は
   `OTEGAMI_TEST_IMAP_HOST` 環境変数が無いと自動的に skip されるので、CI
   では実行されない)。

### ci-app が検証しないこと

- **実 Xcode 署名・配布可能性**: CI ランナーには配布用の証明書/
  プロビジョニングプロファイルが無い (意図的に置いていない — Client ID や
  署名鍵などの秘密情報を CI に持ち込みたくない)。`CODE_SIGNING_ALLOWED=NO`
  はビルドが通ることしか保証せず、実機にインストールできる署名済み
  バイナリが作れることは保証しない。
- **XCUITest (`OtegamiUITests`)**: `dev/mailstack` (Docker 上の
  Dovecot/Mailpit) との接続、実際のタップ操作、画面キャプチャによる目視
  確認が必要で、GitHub Actions の macOS ランナーで Docker + 起動済み
  シミュレータ + XCUITest を安定して回すのは現実的でない (時間・
  シミュレータの機種可用性・過去に遭遇した simulator/toolchain 固有の
  タップ配信バグなど、`.claude/skills/verify/SKILL.md` 参照)。これらは
  ローカルの `scripts/verify-ios-m*.sh` (`docs/verify.md` 参照) が担当する。
- **実 Google OAuth / iCloud サーバーとの通信**: `GoogleOAuthTests` は
  `URLProtocol` スタブと `FakeAuthorizationFlow` で完結しており、実
  Google サーバーにも実 Keychain にも触れない (これは CI でも実行される
  が、「本物の OAuth フローが動く」ことまでは保証しない)。

## ci-server が検証すること

1. `swift build` (Debug) がコンテナ内で通ること。
2. `swift test` が通ること。

### ci-server が検証しないこと

- **Docker 統合テスト**: `otegami-relay` の実運用相当の検証 (APNs 送信、
  実 SQLite ファイルでの永続化、`docker-compose` 経由の起動) はここでは
  行わない。
- **本番イメージのビルド**: `server/otegami-relay/Dockerfile` 自体の
  `docker build` は CI に含めていない (このプロジェクトの手動デプロイ
  フローに合わせて `make relay-docker` 等で個別に確認する想定 —
  `docs/relay-deployment.md` 参照)。

## トラブルシュートの経緯 (2026-07-25)

CI は M0 でワークフローを作って以来、一度も緑になっていなかった。原因は
2つ、ワークフロー定義側の問題で、アプリ/サーバーのソース側には問題は
無かった:

- **ci-app**: `project.yml` の `CODE_SIGN_STYLE: Automatic` が、CI
  ランナーに証明書もプロビジョニングプロファイルも無いため
  `xcodebuild` を `error: No profiles for 'com.m-tkg.otegami' were
  found` で失敗させていた。`CODE_SIGNING_ALLOWED=NO` /
  `CODE_SIGNING_REQUIRED=NO` / `CODE_SIGN_IDENTITY=""` をビルド設定に
  渡すことで解決 (署名を要求せず、ビルドの成否だけを見る)。
- **ci-server**: コンテナイメージが `swift:6.0-jammy` だったが、
  `packages/OtegamiKit` が依存する GRDB.swift (および Hummingbird,
  swift-nio 等の推移的依存) の `Package.swift` が
  `// swift-tools-version:6.1` を宣言しており、Swift 6.0 のツールチェーンは
  6.1 のマニフェストをパースできず `swift build`/`swift test` が依存解決の
  段階で `error: Dependencies could not be resolved because 'grdb.swift'
  ... contains incompatible tools version` として失敗していた
  (`otegami-relay` 自身は `OtegamiRelayAPI`/`OtegamiCore` しか使わないが、
  SwiftPM は依存グラフ全体のマニフェストを解決時にパースするため、
  実際に使わない GRDB 依存でも影響を受ける — `Dockerfile` のコメント
  参照)。本番用 `Dockerfile` が既に `swift:6.2-jammy` を使っていたので、
  CI のコンテナタグもそれに合わせて `swift:6.2-jammy` に上げて解決した。

修正後、`gh run watch` で ci-app / ci-server 双方が緑になることを確認済み。
