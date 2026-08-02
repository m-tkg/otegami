# デフォルトのメールアプリ対応

otegami を OS の「デフォルトのメールアプリ」に設定できるようにする対応の
記録。仕組み、Apple への entitlement 申請手順、承認後の有効化手順、
macOS 側の設定方法をまとめる。

## 全体像

「デフォルトのメールアプリ」に必要なものは iOS と macOS で異なる
(Apple の entitlement リファレンスで実際に確認済み — `com.apple.developer
.mail-client` の対応プラットフォームは **iOS/iPadOS/visionOS のみ**、
macOS は掲載されていない)。

| | 必要なもの | otegami での状態 |
|---|---|---|
| **両プラットフォーム共通の前提** | `Info.plist` に `mailto` スキームを宣言 (`CFBundleURLTypes`) + 実際に `mailto:` を開いて処理できること | 実装済み (`project.yml`、`OtegamiApp.handleOpenURL(_:)`) |
| **iOS/iPadOS** | 上記に加えて Apple が個別に許可する `com.apple.developer.mail-client` entitlement | ビルド時フラグで opt-in (既定オフ、後述) |
| **macOS** | 追加の entitlement 不要 — Launch Services が `mailto` を宣言した任意のアプリを候補として扱う (Mail.app の設定や、対応アプリの環境設定で選べる) | `CFBundleURLTypes` 宣言のみで足りる |

## 1. mailto: URL のハンドリング

- **`MailtoURLParser`** (`packages/OtegamiKit/Sources/OtegamiCore/MailtoURLParser.swift`):
  RFC 6068 に沿って `mailto:` URI をパースする純粋関数。`to`/`cc`/`bcc`
  (パス部分のカンマ区切りアドレスと `to=`/`cc=`/`bcc=` hfield の両方、
  カンマ区切りの複数値、パーセントデコード)、`subject`/`body` を
  デコードする。不正な入力 (壊れた `%` エスケープ、未知の hfield) は
  クラッシュせず安全に無視する。ユニットテスト:
  `packages/OtegamiKit/Tests/OtegamiCoreTests/MailtoURLParserTests.swift`
  (日本語 subject/body の UTF-8 パーセントエンコーディング往復を含む)。
- **`CFBundleURLTypes`** (`apps/Otegami/project.yml`): `mailto` スキームを
  宣言。iOS/macOS 両ターゲット共通の `Info.plist` プロパティなので両
  プラットフォームに効く。entitlement の有無に関わらずビルドに含まれる
  — これが無ければ entitlement を取得してもそもそも `mailto:` を
  受け取れない。
- **`OtegamiApp.handleOpenURL(_:)`** (`apps/Otegami/Sources/OtegamiApp.swift`):
  `.onOpenURL` で受けた URL を `MailtoURLParser` に渡し、成功したら
  `ComposerLaunchPayload.mailto(_:)` で作成画面をプリフィル表示する
  (`presentComposer(_:)` が iOS はシート、macOS は新規ウィンドウに
  ルーティングする既存の仕組みをそのまま使う)。`mailto:` 以外の URL
  (このアプリが登録していない他のスキーム) は黙って無視する。
- **`ComposerView` の Bcc 欄**: `mailto:` の `bcc=` を受け取る先として
  `bccText` フィールドを追加した。送信パイプライン自体
  (`OutboxMessageRecord.bccAddresses` → `OpQueueProcessor` の SMTP
  `RCPT TO`) は元々 Bcc 対応済みで、Composer の UI にフィールドが
  無かっただけ。**既知の制約**: 「下書きとして保存」は Bcc を保存しない
  (`DraftMessageRecord` に `bccAddresses` 列が無いスキーマ上の制約 —
  下書き保存への Bcc 対応は別スコープ)。送信取り消し中の一時保持
  (`PendingSendDraftSnapshot`、メモリ内のみ) は Bcc を保持する。

### 動作確認

**実機検証で判明した重要な事実**: Simulator 上で `xcrun simctl openurl
booted 'mailto:...'` を試すと、`OTEGAMI_MAIL_CLIENT_ENTITLEMENT` フラグが
`NO` (既定) のビルドでは **`CFBundleURLTypes` に `mailto` を宣言していて
も一切 otegami に届かない**。ログ (`log show --predicate 'eventMessage
CONTAINS "mailto"'`) で確認すると `lsd` (LaunchServices daemon) が
`ERROR: There is no registered handler for URL scheme mailto` を返して
おり、`mailto`/`tel`/`sms` のような予約スキームは通常の `CFBundleURLTypes`
宣言だけでは (entitlement 無しの) サードパーティアプリに一切登録され
ない — Apple のドキュメントの「iOS はデフォルトのメールクライアントを
起動する」という記述の実際の実装。`OTEGAMI_MAIL_CLIENT_ENTITLEMENT = YES`
でビルドし直すと (Apple の承認前でも、Simulator は provisioning を検証
しないためローカルで試せる)、直後から `simctl openurl` で otegami に
届くようになる。**つまりこの機能を Simulator で動作確認するには、一時的
にでもこのフラグを `YES` にしたビルドが必要** — `docs/default-mail-app.md`
のこの節は「フラグ無しで検証できる」という当初の想定を実測で修正した。

```sh
# Config/Local.xcconfig に OTEGAMI_MAIL_CLIENT_ENTITLEMENT = YES を追加
# → xcodegen generate → シミュレータへビルド・インストールしたうえで:
xcrun simctl openurl booted 'mailto:a@otegami.test?to=b@otegami.test&cc=c@otegami.test&bcc=d@otegami.test&subject=mailto%E3%83%86%E3%82%B9%E3%83%88&body=%E6%9C%AC%E6%96%87%E3%81%A7%E3%81%99'
```

`simctl openurl` は Springboard の「"Otegami" で開きますか?」という
確認アラート (`Open`/`Cancel`) を毎回はさむ (実際に他アプリ内の
`mailto:` リンクをタップした場合と同じ、非 http(s) カスタムスキームの
標準的な OS 挙動) — これをタップしてから初めて `OtegamiApp
.handleOpenURL(_:)` に URL が渡る。`scripts/verify-ios-mailto.sh` は
この確認アラートを XCUITest (`OtegamiMailtoUITests`、Springboard の
"Open" ボタンをタップ) で自動的にはさんで検証する。

作成画面が To に `a@otegami.test, b@otegami.test`、Cc に
`c@otegami.test`、Bcc に `d@otegami.test`、件名に「mailtoテスト」、
本文に「本文です」を入れた状態で開けば OK
(`scripts/verify-ios-mailto.sh`/`OtegamiMailtoUITests` で自動検証できる)。

## 2. `com.apple.developer.mail-client` entitlement (iOS/iPadOS)

### なぜビルド時フラグで opt-in にしているか

この entitlement は Apple が個別審査のうえ許可する managed entitlement で、
App ID に対して Developer Portal 側で capability を有効化してもらう
必要がある。**許可される前に entitlements ファイルへ書き込むと、
provisioning profile の生成に失敗してビルド/署名が壊れる**
(このリポジトリは entitlement 未承認の状態が長く続く前提の OSS なので、
これは避けたい)。

そのため、`Otegami.entitlements` に直接書かず、xcconfig の変数展開を
使った「間接参照」でどの entitlements ファイルを署名に使うか切り替える
構成にしている:

- `apps/Otegami/Config/Otegami-iOS.entitlements` — 既定 (この
  entitlement を含まない、現状のまま)。
- `apps/Otegami/Config/Otegami-iOS-MailClient.entitlements` — 上記と
  同じ内容 + `com.apple.developer.mail-client` = `true`。
- `apps/Otegami/Config/Shared.xcconfig` の `OTEGAMI_MAIL_CLIENT_ENTITLEMENT`
  (既定 `NO`) が、`OTEGAMI_IOS_ENTITLEMENTS_FILE_NO`/`_YES` のどちらを
  使うかを選ぶ。`project.yml` の
  `CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]`/`[sdk=iphonesimulator*]` は
  リテラルパスではなく `$(OTEGAMI_IOS_ENTITLEMENTS_FILE)` というマクロを
  参照しているので、`Config/Local.xcconfig` (git 管理外) でこの1行を
  上書きするだけで、`project.yml`/生成される `.xcodeproj` を一切
  変更せずに切り替えられる (`DEVELOPMENT_TEAM`/`PRODUCT_BUNDLE_IDENTIFIER`
  と同じパターン — `Signing.xcconfig` のコメント参照)。
- `project.yml` の `OtegamiMailClientEntitlementEnabled` Info.plist キーも
  同じフラグから導出される (`DefaultMailAppSettingsView` が読み、
  entitlement の無いビルドでは設定ショートカットの代わりに「Apple の
  承認待ちです」の案内を出す)。

### 申請手順 (Apple への entitlement 申請)

1. [Request a Mail App Entitlement](https://developer.apple.com/contact/request/default-mail-client/)
   を開く。
2. Account Holder ロールでサインインし、フォームに記入して送信する。
   要件 (Apple のドキュメントに明記): `mailto:` スキームを `Info.plist`
   で宣言していること (対応済み)、任意の宛先へ送信できること (対応済み)、
   任意の送信者からのメールを受信できること (対応済み — ユーザー制御の
   迷惑メールフィルタは許可されている)。
3. 承認を待つ (Apple 側のリードタイムは案件による)。**既知の制限**:
   この entitlement は Apple の個別承認制であり、承認されるまで
   `OTEGAMI_MAIL_CLIENT_ENTITLEMENT = YES` にした実機ビルドを配布する
   ことはできない (Simulator ではフラグを立てるだけでローカルに動作
   確認できる — 下記「動作確認」節参照)。

### 承認後の有効化手順

1. **Developer Portal で App ID の capability を有効化する** —
   developer.apple.com の Certificates, Identifiers & Profiles →
   Identifiers → 該当の App ID (`OTEGAMI_BUNDLE_ID`、既定
   `com.mtkg.otegami` — 実機ビルド用に独自の Bundle ID を使っている場合は
   そちら) → Capabilities で "Mail" (または同等の表記) を有効化する。
   自動署名 (`CODE_SIGN_STYLE: Automatic`) の場合、この操作をしておけば
   次の Xcode ビルドで provisioning profile が自動的に更新される。
2. **`Config/Local.xcconfig` にフラグを立てる** (無ければ
   `Config/Local.xcconfig.sample` からコピーして作成):
   ```
   OTEGAMI_MAIL_CLIENT_ENTITLEMENT = YES
   ```
3. `xcodegen generate` (`make ios`/`make ios-device` が自動で実行する) →
   実機ビルド。`Config/Otegami-iOS-MailClient.entitlements` が署名される
   ようになる。
4. 実機で確認: 設定 →「一般」→「デフォルトのメールアプリに
   設定」→「設定 App で既定のメールアプリを選ぶ」から
   `UIApplication.openDefaultApplicationsSettingsURLString`
   (iOS 18.3+) で「設定」アプリの既定アプリ選択画面が開くこと、
   otegami が候補に出ること、選択後に他アプリの `mailto:` リンクが
   otegami で開くことを確認する。

## 3. macOS の設定方法

macOS は entitlement 不要 (前述の通り Apple のドキュメントに macOS の
掲載が無い) — `CFBundleURLTypes` の宣言だけで Launch Services が
otegami を `mailto:` ハンドラの候補として認識する。ユーザーが実際に
選ぶ方法はどちらか:

- **Mail.app**: 「メール」→「設定」→「一般」の「デフォルトのメール
  アプリ」ポップアップから otegami を選ぶ。
- **システム設定**: macOS のバージョンによっては「システム設定」→
  「デスクトップと Dock」の「メールアプリ」項目からも変更できる。

`DefaultMailAppSettingsView` (設定 →「一般」→「デフォルトの
メールアプリに設定」) の macOS 側はこの案内文言を表示するだけ —
`openDefaultApplicationsSettingsURLString` は UIKit (iOS/iPadOS/Mac
Catalyst/tvOS/visionOS) のみで、素の AppKit ターゲットである otegami の
macOS ビルドには使えないため、直接開くボタンは用意していない。

## 参考

- [com.apple.developer.mail-client (Apple Developer Documentation)](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.mail-client)
- [Request a Mail App Entitlement](https://developer.apple.com/contact/request/default-mail-client/)
- [openDefaultApplicationsSettingsURLString (Apple Developer Documentation)](https://developer.apple.com/documentation/uikit/uiapplication/opendefaultapplicationssettingsurlstring)
