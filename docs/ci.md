# CI (GitHub Actions)

`.github/workflows/ci-app.yml` (macOS ランナー) と
`.github/workflows/ci-server.yml` (Linux コンテナ) が `main` への push と
全 pull request で走る。両方とも「ビルドが壊れていないこと」と
「ネットワーク/Docker に依存しない単体テストが通ること」だけを検証する —
実機/シミュレータでの UI 挙動や、実際のメールサーバーとの結合動作は別の
場所 (後述) でしか検証していない。

TestFlight への配布は GitHub Actions ではなく Xcode Cloud を使う、独立
した別のパイプライン — [docs/xcode-cloud.md](xcode-cloud.md) 参照。

## ci-app が検証すること

1. `xcodegen generate` でプロジェクトファイルを生成できること。
2. **macOS**: `xcodebuild ... -destination 'platform=macOS' build` が
   `CODE_SIGNING_ALLOWED=NO` (署名なし) で通ること。
3. **iOS**: `xcodebuild ... -destination 'generic/platform=iOS Simulator' build`
   が同じく署名なしで通ること (どの実機/シミュレータにもインストールしない
   ビルドのみの検証 — `generic` destination なのでシミュレータを起動する
   必要すらない)。
4. `packages/OtegamiKit` の `swift test` (`make test` と同じ内容。
   `MailTransportMailCoreTests` は `OTEGAMI_TEST_IMAP_HOST` 環境変数が
   無いと自動的に skip されるので、CI では実行されない)。

macOS/iOS 両方のビルドステップには `OTHER_SWIFT_FLAGS="-Xfrontend
-warn-long-expression-type-checking=300 -Xfrontend
-warn-long-function-bodies=300"` を渡している —
「SwiftUI ビューの型チェックタイムアウト」節参照。300ms を超えた式/関数
本体はビルドを失敗させずビルドログに warning として出るだけなので、通常の
PR ワークフローには影響しない。

CI ランナーには配布用の証明書/プロビジョニングプロファイルを意図的に
置いていない (Client ID や署名鍵などの秘密情報を CI に持ち込みたくない
ため)。`CODE_SIGNING_ALLOWED=NO` はビルドが通ることしか保証せず、実機に
インストールできる署名済みバイナリが作れることは保証しない。

### ci-app が検証しないこと

- **実 Xcode 署名・配布可能性**: 上記の理由により対象外。
- **XCUITest (`OtegamiUITests`)**: `dev/mailstack` (Docker 上の
  Dovecot/Mailpit) との接続、実際のタップ操作、画面キャプチャによる目視
  確認が必要で、GitHub Actions の macOS ランナーで Docker + 起動済み
  シミュレータ + XCUITest を安定して回すのは現実的でない (時間・
  シミュレータの機種可用性・既知のシミュレータ不調など、
  [docs/verify.md](verify.md) 参照)。これらはローカルの
  `scripts/verify-*.sh` が担当する。
- **実 Google/Microsoft OAuth・iCloud サーバーとの通信**: OAuth 関連の
  単体テストは `URLProtocol` スタブとフェイクの認可フローで完結しており、
  実サーバーにも実 Keychain にも触れない (CI でも実行されるが、「本物の
  OAuth フローが動く」ことまでは保証しない)。

## ci-server が検証すること

1. `swift build` (Debug) がコンテナ内で通ること。
2. `swift test` が通ること。

### ci-server が検証しないこと

- **Docker 統合テスト**: `otegami-relay` の実運用相当の検証 (APNs 送信、
  実 SQLite ファイルでの永続化、`docker compose` 経由の起動) はここでは
  行わない。
- **本番イメージのビルド**: `Dockerfile` 自体の `docker build` は CI に
  含めていない。手動デプロイフローの一部として個別に確認する
  ([docs/relay-deployment.md](relay-deployment.md) 参照)。

## 設定上の注意点

- **署名を要求しない**: `project.yml` の既定 (`CODE_SIGN_STYLE:
  Automatic`) のままだと、証明書もプロビジョニングプロファイルも無い CI
  ランナーでは `xcodebuild` が `No profiles for ... were found` で失敗
  する。ビルド設定に `CODE_SIGNING_ALLOWED=NO` /
  `CODE_SIGNING_REQUIRED=NO` / `CODE_SIGN_IDENTITY=""` を渡し、署名を
  要求せずビルドの成否だけを見る。
- **Swift ツールチェーンのバージョン**: `packages/OtegamiKit` が依存する
  GRDB.swift・Hummingbird・swift-nio 等の推移的依存の `Package.swift` が
  要求する `swift-tools-version` より古いツールチェーンだと、実際に使わ
  ない依存であっても SwiftPM の依存解決自体が
  `contains incompatible tools version` で失敗する。`server/otegami-relay`
  自身は `OtegamiRelayAPI`/`OtegamiCore` しか使わなくても、SwiftPM は
  依存グラフ全体のマニフェストを解決時にパースするため影響を受ける —
  CI コンテナのタグは本番用 `Dockerfile` と同じ Swift バージョンに揃える
  こと。

## 既知の落とし穴: SwiftUI ビューの型チェックタイムアウト

`ci-app` は過去に、ローカルでは `make mac`/`make ios` が問題なく通り、
`-warn-long-expression-type-checking` の警告もゼロの状態で、次のエラーで
落ち続けたことがある:

```
error: the compiler is unable to type-check this expression in reasonable
time; try breaking up the expression into distinct sub-expressions
```

原因は、行を描画する `ForEach` の中身 — ネストした `ForEach` + `Button` +
`HStack` + 条件分岐 (`if let`) + 複数の modifier チェーンが 1 つの巨大な
式になっており、Swift の型推論がオーバーロード解決の組み合わせ爆発を
起こしていたこと。**この種の問題はローカルでは気づけないことがある** —
CI ランナーは同じ Xcode/Swift ツールチェーンでもローカルより低速なうえ、
**ローカルとCIでXcodeのバージョンが違えば型チェッカーの実装そのものが
違いうる**。単純に遅いから閾値を超えるのではなく、ローカルではそもそも
「reasonable time」に収まる式が、CI 側のコンパイラでは収まらない、という
ケースが実際に起きた。

最初の対処 (行を独立した `View` 構造体に切り出すだけ) では直らなかった。
その `View` を呼び出す `ForEach` クロージャ自体が、`if let` 束縛 + 複数
引数の initializer 呼び出し + 複数文からなるインライン trailing closure
を 1 つの式のまま抱えていたためで、それだけでもまだ重すぎた。実際に
効いたのは次の組み合わせ:

- `ForEach`/`List` クロージャの中身を `@ViewBuilder` メソッドに丸ごと
  追い出し、そのメソッドを呼ぶだけの単純な呼び出しにする (行を `View`
  構造体に切り出すのに加えて、それを**呼び出す側**のクロージャも分割
  する)。
- タップハンドラ等はインラインクロージャ (`onTap: { x in ... }`) では
  なく、named メソッド参照 (`onTap: handleFoo`) にする — クロージャ
  リテラルの型推論も型チェッカーが同時に解かなければいけない要素の一つ。
- 長い modifier チェーンや `NavigationSplitView` の複数カラム閉包は、
  1 つの続いた式ではなく computed property (`some View`) に分割する。

**教訓 (SwiftUI ビューを書く/レビューするときに思い出すこと)**:

- ローカルで `make mac`/`make ios` が通っても、**ローカルで診断フラグの
  警告がゼロであっても**、CI の別バージョンのツールチェーンで型チェック
  がタイムアウトすることがある。「ローカルで緑 = 安全」ではない。
- ネストした `ForEach`/`Button`/`HStack`/条件分岐/長い modifier チェーン
  が 1 つの式に積み重なっている SwiftUI ビューは要注意。行を `View`
  構造体に切り出すだけでは不十分なことがある — その `View` を呼び出す
  `ForEach`/`List` 側のクロージャ自体も分割する必要がある。
- 危険な箇所の当たりをつけるには診断フラグを使う (ただし上記の通り、
  ローカルで警告ゼロというだけでは CI での安全は保証されない):
  ```
  xcodebuild ... OTHER_SWIFT_FLAGS="-Xfrontend -warn-long-expression-type-checking=300 -Xfrontend -warn-long-function-bodies=300"
  ```
  ローカルの速いマシンでは閾値を大きく下げないと何も引っかからないことが
  ある。`ci-app.yml` には 300ms 閾値の診断フラグを恒常的に有効化してあり、
  危険な式が増えたら PR のビルドログに warning として現れる (ビルド自体
  は失敗させない — 既存の無関係な warning まで巻き込んでビルド失敗に
  したくないため、まずは可視化のみに留めている)。
- 見た目やアクセシビリティ識別子を変えずに構造だけ変える場合は、既存の
  `scripts/verify-*.sh` をローカルで回して回帰がないか確認する
  ([docs/verify.md](verify.md) 参照)。
