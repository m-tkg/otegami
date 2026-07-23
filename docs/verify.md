# 動作検証 (verify)

人間の手を借りず、シミュレータ/実ビルドに対する自動検証で各マイルストーンの
チェックポイントを確認する方針 (計画書「テスト戦略」参照)。ノウハウは
`.claude/skills/verify/SKILL.md` にも蓄積している。

## 単体テスト

```sh
make test
```

`packages/OtegamiKit` の `swift test`。`OtegamiCoreTests` / `OtegamiStoreTests`
(in-memory GRDB) / `SyncEngineTests` (`FakeIMAPSession` によるシナリオテスト) は
常時実行。`MailTransportMailCoreTests` は `OTEGAMI_TEST_IMAP_HOST` 環境変数が
設定されている場合のみ実行される opt-in の統合テスト。

## iOS シミュレータ検証 (M1)

```sh
scripts/verify-ios-m1.sh
```

実施内容:

1. `make mailstack-up` + `make mailstack-seed` で dev mailstack を用意。
2. 直前のインストールを `simctl uninstall` で削除し、ローカル DB をまっさらにする。
3. `xcodebuild build-for-testing` でアプリ + `OtegamiUITests` をビルド。
4. `OtegamiUITests` (XCUITest) を実行: アカウント追加フォームに Dovecot
   (`localhost:1143`, 平文, `test1@otegami.test`/`test1234`) を入力 →
   「接続テスト」成功を確認 → 保存 → 初期同期後、seed メール4通の日本語件名が
   INBOX 一覧に表示されることを `XCTAssert` で確認。
5. アプリを再起動してオンライン状態のスクリーンショットを撮影。
6. `make mailstack-down` でメールサーバーを止め、アプリを再起動 (オフライン)。
   一覧がローカル DB からそのまま表示され続けることをスクリーンショットで確認。
7. `make mailstack-up` でメールスタックを復元。

スクリーンショットは `SCREENSHOT_DIR` (既定 `/tmp/otegami-verify/`) に
`01-online-inbox.png` / `02-offline-inbox.png` として出力される。最終判定は
人間ではなく、この画像を読み取れる Claude 自身が行う想定 (計画書参照)。

### UI 操作の自動化について

`simctl` だけではテキスト入力やアクセシビリティ ID によるタップ操作ができない
(スクリーンショット/インストール/起動などのライフサイクル操作限定)。そのため
全 UI 要素に `accessibilityIdentifier` を付与し (`Sources/Features/**`
参照)、`apps/Otegami/UITests/` の XCUITest (`OtegamiUITests` スキームターゲット)
で操作する。詳細・ハマりどころは `.claude/skills/verify/SKILL.md` を参照。

## iOS シミュレータ検証 (M2)

```sh
scripts/verify-ios-m2.sh
```

実施内容:

1. `make mailstack-up` + `make mailstack-seed` で dev mailstack を用意
   (`seed.sh` は冪等化済み: 投入前に INBOX を空にするので、繰り返し実行しても
   重複しない)。
2. 直前のインストールを `simctl uninstall` で削除。
3. `xcodebuild build-for-testing` でアプリ + `OtegamiUITests` をビルド。
4. `OtegamiM2VerificationUITests` (XCUITest) を実行: M1 のヘルパー
   (`addDovecotTest1Account`, `UITests/DovecotAccountUITestHelpers.swift`)
   でアカウントを追加 → `restartAppToRecoverTouchDelivery` でアプリを
   再起動 (この simulator/toolchain 固有の既知の不具合の回避策。
   `.claude/skills/verify/SKILL.md` 参照) → HTML 専用 (プレーンテキスト
   パート無し) の日本語メール (`07-html-only-japanese.eml`) を開き、本文の
   日本語テキストが表示されることを確認 → 外部画像入り HTML メール
   (`06-html-external-image.eml`) を開き、「画像を表示」バナーが表示され、
   タップで消えることを確認。
5. オンライン状態のスクリーンショットを撮影。
6. `make mailstack-down` でメールサーバーを止める。
7. `OtegamiM2OfflineVerificationUITests` を実行: アプリを再起動し、
   直前に開いていたメッセージ (`RootView` の "lastOpenedMessage"
   `@AppStorage` 復元) の本文が、タップ操作なしにローカル DB だけから
   再表示されることを確認。
8. オフライン状態のスクリーンショットを撮影。
9. `make mailstack-up` でメールスタックを復元。

スクリーンショットは `SCREENSHOT_DIR` (既定 `/tmp/otegami-verify/`) に
`m2-01-online-message.png` / `m2-02-offline-message.png` として出力される。

### この環境固有の XCUITest タップ問題について

M2 の実装時、現在の開発機の toolchain (Xcode-beta.app + iOS 27.0 beta
シミュレータ) 固有と見られる複数の自動化バグに遭遇した (アプリのバグでは
ない — 標準的な SwiftUI コードで、安定版シミュレータや実機では発生しない
はずのもの)。具体的には account-setup シートの dismiss 後は全要素の
タップが `{-1, -1}` という無効な座標になる、`List(selection:)` がタップで
更新されない、`NavigationSplitView` がコンパクト幅で content→detail に
自動遷移しない、identifier ベースの要素検索が画面に見えている要素を
見つけられない、など。回避策と診断手法の詳細は
`.claude/skills/verify/SKILL.md` の「M2: この simulator/toolchain の
タップ配信バグ」節に記録した。

### メッセージ詳細画面の自動判定について

HTML メッセージは `WKWebView` (`messageDetail.htmlWebView`) で描画される。
WebKit のコンテンツはアクセシビリティツリー上に静的テキストとして
(段落ごと、または本文全体としてグルーピングされて) 現れるため、
`OtegamiM2VerificationUITests` は完全一致ではなく `label CONTAINS` の
`NSPredicate` で `app.staticTexts` を横断検索している。プレーンテキストの
メール (`messageDetail.plainTextBody`, SwiftUI `Text`) にも同じ判定方式を
使っているので、本文がどちらの表示経路を通っても同じアサーションで検証できる。

## macOS ビルド確認

```sh
make mac
```

M1 では macOS 側の UI 検証は必須ではない (計画書参照) が、ビルドが壊れていない
ことは毎回確認する。M2 の HTML 表示 (`HTMLMessageView`) も iOS/macOS 両方の
`#if os(...)` 分岐を実装しているが、自動 UI 検証は iOS シミュレータのみで
macOS 側はビルド確認 (`make mac`) までとしている (計画書のテスト戦略に準拠)。
