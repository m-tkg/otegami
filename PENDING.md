# PENDING — ユーザー対応待ち事項

このファイルは、開発を進める上でユーザー本人の判断・手動作業が必要になった
項目を記録する。実装は各項目をモック/スキップ/dev mailstack 代替で進めて
おり、開発の手を止めていない。都合の良いときに対応し、必要であれば
`Config/Local.xcconfig` 等の git 管理外ファイルに値を設定すること。

各項目の実装の設計判断・原因調査の詳細は、それぞれ `docs/design-system.md`
(UI変更)・`docs/qa-findings.md`(バグ調査)・`docs/icloud-sync.md`(iCloud同期)・
`docs/translation.md`(翻訳/要約)・`docs/relay-deployment.md`(プッシュ通知
リレー) 等に記録している。このファイルには「何が未検証で、次に何を確認す
れば良いか」だけを簡潔に記す。**解決・実機確認が済んだ項目はここから削除
する** — 経緯を追いたい場合は各 doc の該当節、または git log を参照。

同じ内容を「今日やることリスト」の形に行動単位で並べ替えたものが
[`HUMAN_TASKS.md`](HUMAN_TASKS.md) にある。

## 実機・実アカウントでの確認待ち

### Task #194 (Pull to refresh の進捗表示・キャンセル・非CONDSTORE経路の高速化): 実機での目視・体感確認が未実施

「Pull to refresh が長すぎて終わらない」への対応。非CONDSTORE フラグ
同期の未チャンク化バグ (`open-ended UIDRange`がチャンク化されず全件を
1本の`FETCH`で取っていた) を修正し、FLAGSのみのチャンク取得+進捗表示
(`SyncProgressBanner`)+キャンセル (`Task.checkCancellation()`ベース) を
実装した。`make test`/`make check-localization`/`swift build`(macOS)は
green。詳細・実測値 (dev mailstack 300通での payload サイズ比較):
`docs/qa-findings.md`「Task #194」節、UI設計: `docs/design-system.md`
「Task #194」節。

未検証:
- **`SyncProgressBanner`の実描画**: 同期中にのみ表示される一過性の
  ランタイム状態のため、`scripts/verify-screen.sh`のDB直接注入方式では
  再現できず、シミュレータのIMAP接続不能という既知不調もあり未確認。
  実機で pull-to-refresh (または macOS の「再同期」ボタン) を引いた際、
  一覧上部に進捗バナーが出ること・進捗が動くこと (非CONDSTOREアカウント
  ならパーセンテージ、それ以外は不定形スピナー)・「キャンセル」ボタンで
  同期が止まりバナーが消えること・キャンセル後にエラーアラートが出ない
  ことを確認してほしい。
- **非CONDSTORE経路の実プロバイダでの体感速度**: dev mailstack の
  Dovecot は CONDSTORE 対応 (QRESYNC も対応) のため、今回の主対象である
  `refetchAndDiffFlags`経路そのものは dev mailstack では一度も通らない。
  Gmail は CONDSTORE 対応 (QRESYNC 非対応、別経路) と既知だが、iCloud/
  Yahoo!/その他汎用IMAPプロバイダのどれが非CONDSTOREかは未確認。該当
  する非CONDSTOREアカウントをお持ちなら、大きめのメールボックス
  (数百〜数千通) でpull-to-refreshし、修正前後の体感速度差・Console の
  `flagSync: <mailbox> condstore=false`ログを確認してほしい。
- **キャンセル後の再同期が正しく再開すること**: 同期を途中でキャンセル
  した直後にもう一度pull-to-refreshし、キャンセル前に確定済みのフラグ
  変更が失われていないこと・キャンセルで打ち切った範囲が2回目の同期で
  正しく処理されることを確認してほしい (単体テストでは`FakeIMAPSession`
  で再現・確認済みだが、実サーバーでの再確認)。

### Task #190 (アカウントダイジェストの一括操作確認を`.alert`に変更、設定でオフ可能に): 画面の目視確認未達成

`AccountDigestView`(「アカウントでグループ化」表示) のスワイプ/コンテキスト
メニュー一括操作の確認を`.confirmationDialog`(iPad/macOSでは吹き出し
ポップオーバーになる) から`.alert`(常に画面中央) へ差し替え、「メール
一覧」設定に「一括操作の前に確認する」トグル (default ON) を追加した。
`make test`/`make mac`/`make ios`/`make check-localization`はすべて
green。詳細: `docs/design-system.md`「Task #190」節。

未検証:
- **iOS実機/シミュレータでのダイアログの見た目**: シミュレータでの自動
  確認 (2アカウントfixture + `-listDisplay.groupByAccount YES`起動引数 +
  行スワイプ) を2回試したが、スワイプ後に現れるはずのボタンが見つからず
  失敗 (原因未特定)。3回目は別エージェント (#192) の並行編集中の
  `SyncEngine/MailboxSyncer.swift`がその時点でビルド不能だったため
  ビルド自体が失敗し、そこで打ち切った。実機で「アカウントでグループ化」
  表示 (1a の「すべて」チップ→「アカウント別」) → 行をスワイプ →
  確認ダイアログが**画面中央**に出ること (吹き出し/ポップオーバーでは
  ないこと)、対象件数が文言に出ること、「削除」ボタンが赤字(destructive)
  であることを確認してほしい。
- **macOSは対象外**: `AccountDigestView`は`OtegamiRootView`
  (`MailScreenView`) 経由でのみ描画され、これはiOS専用
  (`OtegamiRootView`のdoc comment参照) — macOSではこの画面自体が
  そもそも表示されないため、確認のしようがない (見た目確認不要)。
- **設定トグルOFF時の実機確認**: 「一括操作の前に確認する」をOFFにした
  状態で一括操作 (アーカイブ/削除/迷惑メール) が確認なしで即座に実行され、
  実行後5秒のUndoトーストが正しく機能すること。

### Task #195〜#198: macOS レイアウト4件 — iOS実機での再確認と2端末同期確認が未実施

macOS の4件 (サイドバーの排他展開/一覧の未読のみトグル/検索・更新の
一覧側への移動/メールビューのツールバーコンパクト化) を実装。`make
test`/`make mac`/`make ios`/`make check-localization`はすべて green。
実機ビルド (`osascript`+`screencapture`) でmacOS側の見た目・排他展開・
絞り込み・ツールバーのコンパクト化はいずれも確認済み。詳細:
`docs/design-system.md`の各 Task 節 (#195/#196/#197/#198)。

未確認:
- **Task #196 (未読のみトグル) の iCloud 同期**: `unreadOnlyKey`は
  Task #89/#186 で既に同期対象になっている。今回 macOS に切替 UI を
  追加したことで「Mac で ON にすると iPhone 側も未読のみ表示になる」
  ことが実際に2端末間で反映されるか、実 iCloud・実2端末での確認が
  必要 (Task #186 節の未確認事項と同種)。
- **Task #198 のツールバーコンパクト化、iOS 側の実機/シミュレータでの
  見た目再確認**: コード変更は`#if os(macOS)`の外に一切無く`make ios`
  もビルドグリーンのため実害は無いはずだが、実機でのタップ感触・
  Liquid Glass表示との重なりなど、目視でのダブルチェックはできていない
  (`docs/verify.md`記載のシミュレータ既知不調のため未実施)。
- **Task #195 のサイドバー排他展開、狭いウィンドウ幅での見え方**:
  実機確認は幅1400〜1500ptのウィンドウで行った。ウィンドウをかなり
  狭くした場合のカテゴリ/アカウント見出しの折り返し・省略表示は
  未確認。
- **Task #197 の検索欄、日本語入力 (IME) での確認**: 実機
  スクリーンショットでは英数字クエリ (`OpenAI`) での絞り込みのみ確認
  した。実機での日本語 (かな漢字変換確定後) クエリでの絞り込みも
  念のため確認してほしい (今回の自動確認では IME 変換候補選択の自動化
  ができなかったため、値を直接セットして代用した)。

### Task #186: iCloud で設定全般を同期 — 実2端末間の確認未実施

表示・操作設定 (`settings.v2`)・署名テンプレート/作成テンプレート
(`templates.v1`) を iCloud KVS で同期する実装が完了 (macOS も iOS/iPadOS と
同条件で同期対象)。単体テストは green。詳細:
`docs/icloud-sync.md`「Task #186」節。

未確認 (実 iCloud・実2端末が必要、シミュレータでは検証不可):
macOS↔iOS/iPad 双方向の設定反映、今回追加した4設定 (リンクを開くブラウザ/
削除・アーカイブ後の挙動/送信取り消し秒数/デフォルトアカウント)、署名・
作成テンプレートの新規作成/編集/削除の反映、アカウントごとの最後に選んだ
署名、2端末オフライン編集からの競合解決 (last-writer-wins)。あわせて
Task #89 (表示設定同期) の再インストール後復元も未確認のまま。

### Task #182: macOS アプリ内アップデート — 実際の差し替え未確認

About パネル統合のアップデート確認/インストール UI は実装・単体テスト済み
(ダウンロード元ホスト制限・zip slip対策・署名同一性検証等)。「更新確認」
ボタン自体の動作は実 GitHub API で確認済み。詳細: `docs/release.md`
「アプリ内アップデート (Task #182)」節。

未確認: 実際に新バージョンをリリースしてからのダウンロード→展開→署名
検証→入れ替え→再起動の一連の流れ (ユーザーの実アプリを壊すリスクがある
ため未実行)、「新しいバージョンがあります」画面の見た目、
`/Applications`書き込み権限が無い環境でのフォールバック、Gatekeeper
未承認/署名不一致時の経路。

### Task #162: 署名を本文に混在させない — 実機確認

署名は本文に挿入せずプレビュー表示のみ、送信時にだけ結合するよう変更済み。
単体テスト・Mailpit統合テストgreen。詳細: `docs/design-system.md`
「Task #162」節。

未確認 (実機タップ操作): 署名選択時のプレビュー表示、署名切替時に本文が
変化しないこと、アカウント切替時の署名追随、送信済みメールでの本文+空行+
署名の反映、下書き保存/復元時の署名状態。

### Task #160: スレッド要約 (mapのみの単一パイプライン) — 実機確認

per-messageの事実抽出を空行区切りで連結するだけの最終形に簡素化済み
(reduce/refine段・■経緯/■現状ラベルは廃止)。詳細:
`docs/translation.md`の Task #160 関連6節。

未確認: 「n/m 通目を要約中…」表示の体感、生成結果の見た目
(`ThreadDetailView`の要約シート)、実データでの内容の正確さ・読みやすさ。

### Task #148: 「詳しく要約」— 実機確認

単一メールのAI要約シートに「詳しく要約」(`sentenceCount`=10) を追加済み。
実FMでの検証は完了、単体テストgreen。詳細: `docs/translation.md`
「Task #148」節。未確認: メニュー表示・選択後の実際の見た目 (シートUI)。

### Task #147/#149: 要約・翻訳ボタンの有効化タイミング — 実機での稀な競合確認

本文の後着到達 (#147) やアコーディオン切替中 (#149) の状態競合を修正済み、
単体テストgreen。いずれもタイミング依存のためtap-freeスクリーンショットで
は再現できず未確認のまま。詳細: `docs/design-system.md`「Task #147」
「Task #149」節。

### Task #116 (第2段): Outlook/Office365 の実接続確認

コード・単体テストは完了。Azure AD アプリ登録 (Client ID 発行) が必要な
OSS 特有の制約で、実接続確認がブロックされている。手順:
`docs/oauth-setup.md`「Microsoft OAuth Client ID の取得」節、
`HUMAN_TASKS.md`該当項目。

### Task #129/#156/#161: 作成画面リッチテキスト化 — タップを伴う書式確認

太字/イタリック/下線/打ち消し線/リスト/インデント/フォントサイズ/文字色/
ハイライト/リンク/引用の書式バーと HTML 送信配線 (`multipart/alternative`)
は実装・Mailpit統合テストまで完了。詳細:
`docs/design-system.md`の該当節、`docs/design-system.md`「composer-richtext」
関連。

未確認 (実機タップ操作): 各書式ボタンの選択範囲追従、フォントサイズ/文字色/
ハイライト/リンク/引用の実際の反映、下書き保存後の書式復元、実メール
クライアント (Gmail等) での受信側表示。

### Task #159: メール翻訳を Apple Translation フレームワークへ切替 — 実機確認未実施

`AppleTranslationService`への切替は`make test`/`make mac`/`make ios`
green。実エンジン呼び出し自体は自動テスト不可。詳細:
`docs/translation.md`「Task #159」節。

未確認: 通常の翻訳成功、言語パック未ダウンロード時の誘導、誤判定メール
(非日本語・非英語判定) での自動翻訳。

### Task #44: Gmail「すべてのメール」新着反映バグ修正 — 実機確認

メールボックス選択中に5分おきで自動差分同期を再試行する
`syncSelectedMailboxOnAppear()`を追加し、Gmailの「すべてのメール」が
サーバー側でINBOXよりやや遅れてインデックスされる挙動があっても、
手動pull-to-refreshに頼らず自動的に反映されるようにした。詳細:
`docs/qa-findings.md`「Task #44」節。

未検証: 実 Gmail アカウントでの動作確認 (`FakeIMAPSession`/実Dovecot
統合テストのみ検証済み)、実際のGmailインデックス遅延の実測値。

### Task #150: 「スレッド一覧で同じメールが2個ずつ表示される」— 原因未特定

`ThreadQuery`/`MessageQuery`のrole×`pinnedOnly`全組み合わせの回帰テストを
追加したが`main`に対して再現しなかった。詳細: `docs/qa-findings.md`
「Task #150」節。

**確認をお願いしたいこと**: 実機で重複が見えたときの (a) 画面、
(b) 一覧表示設定 (スレッドまとめ/フラット)、(c) 未読のみ/フラグ付きのみ
トグルの状態、(d) アカウントの種類・台数。

### Task #178 (文字色/ハイライト): タップを伴う操作は未検証

文字色パレットへの白黒追加・色見本の可視化・「デフォルト」選択でダーク
モードの文字が黒くなるバグの修正 (`make test`35件緑)。詳細:
`docs/design-system.md`「Task #178」節。

未検証: メニューを開いて色を選ぶ操作そのもの (シミュレータのXCUITestタップ
不達のため)。特にダークモードで色選択→「デフォルト」に戻したとき文字が
白のまま (黒くならない) ことの確認が核心。実送信での受信側表示も未確認。

### Task #184: アーカイブ済みメールの操作 — 画面確認が未検証

スレッド詳細画面 (iOSフッターツールバー/その他メニュー、macOS行コンテキス
ト/⌘Eメニュー) がアーカイブ済みメールに対して「アーカイブ解除」表示になる
よう修正 (一覧のスワイプ/macOSコンテキストメニューはTask #87で対応済み)。
`make test`/`make mac`/`make ios`/`make check-localization`green。詳細:
`docs/design-system.md`「Task #184」節。

未検証: 画面自体を一度も目視確認できていない (シミュレータの既知不調で
`scripts/verify-screen.sh`が完了しなかった)。iOS/macOS 双方でのラベル/
アイコン切替、一部だけアーカイブ済みの混在ケース、ピン留め済みメールでの
挙動。

### Task #185: メール詳細画面に件名を表示 — 画面確認が未検証

`MessageHeaderCompactView`のヘッダ先頭に件名を復活。`make test`/`make mac`/
`make ios`/`make check-localization`green。詳細: `docs/design-system.md`
「Task #185」節。

未検証: 画面自体を一度も目視確認できていない (シミュレータの既知不調)。
長い件名の折返し・省略、件名欠落時の表示、スレッドアコーディオンでの
展開行追従、ダークモードのコントラスト。

### Task #188: 「ツールバーをカスタマイズ」位置の再発修正 — 画面確認が未検証

実機報告「メール本文のフッターツールバー『その他』メニュー内で
『ツールバーをカスタマイズ』の位置が一番下にならないことがある」の
修正。表示オフにしたアクション (可変長) を`hiddenActionsMenu`という
別階層のサブメニュー (「メールの操作」) に切り出し、「ツールバーを
カスタマイズ」はトップレベルの「その他」メニューに常に固定1件だけ
並ぶ項目にした — トップレベルの項目数を常に高々2件に保つことで、
非表示アクション数やメニューの開閉挙動に関わらず位置を安定させる
設計 (メカニズム自体は未特定、詳細は`docs/design-system.md`「実機報告:
『ツールバーをカスタマイズ』の位置が安定しない (Task #188)」節)。
`make test`/`make mac`/`make ios`/`make check-localization`green。

未検証: シミュレータの既知不調 (`docs/verify.md`既知不調#6、`xcodebuild
test`が無応答のまま進捗が出ない) に阻まれ、実機/シミュレータでの実際の
メニュー開閉を一度も目視確認できていない。実機で確認してほしいこと:

- メール本文画面の「その他」(…) をタップ → 「メールの操作」サブメニュー
  と「ツールバーをカスタマイズ」の2項目が見えること (既定構成、非表示
  アクション7件)。
- 「メールの操作」をタップ → ミュート/ピン留め/未読にする/アーカイブ/
  迷惑メールにする/削除/ソースを表示の7項目が並び、それぞれ動作すること。
- 設定でツールバーの表示アクションを増減させ (「その他」以外を全部
  オンにする/全部オフにする等)、「ツールバーをカスタマイズ」が常に
  「その他」メニューの最後尾に留まること (「メールの操作」サブメニュー
  が無い/1件だけ、の両パターンで確認)。
- macOS 版でも同じ「その他」メニュー (`ThreadDetailView`共通実装) を
  同様に確認。

### Task #187: Yahoo! JAPAN 断続的認証失敗の再試行間隔是正 — 実機確認

成功実績のある資格情報の再試行間隔を30分〜6時間へ延ばす修正 (リレー+
アプリ両方)。単体テストのみ検証済み、実 Yahoo! JAPAN アカウントでの確認は
未実施。詳細: `docs/qa-findings.md`「Task #187」節。

未検証: ロック再発頻度の実地改善確認、リレーの`watches`表示、「接続テスト」
文言の切替、30分/6時間という値が実際の待ち時間として妥当か。

### Task #176: 通知の内容トグル — 実機での通知表示は未検証

差出人/件名/本文プレビューの表示可否を個別設定できるようにした
(`NotificationContentSettingsStore`)。単体テストgreen。設定画面の
スクリーンショットはシミュレータの既知不調 (contacts権限ハング) で未取得。

未検証: 3トグルの組み合わせでの通知表示内容、全OFF時の無内容通知、アプリ
完全終了後の設定反映。

### Task #189 (設定に「一般」カテゴリを新設、iCloud 同期トグルを移設): スクリーンショット未取得

設定のトップに「一般」カテゴリ (`GeneralSettingsView`) を新設し、iCloud
同期トグルを「アカウントの設定」(`AccountSettingsCategoryView`) から
そこへ移設した (iOS: `AccountsListContent`の先頭、macOS:
`OtegamiSettingsView`のサイドバー先頭)。footer の説明文も、Task #186 で
同期対象が設定全般に広がった実態に合わせて書き直した。単体テストと
`make mac`/`make ios`ビルドは green (`make check-localization`も新規
文言込みで green)。

`scripts/verify-screen.sh settings`/`general-settings`でのスクリーン
ショット取得を2回試したが、いずれも起動シーケンスの`simctl privacy
grant contacts`がハングし先へ進まなかった — Task #176 が既に
`docs/verify.md`の「シミュレータ検証の既知の不調」節に記録済みの
問題そのもの (このセッションでも他エージェント (#188) のxcodebuildが
並行実行中だった)。ユーザー指示どおりリトライは2回で打ち切り、目視
確認は未実施のまま報告する。

実機で確認してほしいポイント:
- ハンバーガーメニュー →「設定」を開くと、カテゴリ一覧の**先頭**に
  「一般」が表示され、その下に「アカウントの設定」「メール一覧」
  「メールビューア」「メール作成」と続くこと (iOS)。
- macOS は `Settings`シーン (⌘,) のサイドバー最上部に「一般」が表示され、
  既定で選択された状態で開くこと。
- 「一般」を開くと iCloud 同期トグル1つだけが表示され、footer に
  「アカウントの接続設定に加えて表示・翻訳・通知内容・署名・テンプレート
  なども同期する」という趣旨の説明文が表示されること (アカウントの
  接続設定としか書いていない旧文言に戻っていないこと)。
- 「アカウントの設定」カテゴリを開いたとき、iCloud 同期トグルが**もう
  表示されない**こと (プッシュ通知リンクは引き続き表示される)。
- トグルの ON/OFF が「一般」画面から問題なく操作できること (アカウント
  一覧・同期挙動自体への影響がないこと)。

### Task #165 (macOS 操作体系再設計): 実クリック検証が未完了

下書きの右クリック削除、一覧行/スレッド内メッセージ行への返信系メニュー
追加、⌘E/⇧⌘U/⇧⌘R/⇧⌘Fショートカット追加は実装・`make mac`/`make ios`
green。実クリック検証は共有マシン環境でフォーカスが意図せず他アプリへ
移った (誤操作のリスクを避けて中断)。詳細な8項目チェックリストは
`docs/design-system.md`「Task #165」節参照。

### Task #192: 実機クラッシュ `0xDEAD10CC` 対策 — 実機での再現・非再現確認が未実施

詳細な原因分析・修正内容は `docs/qa-findings.md`「Task #192」節参照
(`0xDEAD10CC`で検索可)。GRDB の中断通知
(`Configuration.observesSuspensionNotifications`) を有効化し、
`OtegamiApp.handleScenePhaseChange`から中断/復帰を送出、`SyncEngine`側
(`AccountSyncer`/`OpQueueProcessor`) は中断エラーを「エラーではなく
リトライ不要な一時停止」として扱うよう修正した。`make test`/`make mac`/
`make ios`は green だが、**背景でバックグラウンド停止のタイミングに
依存する不具合のため、シミュレータでの再現・非再現確認は困難**
(`docs/verify.md`の既知不調4種のいずれにも該当しない、新種の環境依存)。

実機で確認してほしいポイント:
- **この修正が入る前のビルドで再現していた `0xDEAD10CC` クラッシュが、
  この修正後は起きなくなること。** 具体的には、複数アカウント (できれば
  push 通知有効なアカウント) を設定した状態で、メール一覧を開いたまま
  ホームボタン/スワイプでバックグラウンドへ送り、数分〜数十分放置して
  から再度フォアグラウンドへ戻す、を繰り返す。特に「バックグラウンドへ
  送った直後 (opQueue replay や push 受信処理がまだ書き込み中の可能性が
  ある瞬間)」を狙うと再現しやすいはず。
- 上記の操作中、Xcode の Console.app (または `log stream --predicate
  'subsystem == "com.mtkg.otegami"'`) で `SQLITE_ABORT`/`SQLITE_INTERRUPT`
  や "Database is suspended" 関連のログが出ていないか (出ていても
  クラッシュせずアプリが普通に動き続けていれば正常 — この修正の意図
  どおり)。
- フォアグラウンド復帰直後、同期が正常に再開する (受信トレイが更新
  される、オフライン中の操作が反映される) こと — 中断状態のまま固まって
  いないこと。
- 実機のクラッシュログ (設定 → プライバシーとセキュリティ →
  解析と改善 → 解析データ、または Xcode の Window → Devices and
  Simulators → View Device Logs) に、この修正後は `RUNNINGBOARD`/
  `0xDEAD10CC`起因のクラッシュが新規に増えていないこと。
  **クラッシュログ本体は端末情報を含むためこのリポジトリにコミットしない
  こと** (`CLAUDE.md`の注意点参照)。

### Task #193: 送信済みの古いメールが受信箱の最近のスレッドに混入する不具合 — 実機での確認が未実施

実機報告「10年以上前に送った送信済みメールが、6時間前くらいの日付で、
しかも受信箱に表示されている」に対応。原因は mailcore2 (pinned revision)
の `MessageHeader` 既定コンストラクタが `Date:` ヘッダのパースに失敗した
メッセージの日付を「フェッチした瞬間の時刻」で埋めてしまう既知の挙動
(`packages/OtegamiKit/Sources/OtegamiCore/EnvelopeDateSentinel.swift`の
doc comment に mailcore2 側ソースの該当箇所まで書いてある)。受信箱への
混入は「日付が壊れて『今』に見えることで、件名フォールバックのスレッド化
(件名一致+参加者重なり+7日以内) を通ってしまう」という因果で、**実機
DB のデータでは確認できていない** (アクセス不可のため) — 代わりに
(1) 実 Dovecot (`dev/mailstack`) に `Date:` ヘッダの無いメッセージを
`doveadm save` で投入し、実際に pinned mailcore2 でフェッチして
`date` がフェッチ時刻に化けること/修正後は `nil` (→ `internalDate` に
フォールバック) になることを確認 (`EnvelopeDateSentinelIntegrationTests`)、
(2) インメモリ DB 上で「日付が壊れた古い送信済みメール」が実際に最近の
INBOX スレッドへ合流し、修復パスで解除されることを確認
(`SentinelDateThreadRepairTests`) — の2経路で因果を裏取りしてから実装した
(詳細はこれらのテストファイルの doc comment、および
`EnvelopeDateSentinel.swift`/`MailCoreIMAPSession+Mapping.swift`/
`ThreadAssigner.repairSentinelDates`の doc comment)。既存の壊れた
`message.date`/誤ったスレッド割当を直す修復パス
(`ThreadAssigner.repairSentinelDates`) は v38 マイグレーションとして
既存インストール全件に自動適用される。`make test` green。

未検証 (実機・実アカウントでの確認が必要):
- 実際にこの不具合が報告された実機で、**該当の古い送信済みメールの表示
  日付が正しい (元々の送信日時) 値に戻り、受信箱の最近のスレッドから
  抜けて自分自身の (または元々あるべき) スレッドに移っていること**。
  Xcode 経由でアプリを起動すると v38 マイグレーションが自動的に走るので、
  起動後にその特定のメールを開いて日付・スレッド所属を確認する。
- 修復後、同じアカウントを再同期 (pull-to-refresh 等) しても、その
  メールの日付・スレッド所属が再び壊れないこと (非 CONDSTORE 経路の
  再現防止確認)。
- 可能であれば、修復前に該当メールが実際にどのスレッドに紛れ込んでいた
  か (メッセージ数・件名などから推測できる範囲で) をスクリーンショット
  等で記録しておくと、修復が正しい範囲だけに効いたことの確認に役立つ。

## 環境・インフラの設定待ち (運用者作業)

インフラ設定 (otegami-relay の再デプロイ、Client ID/Secret のビルド設定
登録等) は行動単位のチェックリストとして
[`HUMAN_TASKS.md`](HUMAN_TASKS.md) の「3. インフラ・運用まわり」にまとめて
ある。設計判断の背景は各項目から参照される `docs/relay-deployment.md`/
`docs/oauth-setup.md`/`docs/xcode-cloud.md` を参照。

### Task #177: NotificationService Extension の OAuth 対応 — 実機確認未実施

Gmail/Outlook (`.oauth2`) アカウントの push 通知でも、Extension が共有
Keychain の refresh token をアクセストークンへ交換し XOAUTH2 で IMAP
認証するようにした (`PushOAuthAccessTokenResolution`が30秒制限に対し
10秒タイムアウトでレース)。単体テスト (`PushOAuthAccessTokenResolutionTests`
等) green。詳細: `docs/relay-deployment.md`「既知の制約 / 今後」節。

未検証 (実 Gmail/Outlookアカウント・実push・実Extensionプロセスが必要):
差出人/件名の実内容反映、Client ID未設定時の汎用フォールバック、refresh
token失効時の「要再認証」反映、token交換+IMAP取得が30秒以内に収まるか。

### Task #167: `ComposerView.parseAddresses` への CRLF/NUL 検証追加 (推奨、必須ではない)

SMTP CRLFインジェクションの本修正はトランスポート境界
(`MailCoreSMTPSession.sendMessage`/`validateForSMTP(_:)`) で完了済みで
脆弱性は解消済み。多層防御として、Composer の手入力アドレスパース
(`ComposerView.parseAddresses`) にも同じ検証を入れると、送信前のUI段階で
制御文字混じりの入力に気づけるが、必須の修正ではない。

## 公開時に必要な対応 (まとめ)

以下は「今すぐ開発を止める理由」ではなく、実際に公開・配布する段になったら
対応が必要な項目。

- **Google OAuth の審査**: 各自の Client ID でのテスト利用には審査不要だが、
  作者本人が配布ビルド (App Store/TestFlight) を出す場合は Google の OAuth
  審査が必要になる (`docs/oauth-setup.md`)。
- **サードパーティライセンス表記の保守**: 依存追加/更新時は `NOTICE`
  (ライセンス種別・著作権表示の一覧) の追記漏れがないか確認する。
- **iOS でデフォルトのメールアプリになる (Task #48)**: `com.apple.developer
  .mail-client` entitlement は Apple の個別承認制。申請手順・承認後の
  有効化手順は [docs/default-mail-app.md](docs/default-mail-app.md) 参照。
- **TestFlight ビルドで通知が届くことを確認する (Task #57)**: production/
  sandbox APNs 環境の自動判定 (`APNSEnvironmentDetector`) は実装・単体
  テスト済みだが、実 TestFlight ビルドでの受信確認は Apple 実機環境が必要
  (`docs/xcode-cloud.md`「既知の注意点」節)。

## 起動時プリフェッチの体感速度 — 実回線での確認

未オープンメッセージの背景プリフェッチ (`SyncCoordinator
.prefetchUnifiedInboxBodiesIfNeeded`/`prefetchMessageBodies`) は単体
テスト済み。実 IMAP サーバー・実回線での体感速度 (起動直後のスクロール時、
検索/フィルタ切替直後) は未計測。詳細: `docs/design-system.md`
「一度表示したメールを再度開くと毎回読み込みが入る」節。
