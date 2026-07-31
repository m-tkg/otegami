# リリース (タグ push): iOS → TestFlight / macOS → GitHub Release

リリースしたいコミットに `v` から始まる git tag (`v1.2.3` 等) を打って
push すると、2つの独立した CI パイプラインが並行して走る。

```
git tag vX.Y.Z && git push origin vX.Y.Z
  ├─ Xcode Cloud (Apple 側インフラ、docs/xcode-cloud.md)
  │    → iOS を Archive → TestFlight の内部テストグループに配布
  │
  └─ .github/workflows/release-macos.yml (GitHub Actions)
       → macOS を Archive → Developer ID 署名 → notarization
       → GitHub Release にビルド成果物 (.zip) を添付
```

両者は完全に独立 (同じ tag を見ているだけで、互いを呼び出したり待ち合わせ
たりしない)。iOS 側の設定・既知の注意点は [docs/xcode-cloud.md](xcode-cloud.md)
のまま — このドキュメントは macOS 側 (`release-macos.yml`) だけを扱う。

## トリガー

- **タグ push** (`v*`, 例 `v1.2.3`, `v1.2.3-beta.1`): ビルド成功後
  `gh release create` で GitHub Release を作成し、署名・notarize 済みの
  `Otegami.zip` を添付する。
- **`workflow_dispatch` (手動実行)**: GitHub の Actions タブから
  「Run workflow」で実行できる。tag を作らずにビルド・署名・notarize の
  一連の流れだけを試せる (Release は作成せず、ビルド成果物は
  workflow の Artifacts としてのみ残る、既定 14 日保持)。**タグを
  一度も打たずにこのパイプライン全体を検証できるようにするための
  仕組み** — 初回の実地検証はこちらを先に使うのが安全。

## 表示バージョンはタグから注入される (macOS のみ)

`apps/Otegami/Config/Shared.xcconfig` の `MARKETING_VERSION` は固定値
(`1.2.0` 等)。iOS の TestFlight 配布は数値のみの版数を要求するため、
リポジトリの既定値はその形を保つ必要がある。

一方 macOS のリリースビルドでは、この workflow が
`xcodebuild MARKETING_VERSION=<タグから導いた版数>` で上書きする —
タグ `v1.2.0-beta3` なら `CFBundleShortVersionString` は `1.2.0-beta3` に
なる。ビルド直後に Info.plist を読んで期待値と一致するか検証し、違えば
その時点で失敗させる (公証まで進んでから気付くと作り直しになる)。

理由は 2 つ:

- 配布物の表示バージョンとタグが食い違うと、どのビルドを触っているのか
  実機で判別できない。
- アプリ内アップデートチェック (下記「アプリ内アップデート」節) は
  `CFBundleShortVersionString` と Release タグを SemVer 比較する。固定値
  `1.2.0` のままだと `1.2.0 > 1.2.0-beta3` と判定され、beta を入れている
  のに「最新版です」と表示されてしまう。

iOS 側 (Xcode Cloud) はこの workflow を通らないので影響を受けない。

## 必要な GitHub Secrets

以下は登録済み (`gh secret list` で名前だけ確認可能、値はここに書かない):

| Secret | 用途 |
|---|---|
| `SIGNING_IDENTITY` | `codesign --sign` に渡す Developer ID Application 証明書の識別子 (例: `"Developer ID Application: 氏名 (TEAMID)"`) |
| `SIGNING_CERTIFICATE_P12_BASE64` | 上記証明書 + 秘密鍵の `.p12` を base64 エンコードしたもの |
| `SIGNING_CERTIFICATE_PASSWORD` | 上記 `.p12` のパスワード |
| `NOTARY_APPLE_ID` | notarization 用 Apple ID |
| `NOTARY_PASSWORD` | 上記 Apple ID の App 用パスワード (notarytool 用) |
| `NOTARY_TEAM_ID` | Apple Developer Team ID。署名・notarize 両方および entitlements のチーム識別子解決 (下記) に使う |
| `OTEGAMI_GOOGLE_CLIENT_ID` (任意) | Gmail OAuth の Client ID。登録済みなら「Generate Local.xcconfig from OAuth Client ID secrets」ステップがこの secret から `Config/Local.xcconfig` を生成し、配布ビルドで Gmail 認証が有効になる。**未登録でもビルドは失敗しない** — その場合は Gmail 認証ボタンが無効化された「素のビルド」になるだけ (`docs/oauth-setup.md`)。 |
| `OTEGAMI_MICROSOFT_CLIENT_ID` (任意) | Outlook/Office365 OAuth の Client ID。上記と同じ仕組み・同じ「未登録でも失敗しない」挙動 (`docs/oauth-setup.md`)。 |

この2つの Client ID secret が未登録だと、GitHub Release からインストール
した macOS ビルドは Gmail の「再認証」が常に `oauthUnavailable` で失敗する
(パスワード認証の IMAP/SMTP アカウント・iCloud は元々問題なく使える)。
「Generate Local.xcconfig from OAuth Client ID secrets」ステップ
(`xcodegen generate` の直前) が、登録済みの secret から値はジョブ内の
`Config/Local.xcconfig` (git 管理外、コミットもアーティファクト化もしない)
へのみ書き込む — `::add-mask::` でログへの出力も防いでいる。Xcode Cloud
(`ci_post_clone.sh`) 側も同種の変数マッピングを持つ。

## 署名の仕組み: なぜ `xcodebuild` 自身に署名させないか

`ci-app.yml` と同様に **`xcodebuild build` は
`CODE_SIGNING_ALLOWED=NO` の未署名ビルド**で行い、その後
`codesign` コマンドを直接使って Developer ID 証明書で署名し直す
2段階方式にした。

理由 (このセッションでローカル実機検証で確認済み): macOS ターゲットの
entitlements (`apps/Otegami/Config/Otegami-macOS.entitlements`) は
iCloud KVS (`com.apple.developer.ubiquity-kvstore-identifier`、
アカウントの iCloud 同期に使う) を含んでいる。`xcodebuild` 自身に
署名させようとすると:

- **Manual 署名** (`CODE_SIGN_STYLE=Manual` + `CODE_SIGN_IDENTITY` に
  Developer ID 証明書を指定) は、対応する provisioning profile が
  無いと `xcodebuild` が**ビルドを始める前に**
  `"Otegami" requires a provisioning profile with the iCloud feature`
  で即失敗する (このリポジトリの secrets には provisioning profile は
  含まれていないため、これは実際に踏む)。
- **Automatic 署名** (project.yml の既定) は profile の自動発行/取得に
  ログイン済み Apple ID セッションか App Store Connect API キーを要求する
  — どちらも GitHub Actions のランナーには無い (`-allowProvisioningUpdates`
  を付けても認証手段が無ければ同様に失敗する)。

未署名ビルド → 手動 `codesign` の経路なら provisioning profile を
一切要求しない (`codesign` は指定した証明書とentitlements plist を
そのまま署名に埋め込むだけで、profile とのマッチングを検証しない)。

### entitlements のマクロ解決が必要な理由

`Config/Otegami-macOS.entitlements` は**未解決のテンプレート**で、
iCloud KVS の値はリテラルの `$(TeamIdentifierPrefix)$(CFBundleIdentifier)`
という文字列のままになっている (`xcodebuild` が自分で署名するときに
初めてビルド設定から実際の値に置換する)。`codesign --entitlements` は
この置換を一切行わないため、このファイルをそのまま渡すと
文字通りの `$(TeamIdentifierPrefix)$(CFBundleIdentifier)` という
壊れた値が iCloud KVS の識別子として署名に埋め込まれてしまう。

ワークフローの「Resolve macOS entitlements」ステップが `sed` で
`$(TeamIdentifierPrefix)` → `<NOTARY_TEAM_ID>.` (末尾ドット込み、
Apple のビルド設定リファレンスどおり)、`$(CFBundleIdentifier)` →
`com.mtkg.otegami` (`Config/Signing.xcconfig` のコミット済み既定値
— GitHub Actions には `Config/Local.xcconfig` が存在しないので必ず
この既定値になる) に置換してから署名する。

## 検証状況

実タグ push による `release-macos` の実行は複数回グリーンで完走しており
(`gh run list --workflow=release-macos.yml`)、公開された各 GitHub Release
(`v1.2.0-beta2` 以降) には署名・notarize 済みの `Otegami.zip` が添付されて
いる。`codesign --verify --deep --strict`/`spctl -a -vvv` (Gatekeeper 判定)
も通ることを確認済み。

tag を打つ前に `workflow_dispatch` (手動実行) でこのワークフロー単体を
一度試すこともできる — Release を作らずに同じビルド/署名/notarize 経路を
確認できる。

## 失敗時の見方

- **「Check signing and notarization secrets」で失敗**: 上記 secrets の
  いずれかが未設定 (`gh secret list` で確認)。
- **「Build macOS app (unsigned)」で失敗**: アプリコード側のビルドエラー
  (署名とは無関係)。`ci-app.yml` の同名ステップと原理は同じなので、
  そちらが緑なのにこちらだけ落ちる場合は runner バージョンのズレ
  (`runs-on: macos-26` が退役している等) を疑う。
- **「Sign app bundle」で失敗**: 証明書のインポート
  (キーチェーンへの `security import`) が失敗しているか、
  `SIGNING_IDENTITY` の文字列が実際の証明書の Common Name と一致して
  いない可能性が高い。
- **「Notarize and staple」で失敗**: `NOTARY_APPLE_ID`/`NOTARY_PASSWORD`/
  `NOTARY_TEAM_ID` の組み合わせが誤っているか、hardened runtime
  (`--options runtime`) 抜けなど署名オプション不足。`xcrun notarytool
  submit` はログに詳細な reject 理由を返すので、ジョブのログをそのまま
  確認する。
- **「Create GitHub Release」で失敗**: 同じ tag の Release が既に存在する
  場合など (`gh release create` は既存タグに対して失敗する — 再実行する
  場合は先に `gh release delete` するか、新しいタグを打つ)。

## アプリ内アップデート (macOS のみ)

メニューバーの「Otegami」→「Otegamiについて」(`OtegamiCommands`の
`CommandGroup(replacing: .appInfo)`、標準の`NSApplication`About panel を
置き換え) が開く独立ウィンドウ (`AboutView`、`OtegamiApp`の
`WindowGroup(id: "about")`) の中に、バージョン情報と並んでアップデート
確認/インストール UI (`AboutUpdateSection`) が入っている。iOS はこの機能
を持たない (App Store/TestFlight 配布) — 関連コードはすべて
`#if os(macOS)`。

**ユーザーの明示操作でのみ実行し、自動更新はしない** — About を開いても
勝手にはチェックしない (`AboutUpdateSection`のトグル/ボタンはすべて
ユーザー操作起点)。「更新」ボタンを押してからの手順:

1. **ダウンロード** (`AppUpdateDownloader`): このワークフローが GitHub
   Release に添付する`Otegami.zip`(上の「必要な GitHub Secrets」節などが
   作る配布物そのもの) を一時ディレクトリへ取得する。ダウンロード元は
   GitHub のホストのみに制限し (`OtegamiCore`の`AppUpdateDownloadPolicy`)、
   **初回リクエストだけでなく `URLSessionTaskDelegate
   .willPerformHTTPRedirection` で受け取る全てのリダイレクト hop でも**
   同じチェックを通す — GitHub の Release アセットは実際には
   `objects.githubusercontent.com`系の署名付き URL へ 302 されるため、
   初回 URL だけの検証では不十分という前提。許可ホストは
   `github.com`/`api.github.com`(完全一致)と`*.githubusercontent.com`
   (サフィックス一致、ドット境界つき) のみで、`http`へのダウングレードも
   拒否する。
2. **検証** (`AppUpdateInstaller`、`OtegamiCore`の`ZipEntryPathValidator`/
   `CodeSignatureIdentity`/既存の`FileSystemPathContainment`を利用):
   - zip 展開前に `unzip -Z1` でエントリ名を列挙し、`../`を含む・絶対
     パス・`~`始まりのエントリが1つでもあれば展開自体を中止する
     (zip slip 対策 — SEC-A が添付ファイル名のパストラバーサルを直した
     のと同じ観点)。安全と分かってから初めて`ditto -x -k`で展開する。
   - 展開結果の `.app` バンドルのパスが、実際に展開先ディレクトリの
     子孫であることを`FileSystemPathContainment.isDescendant`で再確認
     する (SEC-A が同じ理由で追加したのと同じヘルパーの再利用 — 多層
     防御であり`ditto`だけを信頼しない)。
   - **署名の同一性**: 実行中のアプリ (`Bundle.main.bundleURL`) と展開後の
     候補アプリの両方に対して`codesign -dv --verbose=4`を実行し (この
     出力は**標準エラー**に出る点に注意)、`TeamIdentifier`と最初の
     `Authority=`行を`CodeSignatureIdentity`で抽出して比較する。**両方
     とも非nilで一致していること**が必須 — Team ID だけの一致では
     不十分とし (証明書の失効・別チェーンでの再取得等を想定した多層
     防御)、`Authority`文字列も合わせて見る。どちらかが unsigned/ad-hoc
     署名なら即座に不一致として扱う。
   - **Gatekeeper**: `spctl -a -vv --type execute`が候補アプリを受理する
     ことも要求する。
   - **これらのいずれかに失敗したら、一切コピー・置き換えを行わない**
     (`AppUpdateInstaller.InstallError`を投げてダウンロード用の一時
     ディレクトリごと破棄する)。
3. **書き込み権限チェック**: 実行中のアプリの親ディレクトリ
   (`/Applications`が典型) に書き込み権限が無ければ`.noWritePermission`
   を投げる。認証ダイアログ (`AuthorizationExecuteWithPrivileges`相当) を
   出す実装は複雑になるため今回は実装せず、**`AboutUpdateSection`側で
   Release ページを開く導線へフォールバックする**判断とした (書き込み
   権限が無い環境では、ユーザーに手動でのドラッグ&ドロップ更新を促す)。
4. **入れ替え** (`AppUpdateInstaller.swap`): 実行中のアプリを同じ
   ディレクトリ内の`<name>.old-<timestamp>`という一時名へ`moveItem`で
   退避 → 検証済みの候補アプリを元のパスへ`moveItem` → 成功したら退避
   コピーを削除、という順序。2番目の`moveItem`が失敗した場合は退避コピー
   を元の位置へ戻し、**アプリが消えたままの状態には絶対にならない**よう
   にしている。実行中のバンドルディレクトリ自体を丸ごと動かす操作は
   macOS/Darwin では安全 (実行中プロセスは既に開いている実行ファイルの
   ファイルディスクリプタ/マップ済みページをそのまま使い続けるため) —
   Sparkle 系の macOS 用アップデータが使うのと同じ性質。
5. **再起動**: 成功後、`AboutUpdateSection`が「今すぐ再起動」ボタンを
   表示する。`NSWorkspace.shared.openApplication(at:configuration:)`に
   `createsNewApplicationInstance = true`を指定して新しいプロセスを
   起動してから`NSApplication.shared.terminate(nil)`する (このフラグが
   無いと、同じ bundle identifier が「既に実行中」と判定され、まもなく
   終了する旧プロセスの方が再アクティブ化されてしまう)。「あとで」で
   閉じた場合、ユーザーが手動で再起動するまで新しいバージョンは使われ
   ない。

**検証状況**: `AppUpdateDownloadPolicy`/`ZipEntryPathValidator`/
`CodeSignatureIdentity`はそれぞれ`OtegamiCoreTests`の単体テストで検証済み
(ホスト許可リスト・zip slip判定・署名同一性比較の網羅的なケース)。About
画面を開いてアップデート確認 (「最新版です」まで) が動くことは確認済み。
**既知の制限**: 実際のダウンロード→展開→入れ替えという一連の流れ、
および本物のアプリの差し替えは、ユーザーの実アプリを壊すリスクがある
ため自動テストの対象外 — 新バージョンをリリースした際は、書き込み
権限が無い環境でのフォールバック、Gatekeeper 未承認/署名不一致時の
経路も含め、手動で一度確認すること。

## 関連ドキュメント

- [docs/xcode-cloud.md](xcode-cloud.md) — iOS 側 (Xcode Cloud →
  TestFlight)。同じ tag をトリガーにする独立したパイプライン。
- [docs/ota-deploy.md](ota-deploy.md) — App Store Connect を経由しない
  もう一つの配布経路 (Ad Hoc + itms-services、日々の開発ビルド用)。
  タグを打たない通常運用ではこちらを使い続ける。
- [docs/ci.md](ci.md) — `ci-app.yml`/`ci-server.yml` (ブランチ push /
  PR で走る、リリースとは別の CI)。
