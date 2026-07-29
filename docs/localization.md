# アプリ UI のローカライズ (表示・操作改善バッチ)

アプリ UI の日本語/English ローカライズと、表示言語の切り替え方法の記録。
表示言語は現在 iOS 標準の「設定 → このアプリ → 言語」(アプリ単位言語
設定) に委ねている — アプリ内蔵の「システムに従う / 日本語 / English」
ピッカーは一時期存在したが廃止済み。経緯は
[docs/settings.md](settings.md#表示言語-表示操作改善バッチ--実機フィードバック第3弾-f-で廃止)
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
  実機フィードバック第3弾 (F) でアプリ内蔵の「表示言語」ピッカー
  (`AppLanguageOption`: `.system`/`.japanese`/`.english`、`AppleLanguages`
  の自前書き換え) は**廃止済み** — 言語切替は iOS 標準の「設定 →
  このアプリ → 言語」(アプリ単位言語設定) に委ねている。詳細・経緯は
  [docs/settings.md](settings.md#表示言語-表示操作改善バッチ--実機フィードバック第3弾-f-で廃止)
  参照。
- **`LocalizationSettingsStore.effectiveLanguageCode`**: 「今実際にどの
  言語で表示されているか」を`"ja"`/`"en"`で返す (`Bundle.main
  .preferredLocalizations`から解決 — OS のシステム言語設定・アプリ単位
  言語設定のどちらの結果もそのまま反映する)。本文画面の翻訳ボタンの表示
  条件 (`MessageView.shouldShowTranslationBar`) と AI要約の出力言語判定
  (`MessageView.requestSummary(message:)`) がこれを参照する — 「メールの
  言語 ≠ アプリの表示言語の場合のみ翻訳を出す」という要件をこの値で判定
  している。この型が公開しているのはこの読み取り専用プロパティのみで、
  言語設定を書き換える処理はもう存在しない (下記「タスク#43」節参照)。

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
- **検索画面**: トップバー (プレースホルダ・星/閉じるボタンの
  アクセシビリティラベル)、「履歴」「保存済み」タブ、空状態の説明文
  (履歴/保存済みそれぞれ)、フィルタチップ (全部/添付/未読 — 検索画面
  再構成 Task #86 で「英語」チップは廃止済み)、スコープ (すべて/この
  メールボックス)。
- **ハンバーガーメニュー**: フォルダ一覧の固定項目 (すべての受信トレイ/
  アカウントを追加/設定)、空状態。
- **設定画面**: `AccountsSettingsView`(iOS「設定」シート/macOS Settings
  シーンの共通実装) の全セクション見出し・トグル・Picker・footer説明文。

**意図的に対象外のまま残したもの** (日本語のままでも動作は壊れない):

- メールの件名・本文・送信者名などの**受信データそのもの** — そもそも
  翻訳対象ではない (これは1i/design-phase-3の翻訳バー機能の役割)。
- エラーメッセージの多く (`MessageView.errorMessage`/
  `ComposerView.errorMessage`/`PushNotificationSettingsView.errorMessage`
  等、`@State private var errorMessage: String?`に代入してから`Text
  (errorMessage)`で表示するパターン全般) — 大半が`"\(error)"`のように
  エラー詳細を埋め込む補間文字列で、固定の接頭辞部分だけを訳しても効果
  が薄い上に該当箇所が多数散らばっており、費用対効果が見合わないと判断
  した。
- macOS 専用 UI (`SidebarView`等の3ペイン構成、メニューコマンド)。

これらは新しい文字列を書くたびに`Localizable.xcstrings`へ追記していけば
段階的に拡張できる — `scripts/generate-localizable.py`の辞書に
`"日本語": "English"`の1行を足して再実行するだけで、対応する
`Text("日本語")`/`Button("日本語")`呼び出しは自動的にローカライズされる
(§「`Text(String)`は自動でローカライズされない」に該当する箇所だけは
追加のSwift側対応が要る)。

## 実機フィードバック第2弾 (A): 「UI に複数言語が混在」「切替が効かない」の調査と修正

実機報告2件を調査した結果、どちらも**この節が既に警告していた
「`Text(String)`は自動でローカライズされない」という同じ根本原因**が
複数箇所で見つかった — カタログのカバレッジ不足そのものより、この
verbatim呼び出しパターンの見落としの方が実際の「混在」の主因だった。

### 1. 「UI に複数言語が混在」の原因: 設定ピッカーの選択肢ラベルが軒並み未対応

`SwipeAction`/`PreviewLineCount`/`SendCancelWindow`/`AppLanguageOption`/
`MessageToolbarAction`の`var title: String { switch self { case ...: "日本語" } }`
という実装パターンが、`Text(action.title)`のように**`String`型の
computed propertyをそのまま`Text`に渡す**呼び出しで使われていた —
まさにこの節の「switch文で文字列リテラルを組み立てて`String`型の
computed propertyとして返し、それを`Text(title)`のように渡すパターン」
そのものだが、`MessageListView.title`等の既知の該当箇所を`String
(localized:)`で対応した際にこれらの`SettingsStore`系ファイルが見落と
されていた。表示言語を English に切り替えても、スワイプ設定・プレビュー
行数・送信キャンセルの猶予・**表示言語ピッカー自身の選択肢**・ツール
バー並び替え画面だけが日本語のまま残り、「大部分は英語なのに一部だけ
日本語」という実機報告の「混在」症状と一致する。5ファイルすべてに
`String(localized:)`を追記して解決した
(`SwipeActionSettingsStore`/`ListDisplaySettingsStore`/
`SendCancelSettingsStore`/`LocalizationSettingsStore`/
`MessageToolbarSettingsStore`)。

同じ調査で`PushNotificationSettingsView`の同意アラートの本文が
`Text("a" + "b" + "c" + "d")`という**文字列連結の`String`式**を`Text`
に渡しており、これも同じ理由 (`Text(some StringProtocol)`のverbatim
オーバーロードに解決される) でカタログを一切引けていなかったことも
発見した — 複数のリテラルを1つに結合して修正した (英訳は
`scripts/generate-localizable.py`に追加済み)。

### 2. 「切替が効かない」の原因: バックグラウンド復帰と完全終了の混同

`LocalizationSettingsStore`の`AppleLanguages`書き換え自体は (実機/
シミュレータへの直接`defaults write`で以前から検証済みのとおり) 正しく
機能する。ただし**反映には「プロセスの完全終了→再起動」が必要**で、
iOS の「ホーム画面に戻る→アプリアイコンを再タップ」は多くの場合アプリを
バックグラウンドから復帰させるだけでプロセスは終了しない — 設定画面の
小さな footer 注記だけでは、ユーザーが「アプリを再起動した」つもりで
実際には同じプロセスのまま (=言語設定が反映されないまま) 使い続けて
しまう、というギャップがあったと考えられる。

対応: 言語ピッカーの選択が変わった直後に確認アラートを表示し、
「今すぐ終了」ボタンで`exit(0)`により**プロセスそのものを終了**する
選択肢を追加した (`OtherSettingsView`)。次にアプリアイコンをタップした
ときは必ず新しいプロセスの起動になるため、「ホーム画面に戻っただけでは
反映されない」という曖昧さを解消する。「あとで」を選んでも footer の
案内文はそのまま残るので、後で手動(スワイプで完全終了→再起動)で反映
することもできる。

### 3. 副作用として発見: この開発機のシミュレータはシステム言語が英語で、
カタログ拡張が既存 XCUITest のラベルテキスト検索を無言で壊しうる

上記1の調査中、この開発機のシミュレータ (iPhone 17 Pro Max, iOS 27 beta)
の**システム言語が既定で英語**であることが判明した — `AppLanguageOption
.system`(このアプリの既定設定) はシステム言語にそのまま従うため、
`Localizable.xcstrings`に英訳を追加した文字列は、このシミュレータ上では
**追加した瞬間から** UI に反映される (アプリを明示的に「English」に切り
替えなくても)。これは仕様どおりの正しい動作だが、副作用として:
`app.buttons["なし (平文)"]`/`app.staticTexts["プッシュ通知"]`/
`app.buttons["ピン留め"]`のような**ラベルテキスト固定の XCUITest
lookup**が、対応する文字列をカタログに追加した瞬間に無言で壊れる
(「なし (平文)」ボタンが実際には「None (Plain)」というラベルになり、
厳密一致検索が何も見つけられなくなる)。実機フィードバック第2弾の作業中
に3箇所 (`DovecotAccountUITestHelpers.fillDovecotAccountForm`/
`fillMailpitSMTPFields`、`OtegamiM9PushSettingsUITests`、
`OtegamiPinSwipeListDisplayUITests`) で実際に踏んで修正した — 対応方法は
「アクセシビリティ識別子があればそちらを使う」「無ければ日英両方の
ラベルにマッチする`OR`述語にする」のいずれか (`DovecotAccountUITestHelpers
.tapPlainSecurityMenuOption(in:)`のドキュメントコメント参照)。

**この3箇所以外にも、同種のラベルテキスト固定 lookup が既存の XCUITest
スイート (`OtegamiCredentialRecoveryUITests`/`OtegamiDuplicateAccountUITests`/
`OtegamiMissingCredentialUITests`/`OtegamiHTMLDisplayUITests`等) に多数
残っている**(「資格情報を待っています」「パスワードを入力」「本文なし」
など、既にカタログに存在する文字列)。これらは今回のバッチが直接触れて
いない既存テストスイートであり、実際にこのシミュレータで壊れているか
どうかは未確認 — 網羅的な洗い出しと修正は本バッチのスコープを大きく
超えるため見送り、次にこれらのテストを実行する際に発覚したらこのパターン
(識別子検索への切り替え、または日英両対応の述語) で個別に対応する前提で
`PENDING.md`に記録した。

### 4. カバレッジの拡張

上記の調査と合わせて、以前「対象外」としていた個々の設定画面
(`AccountSetupView`/`AccountEditView`/`ICloudAccountSetupView`/
`GmailAccountSetupView`/`TemplatesSettingsView`/`TemplateEditView`/
`PushNotificationSettingsView`/`MessageToolbarSettingsView`/`AboutView`)
と、実機フィードバック第2弾で新設した設定画面群
(`AccountSettingsCategoryView`/`MailViewerSettingsView`/
`MailListSettingsView`/`OtherSettingsView`/`SignatureTemplatesSettingsView`/
`SignatureTemplateEditView`/`AccountLabelColorPicker`) の静的な (補間を
含まない) 文字列をすべて`Localizable.xcstrings`に追加した
(137→232エントリ)。`AccountTypeSelectionView`も対応済み。

## タスク#43: 「起動し直すと言語設定が毎回英語に戻る」バグの調査と修正

実機フィードバック第3弾 (F) で表示言語ピッカーを廃止した際、旧ピッカーが
残す`AppleLanguages`上書きの後始末として`AppEnvironment.init()`から起動
のたびに (冪等の**つもり**で) 呼ぶ移行処理
`LocalizationSettingsStore.migrateAwayFromLegacyAppleLanguagesOverrideIfNeeded()`
を追加した。ところがこの実装は「`AppleLanguages`キーに値があれば削除する」
だけで、**一度削除したことを覚えるフラグを持っていなかった** —
そして iOS の「設定 → このアプリ → 言語」(OS 標準のアプリ単位言語設定)
も内部的にはこの同じ`AppleLanguages`キーで実現されているため、ユーザーが
OS 設定で言語を選んでも次回起動時にこの移行処理がそれを削除し、システム
既定の言語 (この場合English) に戻ってしまう — 「起動し直すたびに英語に
戻る」という実機報告と一致する重大な回帰だった。

**対処: 移行処理そのものを削除した** (フラグを立てて「一度だけ実行」に
する対処は採らなかった)。理由は`git log`で旧ピッカーの生存期間を確認した
結果による: `AppLanguageOption`/`setLanguageOption(_:)`は2026-07-27 06:07
のコミットで導入され、同日13:53 のコミットで廃止された — 生存期間は
約8時間で、この間に実際に「日本語」/「English」を明示選択したユーザーが
いたとしても、その残骸は廃止直後の初回起動でこの移行処理が (フラグの
有無に関わらず) 一度実行された時点でもう消えている。つまり「一度だけ
消す」という当初の目的は、フラグを追加するかどうかに関係なくとっくに
果たされていた。それ以降この処理が毎起動削除し続けていたのは専ら OS の
アプリ単位言語設定であり、フラグ化を選んでも「これまでの毎起動削除」を
今から一回だけ余分に踏んでしまう (フラグが立っていない状態からのスタート
になるため) 影響は避けられない。よって一切`AppleLanguages`に触れない
のが最も安全で、移行処理と呼び出し箇所を削除した
(`LocalizationSettingsStore.swift`/`AppEnvironment.swift`)。廃止済み設定
の選択値保存キー (`app.languageOption`) 自体は従来どおり無害な残骸として
放置している。

この型 (アプリターゲット直下の`Support/`) にはXCTestのユニットテスト
ターゲットが無く (`make test`が対象とするのは`packages/OtegamiKit`のみ
— `apps/Otegami`には`OtegamiUITests`しか無い)、今回は削除のみで新しい
分岐ロジックを追加していないため、新規ユニットテストは追加していない。

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
