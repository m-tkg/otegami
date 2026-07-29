# リリース (タグ push): iOS → TestFlight / macOS → GitHub Release

Task #143。リリースしたいコミットに `v` から始まる git tag (`v1.2.3` 等)
を打って push すると、2つの独立した CI パイプラインが並行して走る。

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

`OTEGAMI_GOOGLE_CLIENT_ID`/`OTEGAMI_MICROSOFT_CLIENT_ID` 等の OAuth
Client ID は意図的に設定していない — Xcode Cloud (`ci_post_clone.sh`)
と違ってこのワークフローに環境変数を渡す仕組みを用意していないため、
ビルドされる macOS 版は Gmail/Outlook/Office365 の追加ボタンが無効な
「素のビルド」になる (パスワード認証の IMAP/SMTP アカウント・iCloud は
問題なく使える)。将来必要になれば Xcode Cloud 側と同じマッピングを
このワークフローにも追加すればよい。

## 署名の仕組み: なぜ `xcodebuild` 自身に署名させないか

`ci-app.yml` と同様に **`xcodebuild build` は
`CODE_SIGNING_ALLOWED=NO` の未署名ビルド**で行い、その後
`codesign` コマンドを直接使って Developer ID 証明書で署名し直す
2段階方式にした。

理由 (このセッションでローカル実機検証で確認済み): macOS ターゲットの
entitlements (`apps/Otegami/Config/Otegami-macOS.entitlements`) は
iCloud KVS (`com.apple.developer.ubiquity-kvstore-identifier`、
M11 のアカウント iCloud 同期用) を含んでいる。`xcodebuild` 自身に
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

## ローカルで確認したこと・確認できていないこと

### 確認済み (このセッションでこのマシン上で再現)

- 未署名の `xcodebuild build` (Release, macOS destination) が成功する
  こと (`ci-app.yml`/`make mac` と同じフラグ)。
- `CODE_SIGN_STYLE=Manual` + Developer ID identity での署名は、
  provisioning profile が無いと `xcodebuild` の時点で
  `requires a provisioning profile with the iCloud feature` エラーに
  なること (このマシンにインストール済みの実 Developer ID Application
  証明書で再現)。
- 未署名ビルドした `.app` に対し、実 Developer ID Application 証明書 +
  マクロ解決済み entitlements で `codesign --force --deep --options
  runtime --timestamp --entitlements ... --sign ...` を実行すると成功し、
  `codesign --verify --deep --strict` が `valid on disk` /
  `satisfies its Designated Requirement` を返すこと。
- entitlements のマクロ置換ロジック (`sed` 2箇所) がダミーの Team ID で
  期待通りの文字列 (`<TEAMID>.com.mtkg.otegami`) を生成すること。
- ワークフロー YAML が構文的に妥当であること (`python3 -c
  "import yaml; yaml.safe_load(...)"`。`actionlint` はこの環境に
  未インストールで、未信頼の Homebrew tap 経由でしか入らなかったため
  導入は見送った)。

### 確認できていないこと (次回タグ push / workflow_dispatch で判明する)

- **notarization そのもの** — `xcrun notarytool submit --wait` は
  実際に Apple のサーバーと通信するため、この環境からは実行していない
  (実 Apple ID・実 Team ID を使い、ユーザーの notarization クォータを
  消費する操作になるため)。証明書のインポート (`security import` +
  `set-key-partition-list`) 自体も GitHub Actions のキーチェーン方式は
  `mytty` の実績パターンをそのまま踏襲しているが、この repo の証明書
  では試していない。
- **iCloud KVS entitlement が実際に「効く」か** — 上記の
  署名手順は `codesign --verify` が通る (=署名として正しい形式) ことは
  確認したが、embedded provisioning profile を持たない Developer ID
  署名の非 Sandbox アプリに対して、macOS が実行時に iCloud KVS の
  entitlement を実際に許可するかどうかは未確認。2つのシナリオが
  考えられる:
  1. 通常どおり動く — Developer ID・非 Sandbox アプリは多くの
     entitlement について profile なしでも OS 側のチェックが緩い。
  2. iCloud アカウント同期 (M11) だけがこの配布ビルドでは無言で
     動かない — 現在「Team ID が空 (未署名)」のローカルビルドで
     iCloud KVS が使えないのと同じ壊れ方で、アプリの他の機能
     (メール送受信・翻訳等) には影響しない。
  どちらであっても **notarization/Release 添付というパイプライン自体は
  失敗しない** (notarytool は entitlement の妥当性ではなく hardened
  runtime・タイムスタンプ・署名の整合性だけを見る) — あくまで
  「配布した .app で iCloud アカウント同期が実際に動くか」という
  アプリ機能面のリスクであり、リリース作業そのもののブロッカーには
  ならない想定。
- **GitHub Actions ランナー実機での挙動全般** — `runs-on: macos-26` は
  `ci-app.yml` が同じ設定で緑を継続しているため SDK/ツールチェーン面は
  流用できる想定だが、`release-macos.yml` 自体をこのランナー上で
  実行したことはまだない。

**次回タグを打つときの確認ポイント**:
1. Actions タブで `release-macos` の run が最後まで緑になるか
   (どのステップで落ちるかで切り分け — 証明書 import / codesign /
   notarize / GitHub Release 添付のどこかまでは事前検証済み)。
2. 緑になった場合、GitHub Release に添付された `Otegami.zip` を展開して
   `codesign --verify --deep --strict`、`spctl -a -vvv Otegami.app`
   (Gatekeeper 判定) が通るか。
3. 実際に別の Mac (この配布用証明書を持たないマシン) にコピーして
   起動できるか (Gatekeeper 越え = notarization が本当に効いている
   ことの実地確認)。
4. iCloud アカウント同期 (設定 → アカウント同期) が、この配布ビルドで
   ローカル署名ビルドと同じように動くか — 上記「確認できていないこと」
   の項目。動かない場合は entitlement 周りの追加対応 (例: Developer ID
   用の provisioning profile を新しい secret として追加する) が
   フォローアップとして必要になる。

まず tag を打つ前に `workflow_dispatch` (手動実行) でこのワークフロー
単体を一度試すことを推奨する — Release を作らずに同じビルド/署名/
notarize 経路を確認できる。

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

## 関連ドキュメント

- [docs/xcode-cloud.md](xcode-cloud.md) — iOS 側 (Xcode Cloud →
  TestFlight)。同じ tag をトリガーにする独立したパイプライン。
- [docs/ota-deploy.md](ota-deploy.md) — App Store Connect を経由しない
  もう一つの配布経路 (Ad Hoc + itms-services、日々の開発ビルド用)。
  タグを打たない通常運用ではこちらを使い続ける。
- [docs/ci.md](ci.md) — `ci-app.yml`/`ci-server.yml` (ブランチ push /
  PR で走る、リリースとは別の CI)。
