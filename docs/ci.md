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

macOS/iOS 両方のビルドステップには
`OTHER_SWIFT_FLAGS="-Xfrontend -warn-long-expression-type-checking=300
-Xfrontend -warn-long-function-bodies=300"` を渡している —
「SwiftUI ビューの型チェックタイムアウト」節参照。300ms を超えた式/関数本体は
ビルドを失敗させずビルドログに warning として出るだけなので、通常の PR
ワークフローには影響しない。

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
  `xcodebuild` を `error: No profiles for 'com.mtkg.otegami' were
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

## 既知の落とし穴: SwiftUI ビューの型チェックタイムアウト (2026-07-25)

上記の修正で緑になった後も、`ci-app` が 5 回連続で以下のエラーで落ち続けた:

```
apps/Otegami/Sources/Features/Sidebar/SidebarView.swift:160:37: error: the
compiler is unable to type-check this expression in reasonable time; try
breaking up the expression into distinct sub-expressions
```

原因はソース側にあった (ワークフロー定義は無関係): `SidebarView` のアカウント
別メールボックス一覧を描画する `ForEach` の中身 — ネストした `ForEach` +
`Button` + `HStack` + 条件分岐 (`if let`) + `.buttonStyle`/
`.listRowBackground`/`.accessibilityIdentifier` という modifier チェーンが
1 つの巨大な式になっていて、Swift の型推論がオーバーロード解決の組み合わせ
爆発を起こしていた。**この開発チームのローカルマシンは高速で `make mac`/
`make ios` が普通に通ってしまうため、ローカルでは一切気づけない** —
CI ランナー (このワークフローでは `macos-26`) は同じ Xcode/Swift
ツールチェーンでもローカルより低速で、同じ式の型チェックが「reasonable
time」の閾値を超えて実際にコンパイルエラーになる。

最初の対処 (第1弾) は `SidebarView.swift` に `MailboxRow` (1 行分を独立した
`View` 構造体に切り出す) を作るだけだった。ローカルでは `make mac`/`make
ios` が通り、`-warn-long-expression-type-checking=300`/`=50` のどちらでも
警告ゼロになったので、これで直ったと判断して push した。**それでも
`ci-app` は同じ行・同じエラーで落ち続けた。**

原因を突き止めると、この開発機のローカル Xcode は 27.0 (beta) だったのに
対し、`ci-app` (macos-26 ランナー) は Xcode 26.5 を使っていた ——
**単に「ローカルは速いマシン」なのではなく、型チェッカーの実装そのものが
バージョンによって違う** ため、ローカルで ms 単位の計測がどれだけ小さくても
CI の (おそらくより古い/オーバーロード解決アルゴリズムが違う) コンパイラで
同じ結論になる保証がない、という一段厳しい教訓だった。`MailboxRow` に
切り出しても、それを呼び出す `body` の `ForEach` クロージャ自体が
「`if let` 束縛 + 複数引数の initializer 呼び出し + 2 文からなるインライン
trailing closure」を1つの式のまま抱えていて、それだけで CI 側には
まだ重すぎた。

第2弾の対処 (`mailboxRow(for:in:)`) は `ForEach` クロージャの中身を
`@ViewBuilder` メソッドに丸ごと追い出し、タップハンドラのインライン
クロージャも `handleMailboxSelected(_:)` という named メソッド参照に
置き換えた — `ForEach` のクロージャ自体を「ただの関数呼び出し1つ」まで
削ぎ落とすことで、クロージャリテラルの型推論すら発生しない形にした。
これで実際に `ci-app` が緑になった。

このバージョン差に気づいた時点で、「ローカルでの ms 計測は当てにならない
可能性がある」という前提に切り替え、同じ形 (`ForEach` の中に `if let` +
複数引数の view initializer + 複数の trailing-closure modifier が
1 つの式として積み重なっている) を持つ他のビューも予防的に洗い出して
分割した:

- `MessageListView.body` の `ForEach` (`Button` + `ThreadRow` + 2 つの
  `.swipeActions` + macOS 限定の `.contextMenu` + `.onAppear` — 元の
  `SidebarView` の行より大きかった): `threadRow(for:)` + 新設
  `MessageListRow` に分割。
- `ThreadDetailView.body` の `ForEach` (`if let` + ネストした2つ目の
  条件束縛 + 3引数の `MessageView` initializer + modifier チェーン):
  `messageRow(for:containerSize:)` + 新設 `ThreadMessageRow` に分割。
- `OtegamiApp.swift`'s `RootView.body` (`NavigationSplitView` の3カラム
  閉包 + 長い modifier チェーン) も同じ形だったので
  `splitView`/`sidebarColumn`/`contentColumn`/`detailColumn`/
  `navigationView`/`navigationViewWithFocusedValues` という複数の
  computed property に分割済み。
- `MailboxSyncFailuresView` の `ForEach` 行も確認したが、複数引数の
  カスタム view initializer も trailing-closure の modifier チェーンも
  無く、他の3つより明確に小さいため、今回は分割せず残した (危険度が低いと
  判断)。

**教訓 (今後 SwiftUI ビューを書く/レビューするときに思い出すこと)**:

- ローカルで `make mac`/`make ios` が通っても、CI の遅いランナー/古い
  ツールチェーンで型チェックがタイムアウトすることがある。「ローカルで
  緑 = 安全」ではない。**「ローカルで診断フラグの警告がゼロ」ですら
  安全の証明にはならない** — ローカルとCIでXcode/Swiftのバージョンが
  違えば、型チェッカーの挙動自体が違いうる (`xcodebuild -version` で
  ローカルと `.github/workflows/ci-app.yml` が動く `macos-26` ランナーの
  バージョンを見比べる習慣をつけること)。
- ネストした `ForEach`/`Button`/`HStack`/条件分岐/長い modifier チェーンが
  1 つの式に積み重なっている SwiftUI ビューは、型チェッカーへの負荷が
  非線形に増える。**行/セルの単位で `View` 構造体に切り出す**だけでは
  不十分なことがある — その `View` を呼び出す `ForEach`/`List` 側の
  クロージャ自体も、`if let` 束縛や複数引数の initializer 呼び出しを
  抱えたままなら再び同じ崖に立つ。**呼び出し側のクロージャも
  `@ViewBuilder` メソッドに追い出し、タップハンドラ等のインライン
  クロージャは named メソッド参照 (`onTap: handleFoo` であって
  `onTap: { x in ... }` ではない) に置き換える**のが最も確実。
  `NavigationSplitView` の各カラム閉包や長い modifier チェーンも、
  computed property (`some View`) に分割すると効果がある。
- 見た目やアクセシビリティ識別子を変えずに構造だけ変える場合、既存の
  XCUITest (`scripts/verify-ios-m*.sh`) をローカルで回して回帰がないか
  必ず確認する。
- 危険な箇所を洗い出すには、診断フラグを使う (ただし上記の通り、これは
  「怪しい箇所の当たりをつける」補助であって、ローカルで警告ゼロ =
  CI で安全、を保証するものではない):
  ```
  xcodebuild ... OTHER_SWIFT_FLAGS="-Xfrontend -warn-long-expression-type-checking=300 -Xfrontend -warn-long-function-bodies=300"
  ```
  同じ形 (ネストした `ForEach` + 条件分岐 + 複数引数 initializer +
  trailing closure) を持つコードは、診断フラグが何も引っかからなくても
  構造的にレビューして分割を検討する価値がある。
  ローカルの速いマシンでは閾値を下げないと何も引っかからないことがある
  (今回は 50ms まで下げて洗い出した)。`ci-app.yml` には 300ms 閾値の
  診断フラグを恒常的に有効化してあり、危険な式が増えたら PR のビルドログに
  warning として現れる (ビルド自体は失敗させない — `-warnings-as-errors`
  にすると無関係な既存 warning まで全部ビルド失敗にしてしまうため、まずは
  可視化のみ。CI ランナーごとの速度ばらつきに対してこの閾値がどれくらい
  安全か実績が積めたら、error 化を再検討する)。
