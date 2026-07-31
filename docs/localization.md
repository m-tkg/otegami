# アプリ UI のローカライズ

アプリ UI の日本語/English ローカライズの仕組みと、到達範囲・運用ルールを
扱う。表示言語の切り替えは iOS 標準の「設定 → このアプリ → 言語」
(アプリ単位言語設定) に委ねている — アプリ内蔵の言語ピッカーは廃止済み。

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
- **`LocalizationSettingsStore.effectiveLanguageCode`**
  (`apps/Otegami/Sources/Support/`): 「今実際にどの言語で表示されて
  いるか」を`"ja"`/`"en"`で返す (`Bundle.main.preferredLocalizations`
  から解決 — OS のシステム言語設定・アプリ単位言語設定のどちらの結果も
  そのまま反映する)。本文画面の翻訳ボタンの表示条件
  (`MessageView.shouldShowTranslationBar`) と AI要約の出力言語判定
  (`MessageView.requestSummary(message:)`) がこれを参照する — 「メールの
  言語 ≠ アプリの表示言語の場合のみ翻訳を出す」という要件をこの値で判定
  している。この型が公開しているのはこの読み取り専用プロパティのみで、
  言語設定を書き換える処理は無い (言語切り替えは OS 標準の「設定 →
  このアプリ → 言語」に委ねている)。

## `Text(String)` は自動でローカライズされない ("verbatim" 呼び出し)

`Text`/`Button`/`Label`等が文字列**リテラル**を直接受け取る場合は
`LocalizedStringKey`型のオーバーロードに解決され、String Catalog を自動
的に引く。しかし `Text(someVariable)`のように**`String`型の変数**を渡す
呼び出しは、`Text(_: some StringProtocol)`という別のオーバーロードに解決
され、**verbatim (無変換)** で表示される — カタログに同じ文字列のキーが
あっても引かれない。

「switch文で文字列リテラルを組み立てて`String`型の computed property
として返し、それを`Text(title)`のように渡す」パターン (`SwipeAction`/
`PreviewLineCount`等の設定値の表示名、一覧・作成画面のナビゲーション
タイトルなど) がこのアプリ全体に多数あり、次のいずれかの方法で対応する:

1. **`String(localized: "...")`で明示的にカタログを引く** — switch/三項
   演算子の各分岐そのものを書き換える。
2. **パラメータの型を`String`から`LocalizedStringKey`に変える** —
   呼び出し側は文字列リテラルを渡しているだけなので、この型変更だけで
   自動的にカタログを引くようになる。この方法が使えるのは、その`String`
   値を識別子の組み立てなど**表示以外**の用途に使っていない場合のみ。
3. **`Text(LocalizedStringKey(value))`で表示時にだけラップする** — `value`
   自体を`.accessibilityIdentifier`の組み立てなど他の用途にも使っている
   ため型を変えられない場合。動的な値 (アカウント表示名など) も同じ引数を
   通る場合は、カタログに一致エントリが無い値はそのままキー自体 (=元の
   文字列) が表示されるだけなので安全 (`AccountFilterChip`の`title`が
   この形 — 動的文字列を`Text`に渡すときは`Text(verbatim:)`を使う、という
   `CLAUDE.md`のルールとはこの点で役割が異なる: `LocalizedStringKey`
   ラップは「固定文言はカタログを引きたい・動的値は安全にフォール
   スルーしたい」場合、`Text(verbatim:)`は「Markdown解釈自体を止めたい」
   場合に使う)。

**補間を含む `String(localized: "... \(x)")` の解決**: `String
(localized:)`に文字列補間を渡すと、`String.LocalizationValue`が補間値を
フォーマット指定子 (`Int`なら`%lld`、`String`なら`%@`) に変換したキーで
カタログを引く (例: `"添付ファイル %lld 個"`)。この形は静的には解決できる
が、後述の自動チェックスクリプトは補間を含むリテラルを一律スキップする
ため検出できない — 新規追加時は目視確認が必要 (後述「今後の運用ルール」
参照)。

## ローカライズの到達範囲

主要画面 (一覧・本文・作成・設定・検索・ハンバーガーメニュー・macOS
メニューバー) を優先して英訳を用意している。`Localizable.xcstrings`は
`scripts/generate-localizable.py`で生成・管理する。

**意図的に対象外のままにしているもの** (日本語のままでも動作は壊れない):

- メールの件名・本文・送信者名などの**受信データそのもの** — そもそも
  翻訳対象ではない (翻訳バー機能の役割)。
- エラーメッセージの多く (`"\(error)"`のようにエラー詳細を埋め込む補間
  文字列が大半で、固定の接頭辞部分だけ訳しても効果が薄い)。
- ブランド名・プロトコル用語: `From`/`To`/`Cc`/`Bcc`等のRFC見出し語、
  `Message-ID`/`In-Reply-To`/`References`、`IMAP`/`STARTTLS`/`TLS`等の
  プロトコル名、`Gmail`/`iCloud`/`Yahoo`/`Yahoo! JAPAN`/`Outlook`/
  `Office365`/`Exchange`/`Microsoft`のプロバイダブランド名、`EN`/`HTML`
  の短縮バッジ。
- `DesignSystemCatalogView` (`#if DEBUG`のみの開発者向けカタログ画面)。

新しい文字列を書くたびに`Localizable.xcstrings`へ追記していけば段階的に
拡張できる — `scripts/generate-localizable.py`の辞書に`"日本語":
"English"`の1行を足して再実行するだけで、対応する`Text("日本語")`呼び
出しは自動的にローカライズされる (前述の verbatim パターンに該当する
箇所だけは追加のSwift側対応が要る)。

## 日付/数値の書式

一覧・スレッド行の日付は`OtegamiDateFormat.listRowText(for:)`
(`DesignSystem/OtegamiDateFormat.swift`) に集約されており、`Calendar
.current`+`Text(date, format: .dateTime...)`という標準API経由 — ロケール
追従は Foundation/SwiftUI 側が担うため、`Locale(identifier:)`で固定する
必要のある箇所は無い。カレンダー招待カードの`DateFormatter`も
`dateStyle`/`timeStyle`のみ指定でロケールを固定しない標準的な使い方。

## 既知の落とし穴

- **言語設定の変更にはプロセスの完全終了が必要**: アプリ単位言語設定
  (iOS の「設定 → このアプリ → 言語」、内部的には`AppleLanguages`)
  の変更は、iOS の「ホーム画面に戻る→アプリアイコンを再タップ」では
  多くの場合バックグラウンドから復帰するだけでプロセスは終了せず、
  反映されない。設定画面 (`OtherSettingsView`) は言語設定が変わった
  タイミングで確認アラートを出し、「今すぐ終了」ボタンで`exit(0)`に
  よりプロセスそのものを終了できるようにしている — 次にアプリアイコン
  をタップすれば必ず新しいプロセスの起動になり、変更が反映される。
- **シミュレータのシステム言語が英語だと、日本語ラベル固定の XCUITest
  lookup が無言で壊れる**: `AppLanguageOption.system`(既定) はシステム
  言語にそのまま従うため、開発機のシミュレータのシステム言語が英語だと、
  `Localizable.xcstrings`に英訳を追加した文字列は追加した瞬間から UI に
  反映される (明示的に英語へ切り替えなくても)。これは仕様通りだが、
  `app.buttons["なし (平文)"]`のような**ラベルテキスト固定の XCUITest
  lookup**は、対応する文字列をカタログに追加した瞬間に対象が見つからなく
  なる。対応方法は「アクセシビリティ識別子があればそちらを使う」「無け
  れば日英両方のラベルにマッチする`OR`述語にする」のいずれか。

## 自動チェック: `scripts/check-localizable-coverage.py`

`make check-localization` (`ci-app.yml`にも組み込み済み) で実行する。

- `apps/Otegami/Sources`配下を走査し、`Text`/`Button`/`Label`/`Toggle`/
  `Menu`/`CommandMenu`/`TextField`/`SecureField`/
  `ContentUnavailableView`/`NavigationLink`/`Section`/`Picker`と、
  `.navigationTitle`/`.alert`/`confirmationDialog`/`.accessibilityLabel`/
  `.accessibilityHint`/`.accessibilityValue`/`.help`、`String(localized:)`
  に渡された文字列リテラルを抽出する (コメント/文字列リテラルを正しく
  認識した上でスキャンするので、ドキュメントコメント中のサンプルコード
  を誤検知しない)。
- カタログ未登録のリテラル (日本語・「英語のUI文言らしき」英語の両方)
  を fatal、`en`訳が空のキーを fatal、ソースから見つからないキーを
  warning (削除候補) として報告する。
- ブランド名・プロトコル用語 (`Cc`/`Bcc`等のRFC見出し語、`IMAP`/`TLS`等、
  `Gmail`/`iCloud`/`Yahoo`/`Outlook`/`Office365`/`Exchange`/`Microsoft`等
  のプロバイダ名) はホワイトリストで除外している。
- **既知の限界**: 文字列補間 (`\(...)`) を含むリテラルは全て無条件で
  スキップする — 単純な`Text("... \(x)")`なら補間部分がデータなので
  正しい挙動だが、上記の`String(localized: "... \(x)")`のように本来は
  静的解決できるケースも一律スキップしてしまう。この種の見落としは
  `grep -rn 'String(localized:.*\\(' apps/Otegami/Sources`で定期的に
  手動監査するか、目視確認 (次項) で拾う必要がある。

## 今後の運用ルール

1. **ユーザー向け文字列は必ず`Localizable.xcstrings`経由にする** — 新しい
   `Text`/`Button`/`.navigationTitle`等を書くときは、日本語リテラルを
   そのまま書けばキー自体は自動的に機能する (上記「仕組み」参照)。
   `String`型のcomputed propertyやswitch文の分岐値を経由する場合は
   `String(localized:)`か`LocalizedStringKey(_:)`ラップが要る (上記
   「`Text(String)`は自動でローカライズされない」節)。
2. **新規追加時は`scripts/generate-localizable.py`の`translations`辞書に
   ja→enを1行足して`python3 scripts/generate-localizable.py`を実行する**
   — `Localizable.xcstrings`をXcodeのString Catalogエディタで直接編集
   した場合は、**同じコミットで**同じキー/値をこのスクリプトの
   `translations`辞書 (曖昧さ回避コメントが要る場合は`comments`辞書)
   にも反映すること。次に誰かがこのスクリプトを実行してコミットする際、
   辞書にない追記は容赦なく削除される。
3. **コミット/PR前に`make check-localization`を実行する** — `ci-app.yml`
   で自動的にも走るが、ローカルで先に潰しておく方が速い。
4. **`String(localized: "... \(x)")`は自動チェックの死角** — 補間を使う
   場合は上記grepで手動確認するか、`LOCALE=en scripts/verify-screen.sh
   <scenario>` / macOSはローカルビルドを`-AppleLanguages '(en)'`付きで
   起動して目視確認する。

## 確認方法

Xcode の Scheme 編集や `-AppleLanguages`起動引数を使わずに確認したい
場合、シミュレータの当該アプリのpreferenceドメインへ直接書き込む方法が
手早い:

```sh
xcrun simctl spawn <UDID> defaults write com.mtkg.otegami AppleLanguages -array en
xcrun simctl install <UDID> <path-to-Otegami.app>   # 直近ビルドを確実に反映
xcrun simctl launch --terminate-running-process <UDID> com.mtkg.otegami
```
