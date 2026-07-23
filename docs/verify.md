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

## macOS ビルド確認

```sh
make mac
```

M1 では macOS 側の UI 検証は必須ではない (計画書参照) が、ビルドが壊れていない
ことは毎回確認する。
