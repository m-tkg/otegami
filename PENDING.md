# PENDING — ユーザー対応待ち事項

このファイルは、開発を進める上でユーザー本人の判断・手動作業が必要になった項目を記録する。
実装は各項目をモック/スキップ/dev mailstack 代替で進めており、開発の手を止めていない。
都合の良いときに対応し、必要であれば `Config/Local.xcconfig` 等の git 管理外ファイルに値を設定すること。

同じ内容を「今日やることリスト」の形に行動単位で並べ替えたものが
[`HUMAN_TASKS.md`](HUMAN_TASKS.md) にある。背景・理由・切り分けの経緯を
知りたい場合はこのファイル、次に何をやればいいかだけ知りたい場合は
`HUMAN_TASKS.md` を見ること。

> **2026-07-29 一括確認済み**: この日時点で残っていた実機確認待ち項目
> (OTA `5bb49d0` までの全配信分 — #115/#119/#120/#121/#124 の実機確認、
> 送信の二重送信・スタック、要約エコー、Microsoft OAuth (Outlook/
> Office365)、Yahoo! JAPAN プリセット、引用折りたたみ (プレーン)、
> UI バッチ #125/#126/#130/#131 ほか) は、ユーザーがまとめて実機確認し
> **すべてクリア**と報告済み。以下の個別節の「未確認」記述のうちこの
> 日付以前のものは、この一括確認で解消済みとして読むこと。

## Task #182: macOS アプリ内アップデート (About 統合) — 実際の差し替え未確認

**実装状況**: 実機フィードバック「mac 版で、update のチェックができる画面は
About に移動してほしい。また、そこから update ボタンも置いて、自身の
アップデートができるようにしてほしい」を受けて実装。メニューバーの
「Otegami」→「Otegamiについて」(標準の About panel を置き換え) が開く
`AboutView`にバージョン情報・著作権・アップデート確認/インストール UI
(`AboutUpdateSection`) を統合した。Task #158 の独立ウィンドウ
`UpdateCheckView`/`UpdateCheckRequest`は削除・統合済み。詳細な設計 (ダウン
ロード元ホスト制限・zip slip 対策・署名同一性検証・書き込み権限フォール
バック・入れ替え手順) は`docs/release.md`「アプリ内アップデート (macOS
のみ、Task #182)」節参照。`make test`/`make mac`/`make ios`/
`make check-localization` すべて green (単体テストは`AppUpdateDownloadPolicyTests`/
`ZipEntryPathValidatorTests`/`CodeSignatureIdentityTests`ほか新規)。

**このセッションで確認したこと**: 実際にビルドしたアプリを起動し、
「Otegamiについて」→About ウィンドウを開いて「Check for Updates」を
実際にクリック → 実 GitHub API に問い合わせて「You're Up to Date」まで
表示されることを確認 (実機のシステム言語が英語のため英語表示だが、
ローカライズ自体が正しく解決されている証拠でもある)。「Also Check
Pre-releases」チェックボックスの on/off・再チェックも動作確認済み
(現行タグより新しい安定版が無いため、この開発機では"新しいバージョンが
あります"状態そのものの画面は未確認 — `AvailableUpdateRow`のレイアウトは
目視未検証)。

**未確認 (実機・実リリースでの確認が必要)**:
1. **実際に新しいバージョンをリリースしてから**、「更新」ボタンを押した
   ときの実際のダウンロード→展開→署名検証→入れ替え→再起動の一連の流れ。
   このセッションでは**ユーザーの実アプリを壊すリスクがあるため実行して
   いない** — 検証は`AppUpdateDownloadPolicy`/`ZipEntryPathValidator`/
   `CodeSignatureIdentity`の単体テストと、`AppUpdateInstaller`のコード
   レビューで担保している。
2. 「新しいバージョンがあります」画面 (`AvailableUpdateRow`) 自体の見た目
   (リリースノート抜粋のスクロール等)。
3. `/Applications`に書き込み権限が無い環境 (通常ユーザー権限で
   `/Applications`配下が管理者所有になっている等) での
   `.noWritePermission`フォールバック (ダウンロードページを開く導線) の
   実地確認。
4. 「今すぐ再起動」ボタンで実際に新プロセスが起動し、旧プロセスが正しく
   終了するか (`createsNewApplicationInstance = true`が意図通り機能する
   か)。
5. Gatekeeper 未承認・署名の異なるダミー zip を実際に用意して
   `.signatureMismatch`/`.gatekeeperRejected`経路が実地でも発火するかの
   確認 (単体テストは`CodeSignatureIdentity`の比較ロジックのみで、実際の
   `codesign -dv`/`spctl -a`の出力フォーマットとの整合は次回リリース後の
   実行で確認する)。

## Task #162: 署名を本文に混在させない (実機フィードバック) — 実機確認

**実装状況**: 署名を選んでも本文には一切挿入しなくなった (プレビュー
表示のみ、送信時にだけ「本文+空行+署名」を結合)。詳細は
`docs/design-system.md`の Task #162 節参照。`make test`/`make mac`/
`make ios` green。単体テスト (`RichTextHTMLCoderTests.appendingSignature*`)
と Mailpit 統合テスト (`OutboxHTMLSendIntegrationTests
.bodyCombinedWithSignatureSendsWithABlankLineSeparator`、実際のDovecot/
Mailpit相手にgreen) 済み。

**未確認 (実機での目視・タップ確認)**:
1. 新規作成を開き、署名を選択 → 本文欄には何も追加されず、本文欄の
   すぐ下に「署名: <選んだ署名名>」というラベルと、その下にグレーの
   読み取り専用プレビュー (署名の本文) が表示されること。
2. 別の署名/「なし」に切り替えると、ラベル・プレビューだけが変わり、
   本文の内容は一切変化しないこと。
3. 差出人アカウントを切り替えると、そのアカウントで前回選んだ署名
   (一度も選んだことがなければアカウントの既定署名、それも無ければ
   「なし」) に自動的に追随すること。
4. 署名付きで送信 → 送信済み/Gmail側で「本文 + 空行1つ + 署名」の順で
   本文とhtmlの両方に反映されていること (統合テストでは確認済みだが、
   実際のメールクライアント表示は未確認)。
5. 下書きとして保存 → 再度開く → 署名の選択状態 (ラベル・プレビュー)
   が復元され、本文には混ざっていないこと。
6. 送信を取り消す (C7) → 再度開いたComposerで署名の選択状態が復元
   されること。
7. `scripts/verify-screen.sh composer-signature`は`-uitestsOpenComposerDirectly`
   経由だと`環境.accounts`読み込み前にComposerが開いてしまう既存の
   タイミングの癖 (Task #161以前から) があり、From欄が「アカウントを
   選択」のままで署名プレビュー行自体はスクリーンショットに写っていない
   — 深追いしていないので、実機確認では通常の「作成」ボタン経由で
   確認してほしい。

## Task #160: スレッド要約 — 最終形はmapのみの単一パイプライン (経緯は6段階) — 実機確認

**現在の設計 (Task #160フォローアップ5、2026-07-30ユーザー指示「スレッド
要約の最終形への簡素化」で確定)**: per-messageの事実抽出
(`summarizeThreadEntry`、削らずに書き出す指示) を各メッセージに1回ずつ
実行し、`"[日付] 差出人: 抽出内容"`という行を**空行区切りで**連結する
だけ。reduce/refine段 (旧■経緯統合パス・旧■現状生成パス) は無く、
`■経緯`/`■現状`のラベルも出ない。進捗表示は「n/m 通目を要約中…」のみ。

**それ以前の5段階 (フォローアップ1〜4) は、いずれも「per-message抽出
結果をモデルにもう一段読ませて何かを書かせる」設計に起因する問題の
発見と対策の繰り返しだった** (map段のメッセージ単位化 → 二重圧縮の根治
→ メタ言及調の除去 → 仕上げ(refine)パスの追加 → ■現状ハルシネーション
の多層防御) — 最終的にユーザーが「その2段目自体が要らない」と判断し、
mapのみへ簡素化された。各段の詳細な経緯・実FM確認ログは
`docs/translation.md`の以下6節参照 (フォローアップ3/4の節は先頭に
「撤去済み」の注記あり):
「スレッド全体のAI要約: メッセージ単位のmap段への改修 (Task #160)」
「スレッド要約の二重圧縮を根治 (Task #160フォローアップ)」
「スレッド要約のメタ言及調を除去 (Task #160フォローアップ2)」
「スレッド要約の『仕上げ』パスでさらに簡潔化 (Task #160フォローアップ3、撤去済み)」
「■現状のハルシネーションを多層防御で根治 (Task #160フォローアップ4、撤去済み)」
「スレッド要約を最終形へ簡素化: mapのみの単一パイプラインに (Task #160フォローアップ5)」

`make test`/`make mac`/`make ios` green (全段階とも)。

**残っている実機確認**:
- スレッド要約の生成にかかる時間 (メッセージ数ぶん FM を実行するため、
  reduce/refine段が無くなった分フォローアップ3/4時代より短くなって
  いるはず) と、「n/m 通目を要約中…」表示が実機で違和感なく見えるか。
- 生成結果 (空行区切りのper-message抽出結果のリスト、ラベル無し) が
  `ThreadDetailView`の要約シートで実際にどう見えるか — シミュレータでの
  スクリーンショット確認はしていない (Foundation Modelsのシミュレータ
  既知不調のため)。
- 実際のスレッド (架空フィクスチャでなく実データ) で、数値・固有名詞・
  決定事項が各行にきちんと残っているか、往復の多いスレッドでも
  (以前の仕上げパスほどの圧縮は無いが) 読みやすいと感じられるか。
  reduce/refine段が構造的に無くなったため、以前報告された「■現状に
  全然関係ない話が出てきた」というハルシネーションは原理的に再発し得
  ないはず — 実機でもそれが体感できるか確認してほしい。

## Task #128: 「英語メールなのに翻訳ボタンが押せない」修正 — 実機/UITest実行確認

**実装状況**: 原因の2仮説 (HTML controller未接続の恒久化／保存済み
`detectedLanguage`の不正値固定化) の両方に防御的な修正を実施し、
OSLog計装 (`TranslationGate`カテゴリ) も追加済み。`make test`/`make ios`
(UITestターゲット含むtest-without-buildingビルド) は green。詳細は
`docs/translation.md`「実機フィードバック: 英語メールなのに翻訳ボタンが
押せない (Task #128)」節参照。

**残っているのは以下2点の実機/実行確認**:
- 追加した `OtegamiHTMLTranslationUITests
  .testEnglishMessageWithStaleWrongDetectedLanguageStillShowsTranslateButton`
  は、このセッションの2回のシミュレータ実行いずれも
  `messageDetail.htmlWebView`が現れず失敗した — ただしこれは
  `OtegamiSecurityNoticeDarkModeUITests.testBetaTestingNoticeRendersFullyWithoutOverlap`
  の doc comment が既に記録している、この直接遷移経路自体の既知の
  シミュレータ/ツールチェーン不調と同じ症状 (`docs/verify.md`の既知不調
  (2)) で、今回の変更が原因という証拠はない。実機、または安定した
  シミュレータ環境での再実行が必要。
- 実際の Okta サインオン通知メール (仮説(1)(2)のどちらが実際の原因
  だったか) での end-to-end 確認 — このセッションでは元の `.eml`
  (`scratchpad/signon.eml`、実アドレス入りのため repo に無い) を使えず、
  匿名化フィクスチャでの防御的修正止まり。次に同じ報告が来た場合は、
  まず `log stream --predicate 'category == "TranslationGate"'` で
  3条件の実測値を見て、どちらの仮説が実際に効いていたか確定させること。

## Task #119/#120/#121: 実機での最終確認

実装・単体テスト (`make test`)・`make mac` ビルドは完了済み。以下は実機/
シミュレータでの確認が必要:

- **Task #119 (「その他 → Trash」問題)**: iCloud または SPECIAL-USE を
  広告しない汎用 IMAP アカウントを追加し、ハンバーガーメニューの「その他」
  セクションから Trash/Junk/Sent/Drafts/Archive が消え、対応する統合
  カテゴリセクションに正しく現れるか。詳細: `docs/qa-findings.md`
  「Task #119」節。
- **Task #120 (アーカイブ解除の即時反映)**: アーカイブ済み未読メールを
  アーカイブ解除した瞬間、pull-to-refresh なしで受信箱一覧に現れるか。
  その後サーバー同期が完了しても重複行が残らないか。同じ観点でアーカイブ/
  迷惑メール移動/削除についても、Trash・Junk・Archive の各メールボックス
  が既にローカルに存在するアカウントで確認。詳細: `docs/qa-findings.md`
  「Task #120」節。
  - **follow-up 候補 (未着手)**: `ThreadDetailView`("…" メニュー) の
    archive/junk/delete は `MessageListView`/`AccountDigestView` とは
    別の独自実装 (`MessageRemoval.commit`を呼ばない) で、今回の仮配置
    機構の対象外のまま — 統合すれば同じ即時反映を得られるが、Task #115
    で慎重に直した `notifyThreadRemoved()`/`replaySoon()`の順序を崩さない
    よう別タスクとして着手すること。
- **Task #121 (リレー URL の iCloud 同期) — Task #173 follow-up で撤回・
  解消済み**: リレー URL 自体がビルド時埋め込み値 (`RelayURLConfig`) に
  変わり、ユーザーが入力する値そのものが無くなったため、iCloud 同期の
  対象から外した (`docs/icloud-sync.md` 参照)。この pending 項目は
  もう検証不要。

## Task #124: 送信の二重送信・「送信待ち」スタック — 実機/実 SMTP での最終確認

**実装状況**: 原因 (アカウント単位の直列化が無い `OpQueueProcessor
.replay`、前回 pendingSend を孤立させる `schedule()`、スレッド詳細の裏に
隠れる `SendCountdownBar`) を特定し修正済み。`FakeSMTPSession` を使った
ユニットテスト (`OpQueueProcessorTests.swift` の "Task #124" セクション:
同時 `replay()` 2本で送信1回のみ、クラッシュ模擬からの再送拒否、クリーン
失敗後の正常リトライ) に加え、**実 SMTP (dev mailstack の Mailpit) に
対する統合テストも実施・グリーン** (`OpQueueProcessorSendIntegrationTests
.swift` — 同時 `replay()` 2本を実サーバーに対して発行し、Mailpit の REST
API で受信数が厳密に1通であることを確認)。`make test`/`make mac`/
`make ios` も全てグリーン。詳細は `docs/qa-findings.md`「Task #124」節。

**残っているのは実機での最終確認のみ**:

- スレッドを開いた状態から返信して送信 → カウントダウンバーが (スレッド
  詳細の裏に隠れず) 表示されるか。
- バー満了後、そのセッション内で実際に送信されるか (アプリ再起動不要)。
- カウントダウン中にアプリをバックグラウンドへ送っても、復帰後に (また
  はバックグラウンド中に) 正しく1回だけ送信されるか。
- カウントダウン中に別のメールをもう1通送っても、両方とも最終的に
  (2重送信せずに) 届くか (`schedule()` の finalize-before-overwrite 修正の
  確認)。

## Task #116: アカウント追加画面のプロバイダ拡充 — 実接続・Azure アプリ登録待ち

**実装状況**: 第1段 (Yahoo/Yahoo! JAPAN/Exchange のホスト/ポートプリセット)・
第2段 (Outlook.com/Office365 の Microsoft OAuth) とも実装・単体テスト済み
(`make test`)。**残っているのは実アカウント/実 Azure テナントでの最終
確認のみ。**

- **第1段 (Yahoo/Yahoo! JAPAN/Exchange)**: `MailProviderPresetTests`で
  プリセット値 (ホスト/ポート/セキュリティ) を検証済み。**Yahoo! JAPAN
  は実機フィードバックで「メールサーバにアクセスできない」報告があった**
  — 原因はプリセット自体ではなく (1) Yahoo!メール側「メールソフトでの
  利用設定 (IMAP/POPアクセス)」が既定オフ、(2) ログイン ID がフル
  メールアドレスでなく Yahoo! JAPAN ID (`@`より前) を要求される場合が
  ある、の2点と判断し、ガイダンス文言の具体化 + 編集可能な「ログインID」
  フィールドの追加で対応した。**改めて実機確認が必要** — 詳細は
  `docs/design-system.md`「Task #116」節、確認項目は `HUMAN_TASKS.md`。
- **第2段 (Outlook.com/Office365)**: OSS のため Azure AD の Client ID を
  リポジトリに含めない方針 (Gmail の Google Cloud Client ID と同じ)。
  ビルドする人が各自 Azure Portal でアプリを登録する必要がある。
  - **ブロックしている機能**: Outlook.com/Office365 アカウントの追加・
    同期・送受信の**実サービスでの動作確認** (コード自体は実装済み。
    `AccountTypeSelectionView`の Outlook/Office365 ボタンは
    `OTEGAMI_MICROSOFT_CLIENT_ID`未設定の間ずっと無効化され続ける)。
  - **対応手順** (`docs/oauth-setup.md`「Microsoft OAuth Client ID の
    取得」節に詳細版あり):
    1. [Azure Portal](https://portal.azure.com/) → Microsoft Entra ID →
       「アプリの登録」で新規登録 (アカウントの種類は「任意の組織
       ディレクトリ内のアカウントと個人の Microsoft アカウント」)。
    2. 「認証」→「プラットフォームを追加」→「モバイルアプリケーション
       およびデスクトップアプリケーション」でリダイレクト URI
       `com.mtkg.otegami.msauth://oauth2redirect` を登録し、「パブリック
       クライアント フローを許可する」を有効化する (Google と違い
       **この登録は必須** — 未登録だと `redirect_uri_mismatch` で失敗
       する)。
    3. 発行された Client ID を `Config/Local.xcconfig`(git 管理外) の
       `OTEGAMI_MICROSOFT_CLIENT_ID`に設定する。
    4. `make ios`/`make mac`で再ビルドし、「アカウントを追加」→
       「Outlook」/「Office365」ボタンが有効になっていることを確認する。
    5. 実際にサインインし、INBOX 同期・送信・再認証・アクセス取り消し
       後の復旧を確認する (`docs/oauth-setup.md`「実機での最終確認手順」
       節に詳細なチェックリストあり)。
  - ユニットテスト (`MicrosoftOAuthEndpointsTests`/
    `MicrosoftOAuthClientTests`/`TokenStoreTests`、31件) は Gmail 側の
    `GoogleOAuthTests`と同じ`URLProtocol`スタブ+フェイク認可フロー構造
    で検証済み — token 交換/refresh/invalid_grant/id_token からのメール
    アドレス抽出をカバーしている。実 Azure AD サーバとの通信・実機での
    ブラウザ遷移・実際の同意画面表示は自動化の対象外。

## Task #115: アーカイブ後の空状態フラッシュ修正 — 実機での即時遷移確認

`ThreadDetailView`のフッターツールバーからアーカイブ/削除/迷惑メールに
すると「メッセージが見つかりません」が数秒表示されてから遷移する実機
報告を修正した (`notifyThreadRemoved()`をネットワーク往復
`replaySoon()`の前に呼ぶよう順序を入れ替え、コミット `e9ebc0b`/
`b5100fd`)。ロジックはローカル DB 反映と遷移のタイミングを解きほぐす
だけの単純な並び替えで`make test`/`make mac`/`make ios`は緑だが、
実タップ + 実ネットワーク往復に依存する挙動のため、この開発機の
シミュレータでは検証できていない (`docs/verify.md`の既知不調 (2))。
実機確認ポイントは`docs/design-system.md`「Task #115」節末尾参照 —
要点は「アーカイブ/削除/迷惑メールタップ後、空状態が一瞬でも見えず
即座に遷移すること」「『次のメールへ進む』設定の各分岐」「グループ
表示モードでも同じ」「遅い回線でも最終的にサーバへ反映されること」。

## Task #105: スレッド表示オフなのに再起動直後だけスレッド挙動 — 解決済み (2026-07-29)

実機の OSLog 採取で真因を確定し、`c1804f4` (`ThreadRoute` 導入) で修正、
実機でユーザー確認済み。`CFPreferencesAppSynchronize` 仮説は棄却 —
実際は `.navigationDestination(item:)` の destination クロージャの
stale capture (cold launch 初回 push 限定)。経緯と教訓は
`docs/qa-findings.md`「Task #105」節の「決着」参照。

## Task #89: 表示設定の iCloud 同期 — 実機での再インストール後復元確認

**実装状況**: `SettingsCloudSyncEngine`/`AppSettingsCloudDirectory`
(`packages/OtegamiKit/Sources/AccountCloudSync/`, `apps/Otegami/Sources/Support/`)
で、一覧・ビューア・スワイプ・ツールバー並び・アバターソース・翻訳/AI
設定を `settings.v1` という2本目の iCloud KVS キーで同期する実装を完了。
既存の account 同期 (`accounts.v1`) と同じ「iCloud でアカウントを同期」
トグル・同じシミュレータ汚染ガードを共有する。ユニットテスト
(`SettingsCloudSyncEngineTests`) green、`make mac`/`make ios` green。
詳細は `docs/icloud-sync.md`「表示設定の同期 (Task #89)」節参照。

**未確認**: 実機での end-to-end 確認 (OTA インストール→設定変更 (例:
スレッド表示を OFF)→アプリ削除→再インストール→設定が OFF のまま復元
されるか) はこのセッションでは実施していない。同じ Apple ID の別デバイス
への反映 (iOS→Mac、Mac→iOS) も未確認。都合の良いときに実機で確認して
ほしい。

## Task #61: HTML メール翻訳「無反応」修正の実機/シミュレータでの end-to-end 確認

**実装状況**: `HTMLTranslationController.extractTranslatableTexts()`が
抽出失敗を `nil` として返し、`MessageView.requestTranslation`がそれを
ユーザー可視の失敗状態にする修正、および `evaluateJavaScript`の戻り値を
JSON文字列に統一する防御的な変更を実装済み。ガードレール誤発動の寛容化
(1チャンクだけブロックされても他は翻訳を続行) も実装済み。
`MessageTranslatorTests`のユニットテストは green、`make mac`/`make ios`
のビルドも green。詳細は `docs/translation.md`の該当節参照。

**残っているのは実機/シミュレータでの end-to-end 確認のみ**:
このセッションでは XCUITest による再現を試みたが、(a) このシミュレータ/
ツールチェーンでの XCUITest 実行が非常に不安定 (システム権限ダイアログ・
別プロセスとのシミュレータ競合により1回のテスト実行に4-5分かかることが
あった)、(b) 翻訳フローティングボタンの表示条件がシミュレータのシステム
言語設定に依存する (`LocalizationSettingsStore.effectiveLanguageCode`)
ことに気づくまで時間を要した、という2点により、修正後の「タップして
実際に翻訳される」ところまでの確定的な再現には至らなかった。次回は
シミュレータのシステム言語を日本語に設定したうえで、
`OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE`+
`OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX`+
`OTEGAMI_UITEST_FAKE_TRANSLATION=1` の直接遷移経路 (タップ操作を
迂回できる) から始めること。

## Task #64: HTML翻訳ボタン恒常的失敗の根治修正 — XCUITestでのend-to-end確認

**実装状況**: `MessageView.body`の`if let contentHeight { ... } else
{ ... }`が`content`(HTML本文のWKWebViewを含む) を2つの構造的に別の
ビュー分岐として扱ってしまい、HTML本文の初回描画直後 (`contentHeight`
が`nil`→非`nil`に変わる瞬間) に`WKWebView`ごと`HTMLTranslationController`
が破棄・再構築され、`MessageView.htmlTranslationController`が恒久的に
`nil`のまま残ることがある不具合を特定・修正した (`if`/`else`を単一の
`.frame`呼び出しに統合、`docs/design-system.md`「Task #64」節の「根治」
小節に詳細)。`make ios`のビルド成功は確認済み。

**残っているのは実機/シミュレータでのend-to-end確認のみ**: 既存の
`OtegamiHTMLTranslationUITests.testHTMLTranslationPreservesLayoutAndTranslatesText`
(`OTEGAMI_UITEST_FAKE_TRANSLATION=1`で決定的な`"[ja] ..."`出力を使い、
HTML翻訳ボタンをタップして本文中に現れることを確認する既存テスト) を
2回実行しようとしたが、2回とも別々の理由で本題 (翻訳ボタンの挙動) まで
到達できなかった: 1回目は"Test crashed with signal kill before
establishing connection"というXCUITestランナー自体のインフラ的
クラッシュ、2回目はランナー自体は起動したものの、seed済みのはずの
"Your payment has been processed"メッセージが一覧に現れず
`addDovecotTest1Account`によるアカウント追加ステップで94秒かけて失敗
(dev mailstackへの接続不調 — この`PENDING.md`の随所に記録がある
`MailCoreErrorDomain error 1`系の既知の環境不調と同種とみられる、未確証)。
いずれも翻訳ボタン自体のロジックに達する前の環境要因で止まっており、
今回の修正そのものへの反証にはなっていない — Task #61のPENDINGにも
記録済みの、このシミュレータ/ツールチェーン固有の既知の不調と同種と
見ている。修正後の実際の翻訳成功までは、結局まだ確認できていない。

- **対応手順**: 次回このテストが安定して動く環境 (実機、または
  ツールチェーン更新後のシミュレータ) で
  `xcodebuild ... -only-testing:OtegamiUITests/OtegamiHTMLTranslationUITests test`
  を再実行し、`"[ja]"`マーカーが本文中に現れることを確認する。あわせて
  `scripts/verify-screen.sh html-3`(英語HTMLメール) で翻訳ボタンをタップ
  し、`messageDetail.translationFloatingButton.footnote`に「本文の準備が
  まだ完了していません」が出ないことも確認するとよい (tap-freeでは
  ボタンを押せないため、この確認自体はXCUITestかタップ操作が必要)。

## Task #64/#71: フラット表示の重複ヘッダ削除・本文読み込み完了までの
## フローティングボタン非表示 — 実機/シミュレータでの目視確認

**実装状況**: `ThreadDetailView`が`isFlatModeEntry`に応じて最上部の
サマリー行 (差出人+時刻) の表示/非表示を切り替える`showsHeader`を
`ThreadMessageRow`に渡すようにし、`MessageView.syncAIFeaturesState()`
のフローティングボタン表示条件を`bodyRecord != nil`ベースに変更した
(詳細は`docs/design-system.md`「Task #64」節)。`make ios`ビルド成功、
`scripts/verify-screen.sh html-3`/`html-4`のスクリーンショットで全体的な
レイアウト崩れが無いことは確認済み。

**未確認**: この2点はどちらも、現在のtap-free検証手段
(`scripts/verify-screen.sh`の`html-*`シナリオ) の対象範囲外の状態変化
— 前者はフラットモード (スレッド表示OFFの一覧行タップ、または検索
結果) からの遷移でしか再現しない (`html-*`はいずれもグループモードの
「1メッセージスレッド」経由で開く) ため、実際に一覧の「スレッド表示」
設定をOFFにして行をタップする操作が必要。後者は本文取得中 (数十〜
数百ms) の過渡的な状態で、ローカルに`bodyState: .fetched`済みの
フィクスチャではほぼ観測不能。
- **対応手順**: 設定 →「スレッド表示」をOFFにしてから一覧行をタップし、
  本文画面の最上部にサマリー行 (差出人+時刻の1行) が出ないことを
  目視確認する。フローティングボタンの方は、オフラインのままネットワーク
  取得が必要な (まだ一度も開いていない) メッセージを開き、本文取得の
  スピナー表示中にボタンが出ていないことを確認するとよい。

## M6: Google OAuth Client ID の発行

**実装状況**: M6 のロジック・UI は実装済み・単体テスト済み (PKCE 生成/token
交換/refresh/invalid_grant→要再認証を `URLProtocol` スタブ + `FakeAuthorizationFlow`
でモック検証、`make test` に含まれる `GoogleOAuthTests`)。**残っているのは
実 Google アカウントでの最終確認のみ。** 詳細手順は `docs/oauth-setup.md`
にまとめた。

- **理由**: Gmail 連携は OAuth2 (PKCE) で行うが、OSS のためリポジトリに Client ID を含めない方針。
  ビルドする人が各自 Google Cloud Console で Client ID を発行する必要がある。
- **ブロックしている機能**: Gmail アカウントの追加・同期・送受信の**実サービスでの動作確認**
  (コード自体は実装済み。`AccountTypeSelectionView` の Gmail ボタンは
  `GOOGLE_OAUTH_CLIENT_ID` 未設定の間ずっと無効化され続ける)。
- **対応手順** (`docs/oauth-setup.md` に詳細版あり):
  1. [Google Cloud Console](https://console.cloud.google.com/) で新規プロジェクトを作成する。
  2. 「OAuth 同意画面」を設定する (テストモードで良い。自分の Google アカウントを
     テストユーザーに追加すれば審査不要。審査は作者配布ビルドのみ必要)。
  3. 「認証情報」→「OAuth クライアント ID」で **iOS アプリ**タイプ (シークレット不要) を作成し、
     Bundle ID (`com.mtkg.otegami`) を指定する。リダイレクト URI は Google Cloud
     Console 側への個別登録が不要 (`docs/oauth-setup.md` の該当節参照)。
  4. 発行された Client ID を `apps/Otegami/Config/Local.xcconfig` に設定する
     (`cp apps/Otegami/Config/Local.xcconfig.sample apps/Otegami/Config/Local.xcconfig`
     の上で追記)。
  5. `make ios` で再ビルドし、「アカウントを追加」→「Gmail」ボタンが有効になっている
     ことを確認する。
  6. 実際に Google でログインし、アカウント追加・INBOX 同期・送信 (Sent への
     二重保存が起きないこと)・アクセストークン失効後の自動リフレッシュ・
     Google 側でのアクセス取り消し後に「再認証」バナーから復旧できることを
     確認する (`docs/oauth-setup.md` の「実機での最終確認手順」に詳細チェック
     リストあり)。

## 実機フィードバック第2弾: 既存 XCUITest のラベルテキスト固定 lookup が
## ロケール依存で壊れうる (網羅的な洗い出しは未実施)

**発見の経緯**: A「表示言語の切替」修正作業中、この開発機のシミュレータ
(iPhone 17 Pro Max, iOS 27 beta) の**システム言語が既定で英語**であること
が判明した。`AppLanguageOption.system`(既定設定) はシステム言語にそのまま
従うため、`Localizable.xcstrings`に文字列を追加した瞬間、その文字列に
依存する既存 XCUITest のラベルテキスト固定 lookup (`app.buttons["日本語
ラベル"]`等) が無言で壊れる。実際に3箇所 (`DovecotAccountUITestHelpers
.fillDovecotAccountForm`/`fillMailpitSMTPFields`、
`OtegamiM9PushSettingsUITests`、`OtegamiPinSwipeListDisplayUITests`) で
踏んで修正済み (詳細は`docs/localization.md`「実機フィードバック第2弾
(A)」節の3番目の小節参照)。

- **未確認**: 同種のラベルテキスト固定 lookup を持つ他の既存スイート
  (`OtegamiCredentialRecoveryUITests`/`OtegamiDuplicateAccountUITests`/
  `OtegamiMissingCredentialUITests`/`OtegamiHTMLDisplayUITests`等、
  「資格情報を待っています」「パスワードを入力」「本文なし」等の
  カタログ済み文字列に依存) が、このシミュレータで実際に壊れているかは
  未確認 — 本バッチはこれらのスイートを実行していない。
- **対応手順**: 該当スイートを実行し、ラベルテキスト検索が
  `waitForExistence`タイムアウトで失敗する箇所を見つけたら、
  `DovecotAccountUITestHelpers.tapPlainSecurityMenuOption(in:)`が採用した
  パターン (アクセシビリティ識別子があればそちらへ切り替え、無ければ
  日英両方のラベルにマッチする`NSPredicate`の`OR`述語にする) で個別に
  対応する。恒久対策として、このシミュレータのシステム言語を日本語に
  固定する (`xcrun simctl spawn <UDID> defaults write -g AppleLocale
  ja_JP` 等) ことも検討に値するが、副作用 (他のロケール依存テストへの
  影響) の確認が必要なため、この場では変更していない。

## 実機フィードバック第2弾: Gmail アーカイブ修正の実アカウント確認

**実装状況**: 「Gmail でアーカイブが効かない」実機報告を受け、原因
(`\Archive` special-use メールボックスが Gmail に存在しないため、既存の
ローカル Archive-role ルックアップが常に失敗していた) を特定して修正した。
Gmail アカウントはアーカイブ時に宛先メールボックスへの MOVE を試みず、
ソースメールボックスへの `STORE \Deleted` + `EXPUNGE` のみを行う (INBOX
ラベルだけを外し、「すべてのメール」には残す) 実装に変更した。
`FakeIMAPSession`/`CallRecorder` によるユニットテスト4件で契約 (発行される
IMAP コマンドの種類・宛先) は検証済み。詳細は
`docs/qa-findings.md`「実機フィードバック第2弾: Gmail でアーカイブが効かない
実バグの原因と修正」。

- **理由**: 実 Gmail サーバーへの接続が必要で、dev/mailstack (Dovecot) では
  代替できない (Dovecot は素の IMAP special-use のみで Gmail 固有の挙動は
  再現できない)。
- **ブロックしている機能**: 実 Gmail アカウントでの「アーカイブしたメールが
  INBOX から消え、Gmail の Web UI 上の『すべてのメール』には残っている」
  ことの実地確認。
- **対応手順**:
  1. `docs/oauth-setup.md`/上記「M6: Google OAuth Client ID の発行」の手順で
     実 Gmail アカウントを追加する (Client ID 発行がまだの場合は先にそちら
     を完了させる)。
  2. INBOX の適当なメール (またはスレッド) を1件アーカイブする。
  3. アプリの一覧から即座に消えることを確認する (ローカルの楽観的削除は
     オフラインでも即座に効くので、ここまでは Gmail 固有の検証にならない)。
  4. Gmail の Web UI (mail.google.com) を開き、同じメールが INBOX から
     消えていて、「すべてのメール」/検索では見つかることを確認する —
     これが今回の修正の本質的な検証ポイント。
  5. 併せて、iCloud アカウント (`MailboxRole.archive` へ実際に MOVE する
     経路) でもアーカイブしたメールが iCloud 側の "Archive" メールボックス
     に実際に移動することを確認する (こちらは実装自体は変更していないが、
     このバッチで `commitArchive`/`archiveThread` の実装を書き換えたため、
     回帰確認として一緒に行うと安全)。

## M6: iCloud App 用パスワードでの実アカウント確認

- **理由**: iCloud (`ICloudAccountSetupView`) は `imap.mail.me.com`/
  `smtp.mail.me.com` への実接続が必要で、dev/mailstack (Dovecot/Mailpit) では
  代替できない。実装・単体テストは完了しているが、実 iCloud アカウントでの
  接続テストは未実施。
- **ブロックしている機能**: iCloud アカウントでの実際の送受信確認 (フォーム自体の
  UI・プリセット値は `scripts/verify-ios-m6.sh` で自動確認済み)。
- **未確定事項**: IMAP/SMTP のユーザー名をメールアドレスの**フル**
  (`user@icloud.com`) で実装したが、iCloud が短縮形 (`user` のみ) も/のみ
  受け付けるかは実アカウントでの確認が必要 (`ICloudAccountSetupView` のドキュ
  メントコメント参照)。フルアドレスで失敗する場合は `imapUsername`/
  `smtpUsername` の組み立てを短縮形に切り替える (影響範囲はこの1ファイルの
  数行のみ)。
- **対応手順**:
  1. [appleid.apple.com](https://appleid.apple.com/account/manage) で
     「App 用パスワード」を発行する (iCloud のログインパスワードそのもの
     ではログインできない)。
  2. アプリの「アカウントを追加」→「iCloud」で iCloud メールアドレス +
     発行した App 用パスワードを入力し、「接続テスト」→「保存して同期開始」。
  3. INBOX の同期、新規作成→送信 (Sent への反映)、返信のスレッド接続が
     generic IMAP アカウントと同様に動くことを確認する。
  4. もしログインに失敗する場合、上記の「未確定事項」(ユーザー名の形式) を
     疑い、必要なら実装を短縮形に切り替えて再確認する。

## M9: APNs プッシュ通知 — 完了

**実機の iPhone でエンドツーエンドの動作確認まで完了した。** `.p8` キーを
発行し、リレーサーバーをユーザーの自宅サーバー (reverse proxy + プライ
ベート CA 構成) にデプロイし、実機に通知が実際に届くこと・差出人/件名が
正しく書き換えられること・`DELETE /v1/watches/:id` 後に通知が届かなく
なることまで確認済み。途中で見つかった「IDLE がタイムアウトで接続を壊す」
実バグも修正済み (詳細は `docs/verify.md`「otegami-relay: IDLE がタイム
アウトで接続を壊す実バグ」)。これから otegami-relay を自分でセルフホスト
する人向けの手順 (`.p8` の発行、環境変数、Docker Compose での起動、HTTPS
終端、プライベート CA を使う宅内運用の例) は
[`docs/relay-deployment.md`](docs/relay-deployment.md) にまとめてある
— このファイル自身にはもう自分用の手順を残していない。

iPhone 実機側でのプライベート CA ルート証明書の信頼設定 (プロファイルの
インストール + 証明書信頼設定での明示的な有効化) も完了済み。同じ構成
（宅内サーバー + プライベート CA）でセルフホストする場合の一般化した
手順は `docs/relay-deployment.md`「運用例: 宅内サーバー」を参照。

### M9 追補3: watch 照合掃除 (実機バグ1) + 通知アイコン白紙 (実機バグ2) の恒久修正 — 実機での最終確認待ち

**実装状況**: どちらもコード修正・単体テスト (`make server-test`/`make
test`)・ビルド (`make ios`/`make mac`)・実際の OTA IPA を使ったビルド
成果物レベルの検証まで完了済み。詳細な原因・修正内容は`docs/verify.md`
「プッシュ通知まわりの恒久修正2件」参照、`docs/relay-deployment.md`にも
watch 照合掃除の説明を追記済み。

- **バグ1 (削除済みアカウントの watch 残存)**: `GET /v1/watches` +
  `AppEnvironment.reconcilePushWatchesIfNeeded()`で自己修復するように
  なった。**未確認**: 実際にアカウントを削除→リレーへの`DELETE`を
  意図的に失敗させる (またはリレーを一時停止する)→次回起動/フォア
  グラウンド復帰で本当に孤児 watch が消えることの実機/実リレーでの
  確認。
- **バグ2 (通知アイコン白紙)**: `AppIcon.appiconset`を単一 1024 画像
  形式から明示的な多サイズ形式に置き換えた。ビルドした IPA の
  `Assets.car`を`assetutil --info`でダンプし、修正前は存在しなかった
  `phone/scale 3/180px`等のレンディションが実際に入っていることは
  確認済みだが、**実機の通知バナーで見た目としてアイコンが正しく
  表示されることは未確認** — OTA (`https://otegami.mtkg/ota/`) から
  最新ビルドをインストールし、プッシュ通知を1件発生させて確認する
  こと。

### M9 追補4 (Task #169): SSRF/CRLFインジェクション等のセキュリティ修正 — サーバ側完了、アプリ側も Task #171 で対応済み

`CLAUDE-SECURITY-20260729-134850/CLAUDE-SECURITY-RESULTS.md` の F2
(HIGH)・F3・F4・F8・F16 (`server/otegami-relay/` 配下) を修正した。
`swift test` (server) 緑、`RelayNetworkPolicyTests`/
`WatchRoutesTests`/`MinimalIMAPClientLimitsTests`/
`MinimalIMAPClientValidationTests`/`DeviceRoutesTests` に新規テスト
追加済み。詳細は `docs/relay-deployment.md` の脅威モデル 8〜10 番、
運用者がやるべき作業は `HUMAN_TASKS.md`「otegami-relay の再デプロイ」
参照。

**アプリ側対応済み (Task #171、2026-07-30 follow-up でビルド時埋め込み
方式に作り直し)**: `RELAY_DEVICE_REGISTRATION_SECRET` を運用者が設定
した場合、アプリが `POST /v1/devices` に
`Authorization: Bearer <registrationSecret>` を送る。

- **設計変更 (follow-up)**: 当初は `PushNotificationSettingsView` に
  「登録シークレット」`SecureField` を常時表示していたが、実機
  フィードバック「アプリ側でシークレット登録とかなしで通知を受けたい。
  通常のメールアプリはそんなことをしない」を受けて UI を廃止した。
  今は Google/Microsoft の OAuth Client ID と同じビルド時埋め込み方式
  (`Config/Shared.xcconfig` の `OTEGAMI_RELAY_REGISTRATION_SECRET`、
  git-ignored の `Config/Local.xcconfig` で運用者が値を設定) —
  `RelayRegistrationSecretConfig` (app code) が `Info.plist` から読む。
  ユーザー自身が設定する項目は無くなった。
- 送信: `PushRelayClient.registerDevice(...)` の `registrationSecret`
  引数 (既定 `nil` — ヘッダを送らない、これまでどおり) は変更なし。
  `AppEnvironment.enablePushNotifications` が新規デバイス登録の分岐で
  `RelayRegistrationSecretConfig.value` を渡す。
  `updateDeviceToken`/`createWatch`/`listWatches`/`deleteWatch` が使う
  `deviceSecret` とは別物 (混同しないよう `PushRelayClient.swift` に
  コメントあり)。
- エラー表示: `POST /v1/devices` が 401 を返すと
  `AppEnvironment.PushError.registrationSecretRejected` を投げる。
  `PushNotificationSettingsView` は `isRelayRegistrationSecretConfigured`
  で「このビルドに値が入っているのに拒否された (値の不一致)」と
  「このビルドにそもそも値が入っていない」を切り分けて表示する
  (リレー側の内部エラー文言はそのまま出さない)。
- Keychain: `PushSettingsStore` の旧 `registrationSecret`/
  `setRegistrationSecret`/`deleteRegistrationSecret` (ユーザー入力を
  保存していたスロット) は削除した。旧バージョンで値を保存していた
  端末向けに、`AppEnvironment.init()` が毎起動
  `deleteLegacyRegistrationSecretIfPresent()` で後始末する
  (`PushSettingsStore` のコメント参照)。
- CI/配布: `.github/workflows/release-macos.yml` (GitHub secret
  `OTEGAMI_RELAY_REGISTRATION_SECRET` → `Local.xcconfig`)、
  `apps/Otegami/ci_scripts/ci_post_clone.sh` (Xcode Cloud の同名環境
  変数 → `Local.xcconfig`、**Xcode Cloud 側の環境変数登録は運用者の
  手作業**、`HUMAN_TASKS.md`参照)。
- テスト: `PushRelayClientTests`
  (`packages/OtegamiKit/Tests/PushRelayClientTests/`) のヘッダ有無・
  401 応答のデコードのケースは変更なしで引き続き緑。
  `RelayRegistrationSecretConfig`/`PushSettingsStore`/`AppEnvironment`
  の該当ロジックはアプリターゲット側 (`apps/Otegami/Sources`) にあり
  `swift test` から到達できないため未検証 (`GoogleOAuthConfig`/
  `MicrosoftOAuthConfig` も同様に無テスト — 既存の慣行と同じ) —
  実機/シミュレータでの確認手順は `HUMAN_TASKS.md` 参照。

### 既知の未検証事項 (優先度を下げた項目)

- **(解消) 通知の許可を一度も要求していなかった実バグ**: 後続セッションで
  修正済み。`PushTokenCenter.requestToken()` がデバイストークン登録の
  前に `UNUserNotificationCenter.requestAuthorization(options:)` を
  待つようになった (`.authorized`/`.denied`/`.notDetermined` の3状態を
  `NotificationPermissionResolver` で判定・単体テスト済み —
  `packages/OtegamiKit/Sources/PushRelayClient/NotificationPermission.swift`)。
  拒否時は `PushNotificationSettingsView` が「通知が許可されていません。
  設定アプリから許可してください。」+ 設定アプリへのリンクを表示する。
  これにより `xcrun simctl push` の `UNErrorDomain code=2003 "Source is
  not authorized"` ブロッカーは解消したことを実際に確認した
  (`scripts/verify-ios-push-simulated.sh` の3シナリオとも `push
  accepted`)。ただし、その先で**別の、この開発機の iOS 27 ベータ
  Simulator ランタイム固有と見られる制約** (`NotificationService`
  Extension 自体が `launchd_sim` から一切 spawn されない — アプリ側の
  設定は確認済みで問題なし) に突き当たり、「差出人/件名の書き換え」
  までのシミュレータ上での確認はできなかった。詳細は
  `docs/qa-findings.md`「M9 追補2」節、`docs/verify.md`の該当追記を
  参照。このシミュレータ固有の制約は結局解消せず、**実機での確認が
  唯一の完全な検証手段のままだった** — 上記の通り、その実機確認は
  完了済み。
- **(解消 — Task #175) Gmail/Outlook (`.oauth2`) アカウントのプッシュ通知**:
  v1 のリレーは `WatchAuth.Kind.password` のみ対応していたが、実機
  フィードバック (2026-07-30「Gmail は対象外なので届かない」) を受けて
  ユーザー判断で refresh token を預ける方式を実装した。`WatchAuth.Kind
  .oauth` + `WatchAuth.Provider` (`.google`/`.microsoft`) を追加し、
  リレーは watch の (再)接続のたびに `OAuthTokenExchanger` で refresh
  token をアクセストークンへ交換し (Google/Microsoft の token
  endpoint、client_secret 不要 — アプリ側の `GoogleOAuthClient
  .refresh(refreshToken:)`/`MicrosoftOAuthClient.refresh(refreshToken:)`
  と同じ形)、`MinimalIMAPClient.authenticateXOAuth2` で XOAUTH2/SASL-IR
  認証する。アプリ側は `AppEnvironment.watchAuth(for:)`/
  `isPushWatchCandidate(_:)` が Gmail/Microsoft アカウントも watch 対象に
  含め、`GoogleOAuth.TokenStore`/`MicrosoftOAuth.TokenStore` の新しい
  `rawRefreshToken(for:)` で生の refresh token を取得して送る。refresh
  token が失効 (`invalid_grant`) した watch は即座に停止し
  (`WatchSummary.ErrorKind.oauthTokenExpired`、設定画面は「停止（再認証が
  必要）」)、無駄な再試行を繰り返さない。

  **検証状況**: `swift test` (server, 新規 `OAuthTokenExchangerTests` +
  `WatcherPoolTests`の OAuth watch 3件 + `WatchRoutesTests`の oauth
  watch 作成/バリデーション2件) は green — トークン交換は HTTP を
  モックして検証しており、実 Google/Microsoft へは一切通信していない。
  `make test`/`make ios`/`make mac`/`make check-localization` も green。
  **実 Google/Microsoft アカウントでの動作確認はこのセッションでは未実施**
  (実際の refresh token が必要なため) — `HUMAN_TASKS.md`「otegami-relay
  を再デプロイし、Gmail/Outlook のプッシュ通知 (Task #175) 用の環境変数を
  設定する」に手順をまとめた。リレー運用者は `RELAY_GOOGLE_CLIENT_ID`/
  `RELAY_MICROSOFT_CLIENT_ID` を設定し、**リレーのコンテナイメージを
  再ビルドしてから**再デプロイする必要がある (`docs/relay-deployment.md`
  の環境変数表・脅威モデル項目12参照)。
  UI 上「Gmail 一覧で個別に無効化理由を出す」という残課題自体は解消済み
  (対象になったので無効化理由を出す必要がなくなった) — `.unsupported`
  ("対象外") は今後、Gmail/Outlook のどちらでもない `.oauth2` kind
  (実際には発生しないはずの防御的ケース) のみに残る。

  **(解消 — Task #177) `NotificationService` Extension の OAuth 対応**:
  上記の「既知のスコープ外」(`.oauth2` アカウントの push が汎用フォール
  バックのままになる制約) を解消した。Extension は `account.authType`
  で分岐し、`.oauth2` (Gmail/Microsoft) アカウントは `GoogleOAuth
  .TokenStore`/`MicrosoftOAuth.TokenStore` (`AppEnvironment.auth(for:)`
  が前景同期で使うのと同じ型) で共有 Keychain の refresh token をアクセス
  トークンへ交換し、XOAUTH2 で IMAP 認証する。Extension の Keychain
  Access Group は本体と1つしか宣言していない (8fcfab7) ため、
  `KeychainRefreshTokenStore` が明示グループを指定しなくても既定で
  同じグループを見に行く — 追加のグループ指定は不要だった。

  **30 秒制限への対処**: トークン交換は `PushOAuthAccessTokenResolution`
  (新規、`PushRelayClient`) で `oauthTokenFetchTimeout` (10秒) に対して
  レースさせ、遅延/ハングした token endpoint が IMAP フェッチ分の予算を
  食い潰さないようにした。`URLSessionConfiguration` 側のタイムアウトも
  同じ値に設定済み。失敗 (Client ID 未設定・refresh token 未保存・交換
  失敗・タイムアウトのいずれか) は全て `nil` に畳み込まれ、`.password`
  アカウントの資格情報欠落と全く同じ「汎用フォールバックのまま」の扱いに
  なる — 通知が出ないことは絶対にない。`invalid_grant` で refresh token
  が失効した場合、`TokenStore` は本体と同じ副作用 (共有 Keychain からの
  即時削除) を起こす — 次に本体が `auth(for:)` を呼んだときに正しく
  「要再認証」を報告する。

  **検証状況**: `PushOAuthAccessTokenResolutionTests` (新規4件、成功/
  失敗/タイムアウト/ぎりぎり間に合うケース) で timeout レース自体は
  決定的に検証済み。`make test`/`make ios`/`make mac`/
  `make check-localization` は green (`NotificationService` Extension
  ターゲットのコンパイルも `make ios` に含まれる)。**実機での動作確認は
  このセッションでは未実施** — 実 Gmail/Outlook アカウント・実 push・
  実 Extension プロセスでの検証が必要なため。実機確認ポイント:
  1. Gmail/Outlook アカウントで新着メールの push 通知を受け取り、
     差出人・件名 (トグルが on の設定で) が汎用文言でなく実際の内容に
     なっていること。
  2. 電波状況の悪い環境や、意図的に `Local.xcconfig` の Client ID を
     一時的に空にした状態で受け取った push が、クラッシュも通知の
     欠落もなく汎用文言で表示されること。
  3. Gmail アカウントの refresh token を Google アカウント側から失効さ
     せた状態で push を受け取った後、アプリを開いて該当アカウントが
     「要再認証」表示になっていること (Extension 側の削除が実際に反映
     されるか)。
  4. 実際の所要時間 — token 交換 + IMAP 接続 + フェッチが 30 秒以内に
     収まっているか (Xcode の Console.app 等でこの Extension プロセスの
     生存時間を観察するか、`serviceExtensionTimeWillExpire()` が呼ばれて
     いないかを確認)。
- macOS 版のプッシュ通知: `NotificationService` Extension は iOS のみ
  (理由は `NotificationService.swift`/`Config/Otegami-iOS.entitlements`
  のコメント参照)。`AppEnvironment.enablePushNotifications` は macOS では
  `PushError.unsupportedPlatform` を返し、UI がその旨を表示する — ここ
  までは自動検証済みだが、macOS 版プッシュ通知の実装自体は範囲外。
- `xcrun simctl push` によるシミュレータへのペイロード注入テストは
  後続セッションで `scripts/verify-ios-push-simulated.sh` として実施
  済み (上記「(解消) 通知の許可を一度も要求していなかった実バグ」参照)。
  `NotificationService` の書き換えロジック自体は
  `NotificationEnrichmentTests`、許可判定は
  `NotificationPermissionResolverTests` で単体テスト済み。
  `scripts/verify-ios-m9.sh` 自体は M9 で追加済みで、M10 の
  最終回帰チェックでも引き続き green (プッシュ設定 UI の opt-in フロー・
  無効な URL の拒否・シミュレータでの `.noDeviceToken` グレースフル
  デグレードを確認)。

## M11: iCloud アカウント同期の実機 2 台間確認

**実装状況**: 資格情報 (Keychain) の iCloud キーチェーン同期対応、
アカウント定義 (`NSUbiquitousKeyValueStore`) の同期・突き合わせエンジン
(`AccountCloudSyncEngine`)、設定画面のトグル、entitlement (iOS/macOS 両方)
は実装済み・単体テスト済み (`AccountCloudSyncTests`、22 件、`make test` に
含まれる)。iOS シミュレータでの起動確認・トグル表示・トグル操作の
非クラッシュ確認・既存アカウント追加フローの回帰確認は
`scripts/verify-ios-icloud.sh` で自動検証済み。**残っているのは実
2 台のデバイス (同一 Apple ID) 間で本当に iCloud KVS/Keychain 経由の
同期が起きることの確認のみ。**

- **理由**: `NSUbiquitousKeyValueStore`/iCloud キーチェーンは実 iCloud
  アカウント + 複数の実デバイス (または実デバイス数台) がないと本物の
  往復を検証できない。シミュレータは Apple のドキュメント上、KVS が
  ローカルフォールバック動作をする場合があると明記されており、実際
  この開発環境では「1 台のシミュレータの中で uninstall しても KVS/
  Keychain が残る」という形で観測された (`docs/verify.md`/
  `.claude/skills/verify/SKILL.md` の M11 節) — これは「1 台の中での
  永続化」の確認にはなるが、「2 台の異なるデバイス間で本当に iCloud
  サーバ経由で伝播するか」の確認にはならない。
- **ブロックしている機能**: 実際の「iPhone でアカウントを追加したら Mac
  に自動的に出現する」体験そのものの確認。
- **対応手順** (実機 iPhone + Mac、同一 Apple ID、両方でその Apple ID の
  iCloud キーチェーンが有効になっていること):
  1. 両方の実機に `make ios-device` / `make mac`(または `make mac-app`)
     でビルド・インストールする (`DEVELOPMENT_TEAM`/Bundle ID が同じ
     チームで署名されていること — 異なる Team ID/Bundle ID では
     entitlement の `$(TeamIdentifierPrefix)$(CFBundleIdentifier)` が
     一致せず別々の KVS/Keychain スコープになるため、必ず同じ
     `Config/Local.xcconfig` 設定でビルドすること)。
  2. iPhone 側でアカウントを 1 つ追加する (dev/mailstack の Dovecot でも、
     実 Gmail/iCloud アカウントでも可)。
  3. 数秒〜数十秒待ってから Mac 側のアプリを起動 (またはフォアグラウンド
     復帰) し、設定のアカウント一覧に iPhone で追加したアカウントが
     自動的に出現することを確認する。
     - 資格情報 (パスワード/Gmail リフレッシュトークン) も iCloud
       キーチェーン経由で届いていれば、そのまま初期同期が始まる。
     - まだ届いていなければ「資格情報を待っています」バナー + 「再接続」
       ボタンが出る。Mac 側でキーチェーンアクセス.app を開き iCloud
       キーチェーンの同期状況を確認するか、数分待ってアプリを再起動
       (自動再チェックが走る) するか、「再接続」ボタンを手動で押す。
  4. 逆方向 (Mac で追加 → iPhone に出現) も確認する。
  5. 一方のデバイスでアカウントを削除し、もう一方でも消えることを確認
     する (tombstone 経由の削除伝播)。
  6. 設定の「iCloud でアカウントを同期」トグルを一方のデバイスだけ OFF
     にし、そのデバイスでは新規アカウント追加が cloud に反映されない
     (もう一方には出現しない) こと、OFF のデバイス自身のローカル動作は
     変わらないことを確認する。
  7. **(追加, 重複挿入バグの修正後)** 両方のデバイスで**独立に**同じ
     メールアカウント (同じメールアドレス・同じ IMAP 設定) を追加してから
     iCloud 同期させ、`AccountCloudSyncEngine.reconcile()` の同一性
     チェック (`CloudAccountSnapshot.identityKey`, `docs/icloud-sync.md`
     「重複挿入バグとその修正」節) が実際の cloud KVS 経由の往復でも
     効いて、どちらのデバイスにもアカウントが2行重複しないことを確認する
     — この修正自体はシミュレータ1台への直接 DB 注入
     (`OtegamiDuplicateAccountUITests`) と単体テストでのみ検証済みで、
     実 2 台間の cloud 往復を通した確認はまだ行っていない。

## design-phase-3: 翻訳の実機 (Simulator でない) 確認

**実装状況**: 翻訳バー (1i)・「英語に翻訳して送る」(1k) の UI 実装・
設定 (1l) は完了。エンジン層 (`FoundationModelsTranslationService`) は
`swift test` (サンドボックス化されていない macOS プロセス) からは実機
上で確認済み — 実際に英文↔和文の翻訳に毎回 2〜5 秒で成功している。

**未確認**: この UI を通した実際の翻訳成功が、iOS Simulator の `.app`
プロセス内では確認できなかった。`OtegamiTranslationBarUITests` を通し
て6回連続でリトライしても `FoundationModels.LanguageModelError error
-1` で失敗し続けた (詳細と切り分けの過程は `docs/translation.md`
「design-phase-3: iOS Simulator の `.app` プロセスから呼んだときの既知
の制限」参照)。UI 実装・呼び出しコード自体に不具合がある証拠はなく
(同一コードが素の macOS プロセスからは毎回成功する)、この開発機の
ツールチェーン (Xcode 27 beta + iOS 27 beta シミュレータ) か、iOS
Simulator アプリプロセスから on-device 推論ブローカーを呼ぶ経路自体の
制限とみられる。

- **対応手順**:
  1. 実機 (iPhone/iPad、Apple Intelligence 対応・有効) に
     `make ios-device` でインストールする。
  2. Apple Intelligence が有効になっていることを確認する (設定 →
     Apple Intelligence)。
  3. 英文メール (`dev/mailstack` の `20-english-quarterly-report.eml`
     を seed 済み) を開き、翻訳バーの「翻訳」ボタンをタップして実際に
     訳文を表示するか確認する (自動翻訳は既定オフになったため、今は
     タップが必要 — 下記「自動翻訳の既定 OFF 化」節参照)。
  4. `30-fixed-width-notice-en.eml` (幅700px級の固定幅テーブル英語メール)
     でも同様に翻訳し、表・画像・罫線のレイアウトを保ったまま文字だけが
     日本語化されることを確認する — `HTMLTranslationController` による
     DOM 書き換え経路 (`docs/translation.md`「実機フィードバック: 「勝手
     に翻訳しないで」「HTML はレイアウトを保って」」節) の実モデルでの
     確認。
  5. 実機でも同じ `LanguageModelError -1` が出る場合はコード側の不具合
     の可能性が高まるので調査を再開する。実機では成功する場合は
     Simulator 固有の制限として `docs/translation.md` に確定情報を追記
     し、この節を消す。

### 追補: 自動翻訳の既定 OFF 化・HTML レイアウト保持翻訳・fit-to-width の実機/シミュレータ確認 (実機フィードバック対応)

**実装状況**: 実機ユーザー報告2件 (「翻訳機能は、勝手に実行しないで
欲しい」「htmlメールの場合、レイアウトをなるべく崩さないように翻訳を
表示して欲しい」) を受けて対応済み。`TranslationSettingsStore
.autoTranslateEnglishKey` を既定 OFF に変更 (キーも `.v2` にリネーム)、
HTML メールの翻訳は `HTMLTranslationController` による DOM テキスト
ノード書き換えでレイアウトを保持するようにし、幅600-800px級の固定幅
テーブル HTML メールが右端クリップ・巨大フォントで描画される別件の
実機報告にも fit-to-width (`HTMLWebViewCoordinator.fitToWidthScript`)
で対応した。`make test`/`make ios`/`make mac` すべて green (UITest
ターゲットのビルドも `-only-testing:` 実行時に成功しており、
`OtegamiFitToWidthUITests`/`OtegamiHTMLTranslationUITests`/更新した
`OtegamiTranslationUITests` はコンパイルは通っている)。

**未確認 (このセッション固有のシミュレータ既知事象により)**: この作業
セッションはシミュレータのネットワークが不調で、アカウント追加の
「接続テスト」が `MailCoreErrorDomain error 1` (`接続に失敗しました:
サーバーに接続できません`) で一貫して失敗した (ホスト側から同じ
`localhost:1143` へは Python の素の socket 接続で疎通確認済みなので、
Dovecot 自体は正常 — シミュレータ側の何らかのネットワーク経路の問題と
みられる)。`OtegamiFitToWidthUITests`/`OtegamiHTMLTranslationUITests`は
いずれもテスト内でアカウント追加 (`addDovecotTest1Account`) が必要な
構造のため、2回試して同一エラーで失敗し続けたことを確認した時点で
切り上げた (現在のセッションの既知の制限としてタスク側にも記録あり)。
その結果、以下は **視覚的に未確認** のまま:

- `29-fixed-width-bank-notice.eml`/`30-fixed-width-notice-en.eml` を
  実際にシミュレータ/実機で開き、fit-to-width で右端が切れず全幅に
  収まって表示されることの目視確認。
- `30-fixed-width-notice-en.eml` を `OTEGAMI_UITEST_FAKE_TRANSLATION=1`
  (または実機で通常の翻訳) で翻訳し、`HTMLTranslationController` に
  よるレイアウト保持翻訳が実際に画面上で機能することの目視確認。
- 実際の Foundation Models モデルによる訳文の品質 (レイアウト保持翻訳
  経路を通した場合)。
- 自動翻訳が既定 OFF になったことで、既存インストール (アップグレード)
  のユーザー体験が意図通りか — キーリネームにより理論上は新規/既存
  問わず OFF から始まるはずだが (`TranslationSettingsStore
  .autoTranslateEnglishKey` のドキュメントコメント参照)、実機の
  アップグレードシナリオでの実地確認はしていない。

- **対応手順**: このシミュレータのネットワーク不調が解消した後 (または
  別のシミュレータ/実機で)、`make mailstack-up && make mailstack-seed`
  してから
  `xcodebuild -project apps/Otegami/Otegami.xcodeproj -scheme Otegami
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
  -only-testing:OtegamiUITests/OtegamiFitToWidthUITests test`
  (および `OtegamiHTMLTranslationUITests`) を実行し、`.xcresult` に
  添付されたスクリーンショットを確認する。上記「design-phase-3: 翻訳の
  実機確認」節の対応手順3・4番とあわせて実施するとよい。

## 表示・操作改善バッチ: リンクのブラウザオープン修正・添付メニューの実機確認

**実装状況**: 実機で報告された「メール内リンクをタップしてもブラウザが
開かない」不具合について、`HTMLWebViewCoordinator`(`HTMLMessageView.swift`)
に2つの実際の修正を入れた — `WKUIDelegate`未実装 (`target="_blank"`の
ようなリンクの取りこぼし対策)、`allowsLinkPreview`未無効化 (実機の3D/
Haptic Touchによるピーク・プレビューのジェスチャー競合対策)。同じバッチ
で作成画面の添付ボタンも1つの`Menu`(ファイルを選択/写真を選択/写真を
撮る) に統合し、「写真を撮る」用に`CameraPicker`(`UIImagePickerController`
ラッパー) を新設した。

**未確認 (Simulatorでも実機でも)**: どちらの機能も、実際に「タップした
結果、期待する追加のUI (ブラウザのシート、添付メニューのポップオーバー)
が現れる」ところをXCUITestで自動検証しようとしたが、**このバッチの変更
とは無関係の環境要因**にぶつかり断念した — 掘り下げた結果、このバッチで
一切変更していない既存のUITest (`OtegamiTemplatesUITests`のテンプレート
挿入`Menu`、`OtegamiLinkBrowserUITests`のリンクタップ) が、**このバッチ
の変更を git stash で完全に除去した baseline のコードに対しても**同じ
症状 (タップ後、期待した提示が起こらずに現在の画面自体が消えて背後の
ハンバーガードロワーが見える) で失敗することを確認した — つまり
Xcode 27 beta / iOS 27 beta のこのシミュレータ環境では、「タップ結果と
してシート/ポップオーバーが現れる」系の操作をXCUITestで検証すること
自体が (少なくとも今回試した範囲では) 信頼できない状態になっている。
詳細は`docs/design-system.md`「表示・操作改善バッチ」節の該当箇所参照。

- **ブロックしている機能の確認**: (1) メール本文内のリンクタップで
  設定したブラウザ (アプリ内ブラウザ/デフォルトブラウザ) が実際に開く
  こと、特に`target="_blank"`のようなリンクを含む実際のHTMLメールで。
  (2) 作成画面の「添付」ボタンをタップしてメニュー (ファイルを選択/
  写真を選択/写真を撮る) が実際に開き、それぞれが機能すること。「写真を
  撮る」はシミュレータでは灰色表示 (カメラ無し) になる想定なので、
  実機での有効化・カメラ起動・撮影した写真が添付されることの確認も必要。
- **対応手順**:
  1. `make ios-device`でインストールし、リンク付きの実際のHTMLメール
     (newsletter等、`target="_blank"`を含むものが理想) を開いてリンクを
     タップ、設定どおりのブラウザが開くか確認する。
  2. 設定 →「リンクを開く方法」を「デフォルトブラウザ」に切り替えても
     同様に確認する。
  3. 作成画面 (新規作成/返信) を開き、「添付」ボタンをタップしてメニュー
     が開くこと、「ファイルを選択」「写真を選択」がそれぞれ従来どおり
     機能すること、「写真を撮る」でカメラが起動し撮影した写真が添付
     リストに追加されることを確認する。
  4. もしリンクタップが実機でも失敗する場合、`HTMLWebViewCoordinator`の
     `decidePolicyFor`/`createWebViewWith`に到達しているか (ログ追加や
     ブレークポイントで) 切り分ける — この2つの修正で説明のつかない
     別の原因がある可能性が残る。

## 開発環境: 連続する `xcodebuild test` 単体実行の間でシミュレータの App
## Group DB が読めなくなることがある (原因未特定)

**症状**: `OtegamiDuplicateAccountUITests` の3フェーズ再現手順
(`docs/icloud-sync.md`「重複挿入バグとその修正」節) — フェーズ1を
`xcodebuild test -only-testing:...` で単体実行 → アプリを terminate →
ホストの `sqlite3` で App Group コンテナ内の DB に重複行を直接 INSERT →
フェーズ2を別の `xcodebuild test -only-testing:...` 呼び出しで単体実行 —
という、別々の `xcodebuild test` 呼び出しをまたぐ手順を実行すると、
フェーズ2 (時にはフェーズ1) が「設定 → アカウント」を0件 (「アカウント
がありません」) として表示することを複数回確認した。`sqlite3` で当該
DB ファイルを直接読むと INSERT した行を含めて正しい内容が残っており
(アプリが消したのではない)、`xcrun simctl get_app_container ... groups`
で確認した App Group コンテナの UUID もその DB ファイルと一致している
ため、アプリ自身の `DatabasePool` オープンが何らかの理由で失敗し
`AppEnvironment.init()` の `catch` 節 (インメモリ DB へのフォールバック)
を静かに踏んでいる可能性が高いと見ている。

- シミュレータを `erase` した直後の1回だけの実行でも同一症状が再現した
  (`docs/verify.md` が既に記録している「erase 直後は不安定」パターンとは
  別 — 今回は複数回連続で発生し、時間を置いても再現し続けた)。
- コードの変更 (`AppEnvironment.adoptOrphanedCredentialIfUnambiguous`
  など、この修正セッションで追加した処理) を一時的に無効化しても同じ
  症状が再現することを確認済みなので、この修正セッションのコード変更が
  原因ではない。`AccountDuplicateMerger`/`AppDatabase` 自体は今回無変更。
- 単一の `xcodebuild test` 呼び出し内で `app.terminate()`/`app.launch()`
  を繰り返すテスト (`OtegamiCredentialRecoveryUITests` など) では一度も
  再現していない — 症状が出るのは常に「別プロセスの `xcodebuild test`
  呼び出しがアプリを再インストールした直後」のパターンのみ。
- **対応手順 (次にこの手順を検証する人向け)**: `xcodebuild test` の
  ログに `AppDatabase.makeShared` 失敗時の `assertionFailure` メッセージ
  が出ているか (この Debug/Test 構成でアサーションが有効かどうか自体も
  未確認)、`log stream` でアプリプロセスの `os_log` を尻尾追いする、
  DatabasePool のオープンにタイムアウト/リトライを入れて切り分ける、
  などから始めるとよい。再現待ちのため保留 — 影響は
  `OtegamiDuplicateAccountUITests` のような複数 `xcodebuild test` 呼び出し
  をまたぐ検証手順に限られ、通常のアプリ実行やこのリポジトリの他の
  自動検証スクリプト (単一 `xcodebuild test` 呼び出し内で完結するもの)
  には影響しない。

## 開発環境: 設定画面のトグルタップが一覧側の再描画に反映されないことがある
## (`OtegamiPinSwipeListDisplayUITests.testFlatModeShowsOneRowPerMessage`)

**症状**: 表示・操作改善バッチの回帰確認中に発見 (このバッチの変更が
原因ではない — B3「フラット表示」自体は以前のマイルストーンの既存機能で、
このバッチでは一切変更していない)。設定 →「スレッド表示」トグルを
タップして閉じても、一覧が引き続きスレッド表示のまま (`ThreadSummary`
1件、期待は複数件のフラット行) になることがある。まずこのテスト自体の
バグ (対象行が`dev/mailstack/seed/fixtures/`の増加で画面外にスクロール
していた — `List`は画面外の行をアクセシビリティツリーに残さないため
`cells.containing(...)`だけでは見つからない) を修正し (スクロール追加、
`0`件だった症状は解消)、トグルタップ直後に1秒待ってから閉じる変更も
入れたが、それでもなお安定して`1`件のまま (フラット化していない) で
止まる。`docs/verify.md`のM11節が記録している「タップ自体は効いている
のに`Switch.value`の読み取りが追いつかない」系の癖と同じ環境要因の可能性
があるが未確証 — このテストの場合は値の読み取りではなく実際の一覧の
再描画そのものが追いついていないように見える点が異なる。
- **対応手順**: `@AppStorage(ListDisplaySettingsStore.threadingKey)`の
  変更が`MessageListView`の`.task(id: ObservationKey(...))`を実際に
  再トリガーしているか、実機またはより安定したシミュレータで確認する。
  再現しない場合はこのXCUITest環境固有の問題として確定させる。

## 開発環境: `xcodebuild test` 実行中にアプリがバックグラウンドへ遷移し、
## C7 送信キャンセルの opQueue リプレイが取り残されることがある (原因未特定)

**症状**: 新画面構成バッチの `scripts/verify-ios-m5.sh` 回帰実行中に発見。
Phase 2 (`OtegamiM5ComposeSendUITests` — 作成→送信、Composer シートの
dismiss を確認して即座にテストメソッドが返る) が完了した直後、
Simulator のホーム画面が表示される (アプリがバックグラウンドへ遷移した)
ことをスクリーンショットで確認した。C7 送信キャンセル
(`SendCancelSettingsStore` 既定5秒のカウントダウン) の途中でこれが
起きると、`RootView.handleScenePhaseChange` の `.background` 分岐が
`PendingSendCoordinator.finalizeNow()` を呼び `beginBackgroundTask` 付きで
即座に `replayOpQueue` を試みるはずだが、実際には `opQueue` の `send` 行が
`attempts=0` のまま (＝一度もリトライされずに) 何分も残り続けることを、
App Group コンテナ内の `otegami.sqlite` を `sqlite3` で直接読んで確認した
(DB ファイル自体は正しく開けており、上記の「App Group DB が読めなくなる」
節とは別の症状)。**次にアプリをフォアグラウンドへ戻した瞬間
(`.active` 経由の `syncAllAccountsOnce()`) に初めて実際に送信され、
数秒で Mailpit に届くことも確認済み** — データ消失はなく、あくまで
「バックグラウンドで止まったまま次のフォアグラウンド化を待つ」状態。

- **このバッチのコード変更が原因ではない**: `PendingSendCoordinator`/
  `OpQueueProcessor`/`RootView` のシーンフェーズ処理は一切変更していない
  (今回のバッチはハンバーガーメニュー/検索/フッターツールバーの UI 層の
  変更のみ)。C7 自体はこのバッチ以前から存在する機能で、`docs/verify.md`
  には C7 導入後に `verify-ios-m5.sh` を通し直した記録が見当たらず、
  このバッチの回帰実行が (偶然にも) この経路を最初に踏んだ可能性がある。
  Simulator のバックグラウンド実行タイムアウトが実機より短い/不安定と
  いう既知の一般的な制限 (M9「シミュレータは実 APNs デバイストークンを
  発行しない」と同種) の一種と見ているが未確証。
- **対応手順 (次にこの手順を検証する人向け)**: 実機での再現有無の確認
  (Simulator 固有かどうかの切り分け)。再現するなら、
  `beginBackgroundTask` の猶予時間内に `OpQueueProcessor.replay` の
  IMAP/SMTP 接続が実際に開始されているか (`MCOConnectionLogger` 等で
  ワイヤレベルの挙動を見る、`docs/verify.md` の M5 節が使った手法) から
  切り分けるとよい。影響は「送信直後にアプリが素早くバックグラウンドへ
  回るタイミング」に限られ、通常の利用 (送信後もアプリを見ている、5秒の
  カウントダウンが終わるまで待つ) では踏まない。詳細は
  `docs/design-system.md`「新画面構成」節の「検証で見つかった既存の
  環境依存の落とし穴」参照。

## 起動/フォアグラウンド復帰時・同期完了後の本文バックグラウンドプリフェッチ — 実機での体感速度確認

**実装状況**: 「さっき読んだメールも、アプリを起動し直すと読み込みが
入る?表示まで時間がかかる」報告のうち、未オープンメッセージ
(`bodyState == .notFetched`) が初回オープン時にネットワーク取得を待つ
分を軽減する`SyncCoordinator.prefetchUnifiedInboxBodiesIfNeeded`を実装・
単体テスト済み (`UnifiedInboxPrefetchTests`、`FakeIMAPSession`で候補選定・
デバウンス・オフライン時の無言スキップ・認証エラー時の該当アカウントのみ
スキップを検証)。

Task #63 (「メール本文画面じゃなくても、まだ読み込んでないメールがある
なら裏で読み込みしてほしい。直近3日間くらいのものでいい」) で対象基準を
固定30件から「受信日時が3日以内」の期間基準に変更し、各アカウントの
差分同期成功後にもその場でプリフェッチが走るトリガーを追加した
(`schedulePostSyncPrefetchIfNeeded`)。`MessageQueryTests`/
`UnifiedInboxPrefetchTests`に3日以内カットオフ・保険の上限件数・同期
完了トリガーとそのデバウンスのテストを追加。`make test`/`make ios`/
`make mac`すべて green。詳細は`docs/design-system.md`「C: 一度表示した
メールを再度開くと毎回読み込みが入る、体感が遅い」節のフォローアップ
段落参照。

- **未確認**: dev mailstack (Dovecot) 越しの単体テスト以外での、実機
  (実 IMAP サーバー、実際のネットワーク遅延) を使った体感速度の確認。
  具体的には次の2点:
  - 起動直後に一覧をスクロールしてもすぐ本文が表示されるか。特に複数
    アカウント環境での逐次プリフェッチが実際の起動直後の数秒でどこまで
    終わるか (アカウント数・回線速度依存) は計測していない。
  - Task #63 で追加した同期完了後トリガー: アプリを開いたまま数分待ち
    (IDLE のサーバープッシュ、またはフォアグラウンド復帰時の差分同期を
    待つ)、直近3日以内の新着メールが一覧に出た直後、開く前から本文が
    即座に表示されるか。
- **対応手順**: 実機またはより実回線に近いシミュレータで、複数アカウント
  (できれば実 Gmail/iCloud を含む) を登録した状態でアプリを再起動し、
  起動直後に統合受信トレイの直近3日分を開いて本文が即座に表示される
  かを確認する。加えて、アプリを開いたまま数分待って新着メールが同期
  された直後にも同様に確認する。

**Task #80 追記 (一覧/検索結果更新トリガーのプリフェッチ)**:
`SyncCoordinator.prefetchMessageBodies(messageIds:accounts:authProvider:)`
を新設し、`MessageListView`(一覧の`summaries`/`searchResults`更新)と
`SearchScreenView`(検索結果`results`更新)から、表示中リスト先頭50件の
うち未取得のものを3秒デバウンス＋内容不変ならスキップの条件で背景取得
するようにした。`MessageBodiesPrefetchTests`(`FakeIMAPSession`)で
未取得のみ取得・複数メールボックスにまたがるグルーピング・アカウント
外IDのスキップ・オフライン無言スキップ・既存3日プリフェッチとの共存を
単体テスト済み、`make test`/`make mac`(ビルドのみ、他エージェント作業
中のファイルの影響で当時 red だったが自分の変更箇所には無関係と確認済み)
は確認したが、**下記は実機/シミュレータでの目視未検証**:
- 検索結果を開いた直後 (デバウンス3秒＋取得時間) にヒットメールの本文が
  即座に表示されるか。
- 一覧のフィルタ切替 (未読のみ・アカウント絞り込みチップ・スレッド
  表示ON/OFF) 直後、新しく表示された行の本文プリフェッチが実際に走るか。
- 検索のタイピング中に連打取得が発生しないか (デバウンス/内容比較が
  ユニットテストの対象外のSwiftUI `@State`にあるため)。
- **対応手順**: `scripts/verify-*.sh`/`.claude/skills/verify/SKILL.md`の
  手順でシミュレータを起動し、複数アカウントを登録した状態で①検索して
  ヒットを開く、②未読のみ表示等のフィルタを切り替える、③検索ボックスに
  連続して文字を入力する、の3パターンを目視確認する。

## 画面構造改修バッチ (Task #33): スレッド選択画面・圧縮ヘッダ・カテゴリ
## 優先メニューの実機目視確認

**実装状況**: スレッド選択画面 (`ThreadEntryView`/`ThreadSelectionView`)・
圧縮ヘッダ (`MessageHeaderCompactView`)・カテゴリ優先フォルダメニュー
(`FolderListSheet`) の3点セットを実装し、`make test`/`make ios`/`make
mac` すべて green (OTA配信用の Release アーカイブビルドも成功)。実装中に
追加報告された「スレッド表示をオフにしてるのに、スレッドで表示される
ことがある」も原因特定・修正・回帰テスト追加まで完了した。詳細は
`docs/design-system.md`「画面構造改修バッチ」節参照。

**未確認 (このセッション固有のシミュレータ既知事象により)**:
「design-phase-3: 翻訳の実機 (Simulator でない) 確認」節と全く同じ
`MailCoreErrorDomain error 1` (`接続に失敗しました: サーバーに接続でき
ません`) — アカウント追加の「接続テスト」がシミュレータから一貫して
失敗した (ホスト側からは同じ `localhost:1143` へ Python の素の socket
接続で疎通確認済みなので Dovecot 自体は正常。シミュレータ再起動
(`simctl shutdown`/`boot`) を試したが解消せず、この既知の問題自体を
このバッチでは調査・修正していない — 対象範囲外と判断)。このため以下は
**実機シミュレータでの目視確認 (スクリーンショット) が一切できていない**:

- 「1通スレッドで選択画面をスキップ」「2通以上で選択画面」「本文画面に
  スレッドスタック無し」の実際の画面遷移。
- 圧縮ヘッダが実際に約2行に収まって見えること。
- カテゴリ優先メニューの実際の見た目 (セクション見出し・横断ビュー行・
  セグメントコントロール)。
- 既存 UITest (`OtegamiM4ThreadDetailUITests`を含む、このバッチで更新した
  一式) が実際にシミュレータ上で green になること — ビルドは通ることを
  確認済みだが (`-only-testing:` 実行がテスト実行フェーズまで到達し、
  アカウント追加の接続テストで止まった)、この既知のネットワーク不調に
  阻まれ実行結果の green/red は未確認。

- **対応手順**: 上記「design-phase-3: 翻訳の実機確認」節の対応手順と同じ
  — このシミュレータのネットワーク不調が解消した後 (または別の
  シミュレータ/実機で)、`make mailstack-up && make mailstack-seed` して
  から `xcodebuild ... -only-testing:OtegamiUITests/OtegamiM4ThreadDetailUITests
  test` 等を実行し、`.xcresult` のスクリーンショット/ログで確認する。

## Task #44: Gmail「すべてのメール」新着反映バグ修正の実機確認

**実装状況**: 「Gmail の『すべてのメール』を表示/pull-to-refreshしても
直近の新着が反映されない」実機報告を受け調査した。差分同期ロジック
自体 (`MailboxSyncer.incrementalSync`) は`FakeIMAPSession`/実 dev
mailstack Dovecot の両方で非INBOXメールボックスへの新着取り込みを再
確認でき、バグは見つからなかった。真因はコードレベルで特定: メール
ボックスを選択しただけでは一切同期がトリガーされず (`.onChange(of:
selection)`はページングリセットのみ)、非INBOXメールボックスが新着を
拾える経路が「そのメールボックス表示中の明示的なpull-to-refresh」
だけだった (起動時/フォアグラウンド復帰時の自動同期、フォアグラウンド
IDLEループはいずれも`SyncScope.inboxOnly`固定)。これに Gmail の「すべて
のメール」がサーバー側でINBOXよりやや遅れてインデックスされる既知の
挙動が重なると、「今開いてrefreshしても間に合わず、後で反映されても
再訪して明示的にrefreshし直さない限り永遠に取り込まれない」という
報告と一致する。

修正: `MessageListView`に、メールボックス選択時 (コールドランチで復元
された初期選択も含む) から、その画面を見ている間5分おきに自動で差分
同期を再試行し続ける`syncSelectedMailboxOnAppear()`を追加した (選択を
変える/画面が消えると自動キャンセル、エラーは無言)。詳細は
`docs/qa-findings.md`「Task #44: Gmail の『すべてのメール』に直近の新着が
反映されない実バグの調査と修正」。

- **理由**: シミュレータのアカウント追加不調 (`MailCoreErrorDomain
  error 1`) が継続中のため、実 Gmail アカウントでの UI 経由の動作確認が
  できていない。`FakeIMAPSession`/実 Dovecot 統合テストのみでの検証。
- **ブロックしている機能**: 実 Gmail アカウントで、他のメールクライアント/
  Web UI から新規メールを受信した直後に「すべてのメール」を開いた際、
  (a) すぐには出ない (Gmail 側のインデックス遅延) が (b) 数分〜数回の
  自動再同期のうちに、ユーザーが何も操作しなくても表示されるようになる
  ことの実地確認。あわせて Gmail 側の「すべてのメール」インデックス
  遅延そのものの実測 (今回の修正が前提にしている遅延の実際の長さ)。
- **対応手順**:
  1. シミュレータのアカウント追加不調が解消 (または実機/別シミュレータ)
     したら、実 Gmail アカウントを追加する。
  2. 別クライアント (Gmail Web UI 等) から自分宛にメールを送るか、既存の
     メールを INBOX に残したまま「すべてのメール」を開く。
  3. 「すべてのメール」を開いた直後に出ていなければ、画面を開いたまま
     数分待つ (または一度他のメールボックスに切り替えてから戻る) — 自動
     で反映されることを確認する。手動 pull-to-refresh だけに頼らずに済む
     ことがこの修正の本質的な検証ポイント。
  4. ログ/計測が可能であれば、Gmail のインデックス遅延の実測値を記録し、
     `selectedMailboxResyncInterval` (現在5分) がその遅延に対して妥当か
     見直す。

## 公開時に必要な対応 (まとめ)

以下は「今すぐ開発を止める理由」ではなく、実際に公開・配布する段になったら
対応が必要な項目 (計画書の合意事項)。

- **(完了) リポジトリの public 化**: `github.com/m-tkg/otegami` は既に
  public リポジトリになっている (ローカルの作業ディレクトリ名 `mailapp`
  は単なる clone 先ディレクトリ名でリポジトリ名とは無関係)。個人の
  ホスト名・IP・実機の UDID・自宅サーバーの構成詳細をドキュメントに
  書き込まないことは public 化後も引き続き徹底すること。
- **Google OAuth の審査**: 各自の Client ID でのテスト利用には審査不要だが、
  作者本人が配布ビルド (App Store/TestFlight) を出す場合は Google の OAuth
  審査が必要になる (`docs/oauth-setup.md`)。
- **macOS ビルドの配布**: `make mac-app` で `dist/Otegami.app` を生成できる
  ようになった (M10) が、現状は開発チームでのアドホック署名のまま。
  Developer ID 署名 + notarization (Gatekeeper 対応) は未実施 — 自分の
  Mac 以外に配る場合はこの対応が必要。
- **サードパーティライセンス表記の保守**: 依存追加/更新時は
  `NOTICE` (ライセンス種別・著作権表示の一覧) の追記漏れがないか
  `Package.resolved` と突き合わせて確認する。実バイナリを配布する際は
  Apache-2.0 系依存についてライセンス全文 + NOTICE 内容の同梱が必要
  (現状はソース配布のみなので `NOTICE` ファイルでの記載に留めている)。
- **iOS でデフォルトのメールアプリになる (Task #48)**: `com.apple.developer
  .mail-client` entitlement は Apple の個別承認制で、申請から承認までの
  リードタイムが読めない。実装 (mailto: ハンドリング、entitlement の
  ビルド時 opt-in フラグ、設定画面の導線) は完了しているが、entitlement
  自体は未承認のため実機で「実際にシステム全体のデフォルトに選べるか」は
  まだ確認できていない。申請手順・承認後の有効化手順は
  [docs/default-mail-app.md](docs/default-mail-app.md) 参照、申請自体は
  [HUMAN_TASKS.md](HUMAN_TASKS.md) の該当項目。macOS 側は entitlement
  不要 (`CFBundleURLTypes` の宣言のみで足りる) なのでこの制約の対象外。
- **Xcode Cloud/TestFlight 配布の準備 (Task #49)**: `ci_scripts/`
  (`apps/Otegami/ci_scripts/ci_post_clone.sh`)・`ITSAppUsesNonExemptEncryption`・
  `CFBundleVersion` の CI 連動は実装・ローカル検証済み。**App Store
  Connect 側のワークフロー作成・cloud signing・実際の TestFlight 配信は
  この環境から実行できないため未検証**。手順は
  [docs/xcode-cloud.md](docs/xcode-cloud.md) にまとめ、着手手順は
  [HUMAN_TASKS.md](HUMAN_TASKS.md) に追記した。
  - **(対応済み: Task #57) 当時未解決だった既知の懸念**: TestFlight は
    必ず Distribution (App Store) プロビジョニングプロファイルで
    署名されるが、`AppEnvironment.enablePushNotifications` は otegami-relay
    への登録時に `.sandbox` を固定で送っており、TestFlight ビルドでは
    プッシュ通知が届かなかった。実行時に `embedded.mobileprovision` の
    `aps-environment` を判定して sandbox/production を送り分けるよう
    修正済み (`APNSEnvironmentDetector` — 署名そのものは entitlements の
    `aps-environment` ソース値と無関係に Automatic signing 下で常に成功
    していた、心配していた署名エラーは実際には発生しなかった)。詳細は
    `docs/xcode-cloud.md`「既知の注意点」節、実機での最終確認は
    `HUMAN_TASKS.md` 参照。

## Task #147: 本文の後着で要約/翻訳ボタンが有効化されない修正 — 実機での
## end-to-end確認

**実装状況**: `MessageView.load()`が開いた時点の一回きりの本文取得で
完結し、その後にローカルDBへ届いた本文 (バックグラウンドプリフェッチの
書き込み等) を二度と観測しない不具合 (#64が導入した`bodyRecord != nil`
ゲート自体は正しいが、それを更新する経路が`load()`一本しかなかったのが
根本原因) を修正した。`messageBody`行への`ValueObservation`を張る
`observeBodyRecordChanges()`/`applyObservedBodyRecordIfNeeded(_:)`を
`MessageView`に追加し、`load()`とは別のもう1本の`.task(id: messageId)`
として並走させる — 「反映する価値のある変化か」の判定だけを
`SyncEngine.MessageBodyObservationGate.shouldApply(current:incoming:)`
という純粋関数に切り出し、`MessageBodyObservationGateTests`(5ケース)で
ユニットテスト済み。`make test`/`make ios`green、既存の`html-0`シナリオ
での目視回帰確認 (要約/翻訳ボタンが従来どおり表示される) も実施済み。

**残っているのは実機でのend-to-end確認のみ**: この不具合は「本文取得中
に開く→取得完了と*非同期に*競合する別経路 (バックグラウンドプリ
フェッチ) が後からDBへ書き込む」という、タイミングに依存した競合状態
でしか再現しない。tap-freeの`scripts/verify-screen.sh`は単発スクリーン
ショットしか撮れず、この「開いた後に本文が遅れて届く」という時間差
シナリオを決定的に再現するフィクスチャ (未取得の本文を持つメッセージを
挿入しつつ、数秒後にバックグラウンドプリフェッチ相当のDB書き込みを
別経路から起こす) は今回追加しなかった — Task #64の「本文読み込み完了
までボタン非表示」項目が「数十ms〜数百msの過渡状態」を理由に静的
スクリーンショット1枚での検証を諦めコードレビューに留めたのと同じ理由
による判断。

- **対応手順**: 実機で「読み込みに時間がかかる (電波が弱い等) メール」
  を開き、要約/翻訳ボタンがグレーアウトしたまま表示された状態で
  そのまま待ち、本文が表示され次第 (アプリを再起動せずに) ボタンが
  自動的に有効化されることを確認する。バックグラウンドプリフェッチ
  (b7003ab) がヒットしやすい統合受信トレイの未読メールで試すのが良い。

## Task #149: スレッド表示で要約/翻訳ボタンが一瞬有効→無効に戻る修正 —
## 実機での連続切替確認

**実装状況**: `docs/design-system.md`「Task #149」節参照。根本原因は
アコーディオン切替のアニメーション中、畳まれる側の`MessageView`が
`onDisappear`発火まで生き続け、その残骸 (または Task #147 の観測の
遅延配信) が新しく展開された行の正しい状態を後から上書きしていたこと。
`ThreadDetailView.messageRow(for:containerSize:)`の`onAIFeaturesStateChange`
クロージャに「書き込み時点の`messageId`と現在の`expandedMessageId`が
一致するか」の受け手側ガードを追加 (根本修正) し、`MessageView`/
`ThreadMessageRow`に`isToolbarTarget`フラグを追加して送り手側でも
非対象インスタンスがそもそも書きに行かないよう防御した。`make mac`
green。

**残っているのは実機での連続切替確認のみ**: この不具合は「アコーディオン
アニメーション中の一瞬の競合状態」でしか再現しないタイミング依存のバグ
のため、Task #147 と同じ理由でtap-freeの単発スクリーンショットでは決定
的に再現・確認できない。

- **対応手順**: 実機で複数メッセージを含むスレッドを開き、展開する行を
  素早く連続して切り替える (特に本文が既にキャッシュ済みのメールと
  未取得のメールを交互に)。切り替えるたびにフッターツールバーの要約/
  翻訳ボタンが「一瞬有効になって直後に無効へ戻る」ことなく、常に**今
  展開している行**に対応した状態 (有効/無効、要約済みなら`.active`色等)
  で安定して表示されることを確認する。

## Task #150: 「スレッド一覧で同じメールが2個ずつ表示される」— 原因未特定

**調査状況**: `docs/qa-findings.md`「Task #150」節参照。OTA `c93bec3`
直前の #141 (`role == .all`の非Gmail緩和)/#142 (`pinnedOnly`追加) を
疑って `ThreadQuery`/`MessageQuery` の SQL を精査し、「同一スレッドが
INBOX と Archive の両方にメッセージを持つ」フィクスチャで
`unifiedInboxRequest`/`unifiedInboxFlatSummaries` を role (`.inbox`/
`.archive`/`.all`) × `pinnedOnly` (true/false) の全組み合わせで検証する
回帰テストを追加したが、**`main` に対して green のまま** — 再現しな
かった。`scripts/verify-screen.sh list`/`list-all-mail` のスクリーン
ショット目視でも重複行は確認できなかった。アプリコードへの修正は
行っていない (回帰テストのみ追加・コミット済み)。

- **確認をお願いしたいこと**: 実機で重複が見えたときの詳細
  (a) どの画面か (ハンバーガーメニュー最上部「すべての受信トレイ」/
  特定カテゴリの横断ビュー/「すべてのメール」/個別アカウントの特定
  フォルダ)、(b) 一覧表示設定 (スレッドまとめ表示 or 「スレッドに
  まとめない」フラット表示)、(c) 「未読のみ表示」「フラグ付きのみ
  表示」トグルの状態、(d) 該当アカウントの種類 (Gmail/それ以外) と
  台数。これが分かれば SQL 層以外 (同期・UI描画側) も含めて再度絞り
  込める。

## Task #148: 「詳しく要約」の実機シミュレータでの目視確認

**実装状況**: `docs/translation.md`「Task #148」節参照。AI要約シートの
「再生成」を`Menu`化し、「再生成」(既存、`sentenceCount`=2) に加えて
「詳しく要約」(`sentenceCount`=10) を追加した。`summarizeInstructions`
の■要約パートの分量指示に詳細版向けの文言分岐を追加し、実FM
(`scratchpad/summary-repro`、`SUMMARY_REPRO_SENTENCE_COUNTS=10`) で
複数フィクスチャ・複数回実行して3パート構造の反復なし・引用混入なし・
新規本文の水増しなしを確認済み。この検証中に見つかった
`SummaryOutputSanitizer`の新しい漏れパターン (パーツの間に割り込む
ラベル反復) も修正しユニットテスト追加済み。`make test`/`make mac`
green。

**残っているのは実機/シミュレータでの目視確認のみ**: 本タスクのセッション
では`scripts/verify-*.sh`によるtap-free経路でのシート/`Menu`表示自体の
スクリーンショット確認は行っていない (実FM呼び出しを伴う機能のため、
`docs/verify.md`記載のシミュレータ既知不調 (Foundation Models error -1)
の影響を受けうる)。

- **対応手順**: 実機で任意のメールを開き、AI要約シートを開いた状態で
  右上の「再生成」をタップして`Menu`(「再生成」/「詳しく要約」の2項目)
  が正しく表示されることを確認する。「詳しく要約」を選び、■要約パート
  が通常の「再生成」より詳しい (本文の主要な話題を漏れなく拾っている)
  内容になること、■要約/■伝えたいこと/■アクションの3パート構造が
  崩れていない (ラベルの重複・欠落が無い) ことを確認する。長文メール
  (要約が map-reduce 経路を踏むもの) と短文メールの両方で試すのが良い。

## Task #153: スレッド全体のAI要約シートの実機/シミュレータでの目視確認

**実装状況**: `docs/translation.md`「スレッド全体のAI要約 (Task #153)」
節参照。複数メッセージのスレッド (アコーディオン表示) を開いたときの
ナビゲーションタイトル「スレッド」化と、新設のツールバー要約ボタンは
`scripts/verify-screen.sh thread-accordion`のスクリーンショットで目視
確認済み。要約の生成呼び出し (`TranslationService.summarizeThread`/
`summarizeThreadDigest`) は`scratchpad/summary-repro`
(`SUMMARY_REPRO_MODE=thread`/`thread-long`) で実FoundationModelsに対して
計4回実行し、■経緯/■現状の2パート構造・差出人名の非創作・分量を確認
済み。`make test`/`make mac` green。

**残っているのは、要約シート自体 (生成中/完成/失敗の各表示、「再生成」
ボタン) をタップ経由でスクリーンショット確認すること**: 本タスクの
セッションでは新設のツールバーボタン (sparkles アイコン) が表示されて
いることまでは確認したが、それをタップしてシートが実際に開き、
`SummaryText`によるレンダリング (■経緯/■現状の各行が太字ラベル+本文
という見た目になっているか) がスクリーンショットで意図通りかは未確認 —
`message-source`シナリオの`-uitestsOpen...Directly`パターンに倣ったタップ
不要の直接遷移シナリオを追加すれば`scripts/verify-screen.sh`だけで撮れる
はずだが、本タスクでは時間の都合で見送った。

- **対応手順**: 実機で複数メッセージのスレッド (アコーディオン表示) を
  開き、ナビゲーションタイトル横の sparkles アイコンをタップする。
  生成中はスピナー表示、生成完了後は「■経緯」「■現状」の2つの見出しが
  太字で、それぞれの本文が読みやすく表示されることを確認する。右上の
  「再生成」をタップして再度生成が走ることも確認する。FoundationModels
  が使えない端末 (Apple Intelligence 無効) の場合は「要約に失敗しました:
  …」というエラー文言が表示されることを確認する (クラッシュ・無限
  ローディングにならないこと)。

## Task #156: 作成画面 iOS フラットデザイン化 — Cc/Bcc展開・署名行・添付行の実機確認

**実装状況**: コーディネータ経由のデザイン指示 (2026-07-29、Sparkダーク
モード参考) を受け、iOS の`ComposerView`を`Form`/`Section`のカード的な
グループ化からミニマムなフラットデザイン (`ScrollView`+`VStack`、区切りは
`.otegamiRowDivider()`か余白のみ) へ再構成した。差出人/宛先は「ラベル:
フィールド」表記、宛先行右端の「Cc: Bcc:」丸角アウトラインピルタップで
Cc/Bcc行を展開 (すでに値が入っていれば最初から展開済み表示 —
`OtegamiMailtoUITests`の無タップ前提を壊さない設計)、件名/本文はプレース
ホルダのみ、署名は「署名なし」/選択中の署名名を表示するタップ可能な行、
添付は`.onDelete`の代わりに各行へ明示的な削除ボタンを追加。macOSは指示
どおり既存の`Form`ベースのレイアウトを維持 (スコープ外)。

`make test`/`make mac`/`make ios`すべてgreen (`MessageBuilderTests`の
日本語ラウンドトリップは既知flakeとして無視)。`scripts/verify-screen.sh
composer-richtext`でライト/ダーク両方スクリーンショット確認済み — ただし
このシナリオのフィクスチャにはアカウント/署名/添付が無いため、確認できた
のは「差出人が空/宛先が空/Cc・Bccピルが見える/件名プレースホルダ/本文
プレースホルダ/添付ボタンのみ」の初期状態だけ。**タップを伴う以下の状態は
未確認**:
- 「Cc: Bcc:」ピルを実際にタップしてCc/Bcc行が展開される見た目
  (`isCcBccExpandedByUser`の切り替わり)。
- 署名が1件以上ある状態での「署名なし」/選択中署名名の行の見た目、および
  タップでのメニュー表示・切り替え。
- 添付が1件以上ある状態での行表示・削除ボタンの見た目。
- mailto:プリフィル/全員に返信/送信キャンセル復元でCc/Bccに値が入っている
  ときに最初から展開済みで見えること (ロジック上は保証されているが実機/
  シミュレータでの目視は未実施)。

実機で新規作成画面を開き、上記4点をタップ操作で確認すること。

## Task #158: macOS「アップデートを確認」機能 — フルビルド・実機確認が残る

**実装状況**: GitHub Releases APIを見てアップデートの有無を知らせる
macOS専用機能を実装済み。バージョン比較 (`SemanticVersion`/
`UpdateAvailability`、`OtegamiCore`) は`swift test`で単体テストがgreen
(パース・SemVer優先順位・stable/pre-release混在・draft除外を網羅)。
ネットワーク層・UI (`apps/Otegami/Sources/Features/Updates/`) とメニュー
配線 (`OtegamiCommands.swift`の「アップデートを確認…」、`OtegamiApp.swift`
の専用`WindowGroup`) も実装済み。詳細は`docs/design-system.md`「Task
#158」節参照。

**未検証な理由**: 実装中、並行してTask #159 (翻訳エンジン差し替え) が
`AppEnvironment.swift`を編集中で、`summarizationService`まわりの初期化
順序が一時的に壊れた未コミット状態だった。そのため`make mac`のフル
ビルドが最後まで通らなかった — ビルドログを個別確認し、このタスクで
新設/変更した5ファイルはどれもコンパイルエラーを出しておらず、エラーは
全て`AppEnvironment.swift`側 (Task #159の作業途中状態) に限定されている
ことは確認済み。

**次にやること** (Task #159がコミットされ`make mac`がgreenに戻ってから):
- debugビルドをローカル起動し、「Otegami」アプリメニューに
  「アップデートを確認…」が出ること、クリックしてダイアログ (確認中/
  最新版/更新あり/失敗) が正しく表示されることをスクリーンショットで
  確認する。
- 実際の`m-tkg/otegami`リポジトリには`v1.1.0-beta`というpre-releaseタグ
  が存在する。通常クリック (安定版のみ) では検出されず、optionキーを
  押しながらのクリックでは検出される、という仕様どおりの挙動差を実地
  確認する。
- 「ダウンロードページを開く」ボタンで実際にRelease ページが開くこと。

## Task #129/#156/#161: 作成画面リッチテキスト化 — HTML送信配線・第2段の書式・下部バー再構成は完了、実機確認が残る

**実装状況 (#129 第1段)**: 本文エディタを SwiftUI `TextEditor` から
`RichTextEditor` (`UITextView`/`NSTextView` + `NSAttributedString`) へ移行し、
太字/イタリック/下線/打ち消し線/番号付きリスト/箇条書きリスト/インデント
増減/書式クリアのインラインフォーマットバー (`RichTextFormattingBar`) を
追加した。`OtegamiCore.RichTextDocument`/`RichTextHTMLCoder`
(AttributedString相当の中立モデル⇄HTML、UIKit/AppKit非依存) のラウンド
トリップ単体テスト16件、`MailCoreMessageBuilder`に`ComposeDraft.htmlBody`
対応 (設定時`multipart/alternative`を生成) の単体テスト3件を追加。

**実装状況 (Task #156, HTML送信の最終配線)**: 上記が未配線のまま残していた
ギャップを解消した。
  1. `OutboxMessageRecord.htmlBody: String?` 列を追加
     (`AppDatabase`のv32マイグレーション、既存行は`NULL`のままバックフィル
     不要 — `.send`側は`ComposeDraft.htmlBody`がoptionalなので問題ない)。
  2. `ComposerView.send()`が`bodySnapshotString`
     (既存の`hasUnsavedChanges`比較用に計算していたHTMLレンダリングをそのまま
     再利用) を`OutboxMessageRecord.htmlBody`/`PendingSendDraftSnapshot
     .htmlBody`にセット。
  3. `OpQueueProcessor.swift`の`.send`ケースの`ComposeDraft(...)`構築に
     `htmlBody: outbox.htmlBody`を追加。
  4. C7送信キャンセルの復元 (`PendingSendDraftSnapshot`経由で
     `ComposerView.loadCancelledSend(_:)`が再度Composerを開く経路) でも
     書式が保持されるよう、新規`RichTextAttributedString
     .makeAttributedString(from:)` (`makeDocument(from:)`の逆変換) を追加し、
     `snapshot.htmlBody`があれば`RichTextHTMLCoder.decode(html:)`経由で
     `NSAttributedString`を復元するようにした。

これで「受信側 (Gmail web 等) で書式が再現される」という受け入れ条件が実際
の送信経路で満たされる。dev/mailstackのMailpit REST APIに対する統合テスト
(`OutboxHTMLSendIntegrationTests.swift`、`OTEGAMI_TEST_IMAP_HOST=localhost
swift test --filter OutboxHTMLSendIntegrationTests`) で、太字書式付きの
`OutboxMessageRecord`が実際に`multipart/alternative`として送信され、
Mailpitがデコードした`HTML`フィールドに`<b>`タグが残ることを確認済み
(green)。Outboxラウンドトリップの単体テスト
(`OutboxMessageRecordTests.swift`) も追加。`make test`/`make mac`/`make ios`
すべてgreen。

**Task #161で解消した範囲 (以下は完了、参考として残す)**:
- 書式拡張: `RichTextRun`にフォントサイズ (小/標準/大/特大)/文字色/背景色
  (ハイライト、DesignSystemトークンと独立した7色プリセット)/リンクを追加、
  `RichTextHTMLCoder`が`font-size`/`color`/`background-color`インライン
  スタイル+`<a href>`として符号化・復号 (ラウンドトリップ単体テスト追加)。
  引用ブロックは既存のインデント機構と別に、書式バー専用の引用トグル
  ボタンを追加。
- 下部バーのSpark準拠再構成 (iOS): `RichTextFormattingBar`の常時表示を
  やめ、下部バーの「T」ボタンでトグル表示に。添付/テンプレートの
  アクションも下部バーへ移動。macOSは対象外のまま (Form + 常時表示の
  バーを維持)。
- `DraftMessageRecord`/`saveDraft()`への`htmlBody`追加 (下書き保存経路、
  v33マイグレーション)。`OpQueueProcessor`の`.saveDraft`レプレイにも配線。

**Task #156時点で意図的に対象外のまま残した範囲 (Task #161で解消)**:
- ~~`DraftMessageRecord`/`saveDraft()`への`htmlBody`追加 (下書き保存経路)。
  Task #156のスコープは送信経路 (`OutboxMessageRecord`) のみで、下書き
  テーブルは他エージェントの担当領域と重ならないよう明示的に対象外にした。
  下書きを再開して送信しても、いまの`send()`は毎回そのときの
  `attributedBodyText`からHTMLを計算し直すので実害はない (下書き保存中の
  書式自体はUI上保持される — 失われるのは「保存済み下書きをそのまま
  サーバへPUSHする`OpQueueKind.saveDraft`のレプレイ」経路のHTML化のみ)。~~
- ~~第2段の書式 (フォント選択/文字色/背景色/リンク挿入/引用ブロック、
  下部バーのSpark準拠再構成) は着手していない — 余力があれば次のタスクで。~~

- **対応手順 (実機での目視確認、未実施)**: 実機またはシミュレータで新規
  作成画面を開き、本文にいくつか書式 (太字/イタリック/下線/打ち消し線/
  箇条書き/番号付きリスト/インデント) を実際にタップで付けてみて、
  フォーマットバーのハイライト状態が選択範囲に追従すること、リスト/
  インデントが見た目どおり反映されることを確認する (#129のときから未検証
  のまま — タップ操作を伴うためこのセッションでも未検証)。続けて、
  自分宛てに書式付きメールを送信し、Gmail側 (Web) で太字/イタリック/
  下線/打ち消し線/リストが実際に再現されることを確認する — 統合テストは
  Mailpitの`HTML`フィールドで書式タグの残存を確認済みだが、実際の
  Gmail/Outlookなど実メールクライアントでの表示確認はまだ。

- **Task #161 追加分の実機確認ポイント (未実施 — 同じくタップ操作を伴う
  ためシミュレータでは粘らず未検証のまま出荷)**:
  1. 下部バーの「T」ボタンをタップして書式バーが開閉すること
     (`scripts/verify-screen.sh composer-richtext`/`composer-richtext-open`
     でビルド+タップ無し表示は確認済み — ライト/ダーク各2枚、
     `/tmp/otegami-verify/composer-richtext-{before,after}-{light,dark}.png`)。
  2. フォントサイズメニュー (小/標準/大/特大) を選択すると本文の該当範囲
     が実際にそのサイズで表示されること。
  3. 文字色/ハイライトメニューから色を選ぶと本文の該当範囲に実際に色が
     つくこと (7色プリセット共通)。「デフォルト」/「ハイライトなし」で
     解除できること。
  4. リンクボタン: 文字列を選択してリンクを追加→保存済み下書き/送信後の
     表示で実際にタップ可能なリンクになっていること。既存リンクの上に
     カーソルを置いた状態でボタンを押すと編集/削除ができること。
  5. 引用ボタン (`text.quote`アイコン) をトグルすると段落がブロック
     引用として字下げ表示されること。
  6. 上記を組み合わせたメールを自分宛てに送信し、Gmail (Web) で
     フォントサイズ/文字色/ハイライト/リンク/引用がすべて再現されること
     (HTMLCoderのラウンドトリップ単体テストでは確認済みだが、実メール
     クライアントでの表示確認はまだ)。
  7. 下書き保存→再度開く→書式 (今回追加分含む) が維持されていること
     (`DraftMessageRecord.htmlBody`、v33マイグレーション)。

## Task #159: メール翻訳を Apple Translation フレームワークへ切替 — 実機確認未実施

`docs/translation.md`の Task #159 節参照。`make test`/`make mac`/`make ios`
はいずれも緑だが、`AppleTranslationService`の実エンジン部分
(`Translation.TranslationSession`本体を使う翻訳呼び出し) は自動テスト不
可・シミュレータでの動作確認も未実施 (`FoundationModelsTranslationService`
の既知のシミュレータ不調 — `error -1` — と同じ領域に該当する可能性が高
いと判断し、今回は試みていない)。実機での確認をお願いしたい点:

1. **通常の翻訳**: 英語メールを開き、翻訳ボタン (常時有効) をタップして
   実際に日本語訳が表示されること。
2. **言語パック未ダウンロード時の誘導**: (可能であれば) 翻訳済み言語を
   一度も使ったことがない状態の端末で翻訳ボタンをタップし、システムの
   言語ダウンロードプロンプトが実際に表示される、または明確な「ダウン
   ロードが必要です」というエラー文言が出ること。
3. **誤判定メールの自動翻訳**: 実機フィードバックの元になった、明らか
   に英語なのに`NLLanguageRecognizer`が非日本語・非英語に誤判定するメー
   ル (Okta 通知など) で、自動翻訳が実際に (手動タップ無しで) 起動し、
   正しく翻訳されること。

**今回スコープ外にした改善案 (将来検討)**: `Translation
.TranslationSession.Response.sourceLanguage` (実SDKで存在確認済み) を
使い、自動翻訳の起動ゲート自体を「実際にエンジンが検出した言語」だけで
判定する設計 — 今回は`MessageTranslator`/`MessageView`側への新しい状態
受け渡し (「この自動翻訳は事後的に見るとスキップすべきだった」という
判定結果の伝播) が必要になり、タスク範囲を超えると判断して見送った。
`docs/translation.md`の Task #159 節「自動翻訳の言語判定」参照。

## Task #145: 言語/ローカライズ周りの精査 — 見送った点

`docs/localization.md`の Task #145 節参照 (見つけた英語残り・xcstringsドリ
フト解消・XCUITestのロケール依存lookup対応の全体まとめはそちら)。ここには
このタスク中に見つけたが直さなかった点だけ記録する。

- **`OtegamiQASweepScenario2UITests.testBoundarySearchQueries`が現在の
  検索UIと乖離している疑い**: このテストは`app.searchFields.firstMatch`
  (システム標準の`.searchable`が生成する検索フィールド) を探すが、
  `MessageListView.swift`の`.searchable(text:prompt:)`は`#if os(macOS)`
  専用になっており (コード中のコメントが「iOSはもう`.searchable`を使わ
  ない、検索は`SearchScreenView`へ」と明言している)、`OtegamiUITests`は
  iOS専用ターゲット (`project.yml`の`platform: iOS`) — つまりこのテスト
  は今のiOS実装に対して`searchField.waitForExistence`が失敗する可能性が
  高い。ロケール依存lookup (`"No Results"`→`messageList.search
  .emptyState`識別子、`"Cancel"`→OR述語) はTask #145で修正済みだが、
  「検索フィールドの発見自体」を`SearchScreenView`/`SearchTopBar`の実際
  の構造 (カスタム`TextField`+`search.closeButton`) に合わせて書き直す
  作業はローカライズの範囲を超えるため見送った。次にこのテストを実行する
  機会があれば要確認・要書き直し。

- **`make mac`/`make test`が現状赤い件について**: Task #145の作業中、
  同じワークツリー上で別のエージェントが`TranslationService
  .summarizeThread`のクロージャ引数を`(current, total)`から
  `ThreadSummaryProgress`単一引数へ変更する作業を並行して進めており
  (`packages/OtegamiKit/Sources/OtegamiTranslation/`配下と
  `ThreadDetailView.swift`が未コミットのまま変更中)、呼び出し側の追従が
  終わっていない状態だったため`make mac`/`make test`がその箇所で赤に
  なっていた。Task #145の変更ファイル (このコミット群) はそれとは無関係
  — `swift build` (テスト抜き) の成功、変更ファイル個別の`swiftc -parse`
  通過、および変更内容が文字列リテラルの置き換えのみであることで確認
  済み。ビルドが緑になっているか、別途 (このタスクの変更を取り込んだ
  クリーンな worktree で) 確認してほしい。

## Task #165 (macOS 操作体系再設計): 実クリック検証が未完了

`make test`/`make mac`/`make ios` はすべて green (`make test`唯一の失敗
`MailTransportMailCoreTests`の日本語RFC822往復テストはこのタスクが一切
触れていないファイル由来で無関係)。

macOS 実機での実クリック検証 (`docs/verify.md`「macOS 検証 (M10)」節の
CGEvent/AX driver手法) に着手し、`OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT=1`
でアプリを起動、下書き一覧 (`DraftsView`) を開くところまでは確認できた
— が、下書き行を右クリックする直前に確認したところ、フロントモスト
プロセスが `Otegami` から `Google Chrome` へ変わっていた。このマシンは
隔離された CI サンドボックスではなく、ユーザー本人か他の並行エージェント
が同じ物理ディスプレイを同時に使っている可能性がある共有環境だと判明
— `CGEvent(...).post(tap: .cghidEventTap)`によるクリックはグローバル
HIDタップへの注入で対象PIDを指定できないため、フォーカスが移った後の
クリックは意図しないウィンドウに届く恐れがある。それ以上の座標クリック
は中断し、起動したテスト用プロセスは終了した (実際に誤操作した形跡は
確認していない)。

**ユーザーに引き継ぐ実機確認ポイント** (`docs/design-system.md`の
Task #165節の検証セクションに詳細な8項目チェックリストあり):
下書きの右クリック削除・⌫キー削除・ツールバー削除ボタン、メール一覧行/
スレッド内メッセージ行の右クリックメニューへの返信系追加、「メッセージ」
メニューバーの新規ショートカット (⌘E アーカイブ・⇧⌘U 既読未読・⇧⌘R
全員に返信・⇧⌘F 転送)、⌘E化で件名欄等への通常のタイピングに副作用が
無いこと、⌘F への検索ショートカット移動。

## Task #167 (SEC-B): ComposerView.parseAddresses への CRLF/NUL 検証追加を推奨

`CLAUDE-SECURITY-20260729-134850/CLAUDE-SECURITY-RESULTS.md` F9 (SMTP
CRLFインジェクション) の本修正は `MailCoreSMTPSession.sendMessage` /
`validateForSMTP(_:)` (トランスポート境界で CR/LF/NUL を含むアドレス・
表示名を throw で拒否) で完了済み — これがどの経路 (mailto: URL 由来、
IMAP ENVELOPE 由来、Composer 手入力由来) から来たアドレスに対しても
効く唯一の必須修正であり、脆弱性は既に閉じている。多層防御として
`MailtoURLParser.addressList(from:)` にも同種の検証を追加済み。

残っているのは多層防御としての「推奨」のみ:
`apps/Otegami/Sources/Features/Composer/ComposerView.swift` の
`parseAddresses` (`,` で分割し空白/タブのみトリム、CRLF はトリムしない)
にも同じ CR/LF/NUL 検証を入れると、ユーザーが手入力欄に何らかの経路で
制御文字混じりの文字列を貼り付けた場合、送信ボタンを押す前の UI 段階で
気づける。このファイルは並行エージェント (SEC-A) が編集中のため今回は
触れていない。次にこのファイルを触る機会があれば検討してほしい
(必須ではない — トランスポート層の修正だけで脆弱性自体は解消済み)。

## Task #176 (通知の内容トグル): 実機での通知表示は未検証

実機フィードバック 2026-07-30「通知にタイトル、差出人、本文の一部を出す
かどうかの設定を追加して」への対応 (`NotificationContentSettingsStore`/
`PushNotificationSettingsView`の「通知の内容」セクション/
`NotificationService.enrich(payload:)`) は `make test`/`make ios`/
`make mac`/`make check-localization` すべて緑、`NotificationEnrichment`の
純粋関数は8通りの組み合わせを含め単体テスト済み。

**未検証**: 設定画面 (`push-settings`シナリオ) のスクリーンショットは
`docs/verify.md`の既知不調に新しく追記した`simctl privacy grant
contacts`のハング (3回試行して打ち切り) により取得できなかった。加えて
「トグルを変更 → 実際にプッシュ通知が届いたときに表示内容が変わる」
という一番肝心な end-to-end の確認は、この Extension の性質上
(`docs/verify.md`のシミュレータ既知不調4節参照 — シミュレータ内 IMAP
接続は全滅する) シミュレータでは原理的にできず、実機でしか確認できない。

**ユーザーに引き継ぐ実機確認ポイント**:
1. 設定 → アカウントの設定 → プッシュ通知 を開き、「通知の内容」
   セクションに「差出人を表示」「件名を表示」「本文プレビューを表示」の
   3トグル (既定すべて ON) が表示され、footer に OS のプレビュー設定とは
   別物である旨の説明が出ていること。
2. プッシュ通知が有効な `.password` 認証アカウントで、3トグルを色々な
   組み合わせでオン/オフし、新着メールを送って実機に通知が届いたときの
   タイトル/本文が期待通りか (例: 本文プレビューだけ ON なら本文の先頭
   120文字程度が本文欄に出て、差出人・件名は出ない)。
3. 3つとも OFF にした状態で新着メールを送り、「新着メールがあります」
   という内容を伴わない通知になること。
4. 設定変更後、アプリを完全に終了してから (バックグラウンドに置くだけで
   なく) 新着メールを送っても、直前に変更した設定が反映されること
   (App Group 経由の反映がタイミングよく効いているかの確認)。

## Task #178 (文字色/ハイライト3点バッチ): タップを伴う操作は未検証

実機フィードバック 2026-07-30 (文字色パレットへの白黒追加/色見本の
可視化/「デフォルト」選択でダークモードの文字が黒くなるバグ) への対応
(`docs/design-system.md`のTask #178節に詳細) は `make test`(35件)/
`make mac`/`make ios`/`make check-localization` すべて緑。

**未検証**: 文字色/ハイライトメニューを実際にタップして開く・項目を
選ぶという操作そのもの (シミュレータのXCUITestタップ不達のため、
`scripts/verify-screen.sh composer-richtext-open`のtap-free経路では
書式バーの閉じたメニューボタンまでしか確認できない)。

**ユーザーに引き継ぐ実機確認ポイント**:
1. 新規作成画面の書式バーで文字色メニュー ("A"アイコン) を開き、
   「デフォルトの文字色」「赤」「オレンジ」「黄」「緑」「青」「紫」
   「グレー」「黒」「白」の9項目それぞれに、その色自体で塗られた丸い
   スウォッチが見えること (以前は全項目が無色の丸だった)。白・黒の
   スウォッチには細い輪郭線が付いて背景に埋もれないこと。
2. いずれかの色を選んだ状態で同じメニューを再度開くと、選択中の項目の
   タイトル先頭に「✓ 」が付いていること。
3. ライトモードで新規作成 → 何も装飾せず本文を入力 (黒っぽく表示される
   のは正常) → 文字色メニューで一度何か色を選び、その後「デフォルトの
   文字色」に戻す → 文字が黒いまま (ライトモードなので正常) であること。
4. **最重要**: ダークモードで新規作成 → 何も装飾せず入力した文字が白く
   表示されることを確認 → 文字色メニューで適当な色 (例: 赤) を選んで
   から「デフォルトの文字色」に戻す → 文字が白のままで黒くならない
   こと (このバグ修正の核心)。ハイライト (背景色) 側も同様に「ハイライト
   なし」に戻した後、透明に戻ること (変な色が残らないこと) を確認。
5. 3・4を選択範囲がある状態 (テキストを選択してから操作) と、選択なし
   (カーソルのみ、これから入力する文字への適用) の両方で確認。
6. 実際に色付き文字/ハイライトを含むメールを送信し、受信側 (Gmail等) で
   指定した色が正しく表示されること、「デフォルト」のまま送った部分は
   `color:`指定が付かず受信側の既定色で表示されること (送信元HTMLソースに
   `color:`が出ていないことは`make test`の単体テストで担保済みだが、
   実際のメールクライアントでの見た目は未確認)。

## Task #172: `OtegamiUITests`コンパイル修復 — 実行 (pass/fail) は未検証

前任セッションが直したコンパイル修復 (約40ファイル、詳細は
`docs/verify.md`のTask #172節) をこのセッションでコミット
(`8037cce`/`ebfebab`) し、`xcodebuild build-for-testing`で
**TEST BUILD SUCCEEDED**まで確認した。

**未検証 (次回セッションで確認すること)**:
1. `OtegamiAvatarSettingsUITests`等、個別テストクラスを
   `xcodebuild test -only-testing:OtegamiUITests/<クラス名>`で実際に
   実行した pass/fail。このセッションでは複数回試みたが、直前の編集で
   `OtegamiUITests`モジュールがフルリコンパイル対象になっており、
   数分待っても`ClangStatCache`/ビルド記述生成の段階からテスト実行
   フェーズまで到達しなかった (エラーではなく単に遅い/この開発機固有の
   ビルドの重さ)。ユーザー指示 (シミュレータで粘りすぎない) に従い
   打ち切った。
2. `OtegamiUITests`スイート全体を1回で流した場合の pass/skip/fail の
   全体像 (account/mailstack依存クラスが既知不調#1で意図通りskipされる
   か、等) も未取得。
3. 大規模な整理 (重複テストの統廃合、tap依存テストのtap-free方式への
   置き換え) はこのセッションのスコープ外。次回、上記1・2の実行結果を
   見た上で判断すること。

## Task #183: iCloud Archive の `UNIQUE constraint failed` 修正 — 実機で解決を確認済み

**2026-07-31 追記: 実機で解決を確認した。** 実際にこのバグを踏んで壊れて
いた端末に `30faa2e` を OTA 配信したところ、同期エラーが解消した (ユーザー
報告)。下記「未検証」の項目 1 (自己回復) はこれで満たされた。項目 2 (Task
#120 の対象操作全体の回帰) は引き続き通常利用の中で様子を見る。

詳細は`docs/qa-findings.md`のTask #183節。
`AccountSyncer.reconcilePendingRelocation`/`MessageRemoval.undo`の
書き込み先`(mailboxId, uid)`衝突ガード漏れを修正し、
`MessageRelocationConflict`に共有の衝突解決ポリシー (生存側へローカル
状態をマージして敗者側を破棄) を切り出した。回帰テスト3本 (`make test`
green) を追加し、修正前のコードに一時的に戻した状態で実際に失敗する
ことも確認済み。

**未検証 (実機での確認が必要)**:
1. このバグを実際に踏んで壊れている実機 (iCloud アカウントの Archive
   同期が`UNIQUE constraint failed`で失敗し続けている端末) に今回の
   修正を配信し、**次回の同期1回でエラーが解消し、Archive の一覧が
   重複なく正しく表示されるようになること**。単体テストは仮配置行の
   状態を人工的に再現したものであり、実機の実際のDBの壊れ方 (仮配置
   行が何行残っているか、既に本物の行と共存しているか等) が想定通り
   かは実機でしか確認できない。
2. 修正後、通常のアーカイブ/アーカイブ解除/迷惑メール/削除操作 (Task
   #120の対象範囲全て) が引き続き正常に動作すること (今回の変更は
   既存の仮配置ロジック自体は変えていないが、念のため)。
3. `MessageRemoval.undo`側の衝突ケース (`uidValidity`リセット等) は
   実機での再現が難しいシナリオのため、単体テストのみでの担保。

## Task #184: アーカイブ済みのメールの操作 — 画面確認が未検証

**実機フィードバック**:「アーカイブ済みのメールの操作について、ツール
バーにあるアーカイブボタンはアーカイブ解除ボタンにして欲しい。また、
そのメールに対してのアーカイブスワイプ操作もアーカイブ解除操作にして
欲しい。アイコンもそういうのがわかるデザインにして」。

詳細・判定ロジックの根拠は`docs/design-system.md`のTask #184節。要点:
一覧のスワイプ/macOSコンテキストメニューは Task #87 (1) で既に対応済み
だったため、今回の実装はスレッド詳細画面 (iOSフッターツールバー+「その
他」メニュー、macOSの行コンテキストメニュー、macOSの⌘E「アーカイブ」
メニュー項目) 側に限定。`ThreadDetailView.isThreadArchived`/`RootView
.isSelectedThreadArchived`が状態源、実処理は既存の`MessageRemoval
.commit(.unarchive, ...)`をそのまま再利用 (`SyncEngine`は無改修)。
`make test`/`make mac`/`make ios`/`make check-localization`すべて green。

**未検証 (実機/シミュレータでの目視確認が必要)**:
1. **画面自体を一度も目で見られていない** — `scripts/verify-screen.sh
   archived-message-detail`を3回試みたが、いずれも`docs/verify.md`の
   既知不調#6 (Task #173) と同じ症状 (`xcodebuild build`が無応答のまま
   進捗が一切出ない) で完了せず、ユーザー指示どおり打ち切った。以下は
   すべて実機/シミュレータでの確認が必要:
2. iOS: 既にアーカイブ済みのメール/スレッドを開く (Gmailなら「アーカイ
   ブ」から、もしくは「すべてのメール」でアーカイブ済み表示バッジ付きの
   行から) → 画面下部フッターツールバーのアーカイブアイコンが
   `tray.and.arrow.up`(トレイから上向き矢印) で「アーカイブ解除」表示に
   なっていること。タップして実際に受信トレイへ戻ること。
3. 同じメールを「…」(その他) メニューから開いたときも同じラベル/
   アイコンで「アーカイブ解除」項目が出ること。
4. 未アーカイブの通常メールでは従来どおり「アーカイブ」表示・
   `archivebox`アイコンのままであること (退行していないこと)。
5. macOS: スレッド一覧の行を右クリック (Task #87 (1) 既存分の再確認) と、
   詳細画面の折りたたみ行を右クリックした場合の両方で、アーカイブ済み
   メッセージには「アーカイブ解除」が出ること。
6. macOS: アーカイブ済みのスレッドを選択した状態で「メッセージ」メニュー
   (メニューバー) を開き、⌘E相当の項目が「アーカイブ解除」表示に
   なっていること。押すと実際に解除されること。未アーカイブのスレッド
   では「アーカイブ」のままであること。
7. スレッドに複数メールがあり一部だけアーカイブ済みの混在ケース (可能
   なら) — 「アーカイブ解除」を押したとき、既にアーカイブ済みの1通だけ
   が受信トレイに戻り、他の現役メールには影響が無いこと (`docs/
   design-system.md`のTask #184節「一部だけアーカイブ済みの判定」の
   根拠どおりの挙動になっているか)。
8. ピン留め済み+アーカイブ済みの組み合わせ (他クライアントでピン留め→
   アーカイブされた等、作れれば) — 「アーカイブ解除」が通常どおり成功
   すること (Task #163のピン留めガードは`.archive`のみ対象で
   `.unarchive`には掛からない設計)。

## Task #185: メール詳細画面に件名を表示 — 画面確認が未検証

詳細・判定ロジックの根拠は`docs/design-system.md`のTask #185節。要点:
`MessageHeaderCompactView`(iOS/macOS共通) のヘッダ先頭に件名
(`Text(verbatim:)`, `OtegamiFont.title()`, 2行まで折り返し後に省略) を
復活。`ThreadDetailView`のナビゲーションタイトルは変更していない (元々
の設計どおり、件名はメッセージ自身のヘッダ側で見せる)。`make test`/
`make mac`/`make ios`/`make check-localization`すべて green。

**未検証 (実機/シミュレータでの目視確認が必要)**:
1. **画面自体を一度も目で見られていない** — `scripts/verify-screen.sh
   html-0`を2回、`make ios`が生成済みの`.app`を使った手動`simctl
   install`/`launch`を1回、計3回試みたが、いずれも`docs/verify.md`の
   既知不調#6 (Task #173、Task #184が同日追記) と同じ症状
   (`Device already booted, nothing to do.`の直後で無応答) で完了せず、
   ユーザー指示どおり打ち切った。作業中`#184`/`#186`の2エージェントが
   同じ共有ツリー/シミュレータで並行してビルド・検証していたため、
   リソース競合の可能性が高い。以下はすべて実機/シミュレータでの確認が
   必要:
2. iOS: 一覧からメールを開く → 詳細画面ヘッダの差出人行の**上**に件名が
   1〜2行で表示され、本文の表示領域を過度に圧迫していないこと。
3. iOS: 件名が非常に長いメール (2行に折り返しても収まらない長さ) を開き、
   3行目以降が省略記号`…`で切れ、レイアウトが崩れないこと。
4. iOS: 件名が空/欠落しているメール (通常あまり無いが、あれば) で
   「(件名なし)」と表示されること。
5. iOS: スレッド (複数メール) のアコーディオンで、展開する行を切り替える
   たびに、展開された**その1通の**件名がヘッダに正しく追従すること
   (前に展開していたメールの件名が残ったままにならないこと)。
6. iOS/macOS 両方: ナビゲーションタイトル (画面上部) は引き続き「メール」
   /「スレッド (N)」のままで、件名がそこに重複して出ていないこと。
7. macOS: 3ペイン表示の詳細ペインでも同様に件名がヘッダへ表示されること
   (`OtegamiApp.swift`の`detailColumn`経由)。
8. ダークモードで件名の文字色 (`OtegamiColor.ink`) が背景に対して読みやすい
   コントラストになっていること (既存の差出人名と同じトークンなので
   回帰は無いはずだが未確認)。
