# アプリ UI のローカライズ (表示・操作改善バッチ)

アプリ UI を「システムに従う / 日本語 / English」から選べるようにした
バッチの記録。設定項目自体は [docs/settings.md](settings.md#表示言語-表示操作改善バッチ)
参照 — このドキュメントは仕組みとローカライズの到達範囲を扱う。

## 仕組み

- **String Catalog** (`apps/Otegami/Resources/Localizable.xcstrings`,
  `sourceLanguage: "ja"`)。このアプリの UI コードは最初から日本語の文字列
  リテラルを直接 `Text`/`Button`/`Label` 等に書いている
  (`Text("すべての受信トレイ")`のように) — ソース言語を日本語にしたことで、
  この**既存のコードを一切変更せずに**、その日本語リテラル自体が String
  Catalog のキーとしてそのまま機能する。`en` の翻訳をカタログに追記する
  だけで、該当する `Text`/`Button`/`Label` 呼び出しは自動的にローカライズ
  される。
- **`apps/Otegami/project.yml`**: `options.developmentLanguage: ja`、
  `Otegami` ターゲットの Info.plist に `CFBundleLocalizations: [ja, en]`
  を追加。`xcodegen generate` 後、`Localizable.xcstrings` はビルド時に
  `en.lproj/Localizable.strings` へコンパイルされる (Xcode 標準の動作、
  手動のビルド設定は不要 — `Resources/`配下に置くだけで拾われる)。
- **`LocalizationSettingsStore.swift`** (`apps/Otegami/Sources/Support/`):
  ユーザーの選択 (`AppLanguageOption`: `.system`/`.japanese`/`.english`)
  を保存し、`AppleLanguages`(`UserDefaults`の標準キー、`Bundle.main`の
  ローカライズ解決がプロセス起動時に読む) を書き換える。**アプリ内即時
  反映ではなく再起動が必要** — SwiftUI の `Text(LocalizedStringKey)`
  解決は起動時にロードされた `Bundle` のローカライズに紐づいており、
  `.environment(\.locale, ...)` を注入するだけでは文字列カタログの参照先
  までは切り替わらないため (実際に試して確認済み — 環境注入だけでは
  `Text`の表示は変わらなかった)。
- **`LocalizationSettingsStore.effectiveLanguageCode`**: 「今実際にどの
  言語で表示されているか」を`"ja"`/`"en"`で返す。`.system`のときは
  `Locale.preferredLanguages`から解決する。本文画面の翻訳ボタンの表示
  条件 (`MessageView.shouldShowTranslationBar`) と AI要約の出力言語判定
  (`MessageView.requestSummary(message:)`) がこれを参照する — 「メールの
  言語 ≠ アプリの表示言語の場合のみ翻訳を出す」という要件をこの値で判定
  している。

## `Text(String)` は自動でローカライズされない ("verbatim" 呼び出し)

`Text`/`Button`/`Label`等が文字列**リテラル**を直接受け取る場合は
`LocalizedStringKey`型のオーバーロードに解決され、String Catalog を自動
的に引く。しかし `Text(someVariable)`のように**`String`型の変数**を渡す
呼び出しは、`Text(_: some StringProtocol)`という別のオーバーロードに解決
され、**verbatim (無変換)** で表示される — カタログに同じ文字列のキーが
あっても引かれない。

このアプリには「switch文で文字列リテラルを組み立てて`String`型の
computed propertyとして返し、それを`Text(title)`のように渡す」パターンが
複数あった (一覧のナビゲーションタイトル、作成画面のナビゲーションタイト
ル、翻訳/AI要約バーの見出し、等)。該当箇所は次のいずれかの方法で対応した:

1. **`String(localized: "...")`で明示的にカタログを引く** — switch/三項
   演算子の各分岐そのものを書き換える (`MessageListView.title`、
   `ComposerView.navigationTitle`、`TranslationBar.headline`、
   `AISummaryBar.headline`、`SearchFilterOption.title`、
   `SearchScopeOption.title`、`MailScreenView.selectionTitle`)。
2. **パラメータの型を`String`から`LocalizedStringKey`に変える** —
   呼び出し側は文字列リテラルを渡しているだけなので、この型変更だけで
   自動的にカタログを引くようになる (`MessageListView
   .selectionBarButton(title:)`)。この方法が使えるのは、その`String`値を
   識別子の組み立てなど**表示以外**の用途に使っていない場合のみ。
3. **`Text(LocalizedStringKey(value))`で表示時にだけラップする** — `value`
   自体は`.accessibilityIdentifier`の組み立てなど他の用途にも使っている
   ため型を変えられない場合 (`MessageHeaderInfoView.infoRow(_:_:)`の
   `label`引数、`AccountFilterChip`の`title`— 後者はアカウント表示名の
   ような**動的な値**も同じ引数を通るため、カタログに一致エントリが無い
   値はそのままキー自体 (=元の文字列) が表示されるだけで安全)。

## ローカライズの到達範囲 (網羅していない部分は日本語のまま)

文字列の数が非常に多いため、指示どおり主要画面 (一覧・本文・作成・設定・
検索・ハンバーガーメニュー) を優先し、英訳を用意した。`Localizable
.xcstrings`には136エントリ (`scripts/generate-localizable.py`で生成・
管理)。カバーしている範囲の概要:

- **一覧**: ナビゲーションタイトル、スワイプ/一括操作のラベル、空状態
  メッセージ、同期エラーアラート。
- **スレッド詳細・本文画面**: フッターツールバー5アイコンとその「…」
  メニュー全項目、翻訳バー・AI要約バーの全文言、メール情報シート、
  ナビゲーションタイトル ("メール")。
- **作成画面**: 全セクション見出し・フィールドラベル・ボタン・確認
  ダイアログ、添付メニューの3項目、下書き/送信待ち一覧。
- **検索画面**: ナビゲーションタイトル、空状態の説明文、検索履歴、
  フィルタチップ (全部/添付/未読/英語)、スコープ (すべて/このメール
  ボックス)。
- **ハンバーガーメニュー**: フォルダ一覧の固定項目 (すべての受信トレイ/
  アカウントを追加/設定)、空状態。
- **設定画面**: `AccountsSettingsView`(iOS「設定」シート/macOS Settings
  シーンの共通実装) の全セクション見出し・トグル・Picker・footer説明文。

**意図的に対象外のまま残したもの** (日本語のままでも動作は壊れない):

- メールの件名・本文・送信者名などの**受信データそのもの** — そもそも
  翻訳対象ではない (これは1i/design-phase-3の翻訳バー機能の役割)。
- エラーメッセージの多く (`MessageView.errorMessage`/
  `ComposerView.errorMessage`等) — 大半が`"\(error)"`のようにエラー詳細
  を埋め込む補間文字列で、固定の接頭辞部分だけを訳しても効果が薄い上に
  該当箇所が多数散らばっており、このバッチのスコープに対して費用対効果
  が見合わないと判断した。
- `Settings/`配下の`AccountsSettingsView.swift`以外のファイル
  (`AccountSetupView`/`AccountEditView`/`ICloudAccountSetupView`/
  `GmailAccountSetupView`/`TemplatesSettingsView`/`TemplateEditView`/
  `PushNotificationSettingsView`/`MessageToolbarSettingsView`/`AboutView`
  等) — アカウント追加・編集フォームや個別設定画面群。「設定」の入口
  画面 (`AccountsSettingsView`) は優先対応したが、そこから先に潜る個々の
  画面までは今回のスコープに含めていない。
- macOS 専用 UI (`SidebarView`等の3ペイン構成、メニューコマンド) — iOS の
  主要画面を優先した。文字列自体はソース言語 (日本語) のままなので、
  macOS で「表示言語: English」を選んでも一覧/検索/設定など今回対応した
  範囲は英語化されるが、それ以外は日本語のまま混在する。

これらは新しい文字列を書くたびに`Localizable.xcstrings`へ追記していけば
段階的に拡張できる — `scripts/generate-localizable.py`の辞書に
`"日本語": "English"`の1行を足して再実行するだけで、対応する
`Text("日本語")`/`Button("日本語")`呼び出しは自動的にローカライズされる
(§「`Text(String)`は自動でローカライズされない」に該当する箇所だけは
追加のSwift側対応が要る)。

## 確認方法

Xcode の Scheme 編集や `-AppleLanguages`起動引数を使わずに確認したい
場合、シミュレータの当該アプリのpreferenceドメインへ直接書き込む方法が
手早い (アプリ自身の`LocalizationSettingsStore.setLanguageOption(_:)`が
実際にやっていることと同じ):

```sh
xcrun simctl spawn <UDID> defaults write com.mtkg.otegami AppleLanguages -array en
xcrun simctl install <UDID> <path-to-Otegami.app>   # 直近ビルドを確実に反映
xcrun simctl launch --terminate-running-process <UDID> com.mtkg.otegami
```

このバッチではこの方法で一覧画面 ("All Inboxes"/"All"チップ) と検索画面
("Search"/"Search Mail"/フィルタ文言) の英語表示を実機さながらのスクリー
ンショットで確認済み。
