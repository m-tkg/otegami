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

### Task #165 (macOS 操作体系再設計): 実クリック検証が未完了

下書きの右クリック削除、一覧行/スレッド内メッセージ行への返信系メニュー
追加、⌘E/⇧⌘U/⇧⌘R/⇧⌘Fショートカット追加は実装・`make mac`/`make ios`
green。実クリック検証は共有マシン環境でフォーカスが意図せず他アプリへ
移った (誤操作のリスクを避けて中断)。詳細な8項目チェックリストは
`docs/design-system.md`「Task #165」節参照。

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
- **macOS ビルドの配布**: Developer ID 署名 + notarization のワークフロー
  (`.github/workflows/release-macos.yml`) は整備済み、次回タグ push 時に
  Actions の run が緑になるか・Gatekeeper (`spctl -a -vvv`) を越えるかの
  実地検証が必要 (`docs/release.md`)。
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
