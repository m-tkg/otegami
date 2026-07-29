# HUMAN_TASKS — 人間 (ユーザー本人) がやる作業一覧

このファイルは「人間の行動」視点で、otegami の開発を進める上でユーザー
本人にしかできない作業をまとめたチェックリスト。完了したら `[ ]` を
`[x]` に変えていく運用を想定している。

## PENDING.md との関係

[`PENDING.md`](PENDING.md) は「何が技術的に未検証で、なぜで、対応手順は
何か」を機能単位で詳しく記録したドキュメント (実装側の視点)。この
`HUMAN_TASKS.md` はその内容を「今日やることリスト」として行動単位に
並べ替えたもの — 詳しい背景・理由・切り分けの経緯が知りたい項目は、
各行から `PENDING.md` の該当節にリンクしている。逆に、ここに無い技術的
な保留事項は無い (このファイルは PENDING.md の全項目 + ドキュメント
全体から拾った確認待ち事項を漏れなく含む)。

---

## 1. 実機での確認 (シミュレータでは確認しきれなかったもの)

- [ ] **スレッド要約 (■経緯/■現状) の内容が具体的・自然な口調・簡潔に
      なったか (二重圧縮・メタ言及調の根治 + 仕上げパスによる簡潔化後)**
      — 複数往復のあるスレッド (できれば金額・日時・固有名詞など具体的な
      内容を含む4通以上のもの) を開き、ナビゲーションタイトル横の要約
      ボタンをタップして「n/m 通目を要約中…」に続き「仕上げ中…」という
      進捗表示が出ること、生成完了後の■経緯が数値・固有名詞・決定事項を
      落とさずに、以前より少ない行数で簡潔にまとまっていること、かつ
      「この返信では〜が述べられている」のような説明調(メタ言及)の言い
      回しが出ていない (書き手が言ったことが直接書かれているか) を確認
      する。
      優先度: 中 / 所要時間: 10分 / 詳細: [PENDING.md](PENDING.md)「Task #160: スレッド要約のmapをメッセージ単位に固定・二重圧縮とメタ言及調を根治・仕上げパスで簡潔化」節
- [x] **本文内リンクのブラウザオープン** (2026-07-28 確認済み) — 実際のHTMLメール (newsletter等、
      `target="_blank"` を含むものが理想) を開き、リンクをタップして
      設定通りのブラウザ (アプリ内ブラウザ/デフォルトブラウザ) が開くか
      確認する。設定の「リンクを開く方法」を切り替えて両方確認。
      優先度: 高 / 所要時間: 15分 / 詳細: [PENDING.md](PENDING.md)「表示・操作改善バッチ: リンクのブラウザオープン修正・添付メニューの実機確認」節
- [x] **作成画面の添付メニュー** (2026-07-28 確認済み) — 「添付」ボタンをタップしてメニュー
      (ファイルを選択/写真を選択/写真を撮る) が実際に開くか、「写真を
      撮る」でカメラが起動し撮影した写真が添付されるか確認する
      (シミュレータではカメラ非搭載のためグレーアウトのままで、実機でしか
      検証できない)。
      優先度: 高 / 所要時間: 10分 / 詳細: 上記と同じ節
- [x] **端末内翻訳が実機で成功するか (HTML レイアウト保持翻訳を含む)** (2026-07-28 確認済み) —
      実機 (Apple Intelligence 対応・有効) で英文メール
      (`20-english-quarterly-report.eml` seed 済み) を開き、翻訳バーの
      「翻訳」ボタンをタップして (自動翻訳は既定オフになった) 実際に
      訳文を表示するか確認する。あわせて `30-fixed-width-notice-en.eml`
      (固定幅テーブルの英語メール) でも翻訳し、表・画像・罫線のレイアウト
      を保ったまま文字だけ日本語化されるか確認する。iOS Simulator の
      `.app` プロセスからは `FoundationModels.LanguageModelError -1` で
      一貫して失敗しており (同一コードが素の `swift test` プロセスからは
      毎回成功)、実機でも同じエラーが出るならコード側の不具合の可能性が
      高まるので、その場合は調査を再開する必要がある。
      優先度: 高 / 所要時間: 10分 / 詳細: [PENDING.md「design-phase-3: 翻訳の実機確認」](PENDING.md#design-phase-3-翻訳の実機-simulator-でない-確認)、[docs/translation.md](docs/translation.md)
- [x] **資格情報の自動救済が実際に効いたか** (2026-07-28 確認済み) — 起動時にローカル資格情報
      (Keychain) が見つからない状況からの自動救済 (`AppEnvironment
      .adoptOrphanedCredentialIfUnambiguous` 等) が実機でも動くか、
      不具合報告があった場合に確認する。通常運用では踏まないパスなので
      優先度は低いが、iCloud 同期がらみで資格情報が孤立した報告があれば
      最優先で確認すること。
      優先度: 低 (普段は不要、不具合報告時のみ) / 所要時間: 10分
- [x] **新画面構成の使用感** (2026-07-28 確認済み) — ハンバーガーメニュー、ヘッダ検索、メール
      本文フッターツールバー (返信/転送/検索/情報/その他) を数日実際に
      使ってみて、動線に違和感が無いか確認する。自動テストではUI要素の
      存在確認までしかできておらず、「使いやすいか」は人間の判断が必要。
      優先度: 中 / 所要時間: 数日かけて日常使用
- [x] **画面構造改修バッチ (スレッド選択画面・圧縮ヘッダ・カテゴリ優先 (2026-07-28 確認済み)
      メニュー) の目視確認** — このバッチの実装セッションはシミュレータの
      ネットワーク不調 (`MailCoreErrorDomain error 1`、翻訳バッチのときと
      同じ既知の環境問題) でアカウント追加の接続テストが一貫して失敗し、
      スクリーンショットによる目視確認が一切できなかった。2通以上の
      スレッドをタップして選択画面が出ること・1通のスレッドはスキップ
      されること・本文画面にアコーディオンが残っていないこと・本文ヘッダ
      が約2行に収まっていること・ハンバーガーメニューがカテゴリ優先
      (受信トレイ/アーカイブ/送信済み等のセクション+「すべての◯◯」
      横断ビュー行) で表示されることを確認する。
      優先度: 高 / 所要時間: 15分 / 詳細: [PENDING.md「画面構造改修バッチ (Task #33): スレッド選択画面・圧縮ヘッダ・カテゴリ優先メニューの実機目視確認」節](PENDING.md)
- [x] **表示言語設定 (String Catalog) の見た目確認** (2026-07-28 確認済み) — 設定で「English」
      に切り替えて再起動し、一覧・本文・作成・検索・ハンバーガーメニュー・
      設定画面 (5カテゴリすべて) の英訳が不自然でないか、レイアウト崩れが
      無いか確認する (`docs/localization.md` の確認方法参照 — 232エントリ、
      アカウント追加/編集フォームや署名テンプレート等も対応済み)。
      優先度: 低 / 所要時間: 10分
- [x] **Gmail でのアーカイブ動作確認** (2026-07-27 確認済み) — 実 Gmail アカウントでメールを
      アーカイブし、INBOX から消えて「すべてのメール」には残ることを
      確認する (以前は Gmail に `\Archive` special-use フォルダが無いため
      アーカイブが無言で失敗していた実バグの修正)。
      優先度: 中 / 所要時間: 5分 / 詳細: [PENDING.md「実機フィードバック第2弾: Gmail アーカイブ修正の実アカウント確認」](PENDING.md#実機フィードバック第2弾-gmail-アーカイブ修正の実アカウント確認)
- [x] **スレッド表示オフが再起動直後の一覧に反映されるか (Task #105)** —
      (2026-07-29 実機確認済み) 実機ログ採取で真因を
      `.navigationDestination(item:)` destination クロージャの stale
      capture と確定し、`ThreadRoute` 導入 (`c1804f4`) で解決。経緯は
      [docs/qa-findings.md「Task #105」節の「決着」](docs/qa-findings.md)。
- [ ] **「スレッド一覧で同じメールが2個ずつ表示される」報告の詳細確認
      (Task #150)** — OTA `c93bec3` 直後の実機報告。#141/#142 の
      `ThreadQuery`/`MessageQuery` SQL を精査し回帰テストを追加したが
      `main` に対して再現しなかった (`docs/qa-findings.md`「Task #150」
      節/`PENDING.md`参照)。再現時の (a) 画面 (統合受信トレイ/カテゴリ
      横断ビュー/すべてのメール/個別フォルダ)、(b) 一覧表示設定 (スレッド
      まとめ or フラット表示)、(c) 未読のみ/フラグ付きのみトグルの状態、
      (d) アカウントの種類・台数 を教えてもらえると絞り込める。
      優先度: 高 (regression 報告のため) / 所要時間: 数分 / 詳細:
      [PENDING.md「Task #150」](PENDING.md#task-150-スレッド一覧で同じメールが2個ずつ表示される-原因未特定)
- [ ] **実機フィードバック第2弾の新機能を数日実際に使ってみる** —
      アカウントのラベル色・署名テンプレート・デフォルトのアカウント・
      削除/アーカイブ後の挙動・カード状一覧の角丸・スレッド詳細の
      アコーディオン化・アプリアイコンの未読バッジ・再構成された設定
      画面 (5カテゴリ) を実機で数日使い、使用感に違和感が無いか確認する。
      優先度: 中 / 所要時間: 数日かけて日常使用
- [x] **Gmail 再認証がワンタップでサイレントに完了するか (2026-07-28 確認済み) (Task #47: 「毎回
      警告が出るのがつらい」)** — スコープを何も変えていない既存の Gmail
      アカウントで「アカウント編集」→「再認証」を実行し、同意画面も
      「アプリは確認されていません」警告も出ず、ブラウザシートが一瞬
      開いてすぐ閉じるだけで完了することを確認する。逆に、`scope` に
      新しいスコープが追加された直後でまだ再接続していないアカウント
      (または一度もアクセス権を許可していない状態) では、従来通り同意
      画面が出ることも確認する。実 Google での自動 E2E は不可なため、
      分岐ロジック自体は `GoogleOAuthEndpointsTests`/`GoogleOAuthClientTests`/
      `TokenStoreTests` の URLProtocol スタブで検証済み — この項目は
      「実際に Google がサイレント承認するか」という実機体感の確認。
      優先度: 高 / 所要時間: 5分 / 詳細:
      [docs/oauth-setup.md「再認証時に同意画面を省略する (Task #47)」節](docs/oauth-setup.md#再認証時に同意画面を省略する-task-47-毎回警告が出るのがつらい)
- [x] **送信キャンセル中にアプリが自動でバックグラウンドへ回る不具合の
      実機再現確認** — (2026-07-29 解決) Task #124 (98d0990) でカウント
      ダウン満了後の replay 未発火・二重送信を根治し、実機確認済み。
- [ ] **mailto: リンクの実機確認 (Task #48)** — 実機/シミュレータで他の
      アプリ (メモ、Safari 等) から `mailto:宛先?subject=...&body=...`
      形式のリンクを開き、otegami の作成画面が to/cc/bcc/件名/本文を
      プリフィルした状態で開くことを確認する (`xcrun simctl openurl` でも
      代用可)。あわせて設定 →「アカウントの設定」→「デフォルトのメール
      アプリに設定」の行を開き、entitlement 未承認ビルドでは「Apple の
      承認待ちです」の案内が、承認済み・フラグ有効ビルドでは「設定 App で
      既定のメールアプリを選ぶ」ボタンが実際に「設定」アプリの既定アプリ
      選択画面を開くことを確認する。
      優先度: 中 / 所要時間: 10分 / 詳細: [docs/default-mail-app.md](docs/default-mail-app.md)
- [ ] **作成画面フラットデザイン (Task #156) のタップ操作を伴う見た目確認** —
      新規作成画面を開き、(1) 宛先行の「Cc: Bcc:」ピルをタップして Cc/Bcc
      行が展開されること、(2) 署名を1件以上登録した状態で本文下の
      「署名なし」行をタップし、署名選択メニューが開いて選んだ署名名が
      行に反映されること、(3) ファイルを1件以上添付し、行の表示と削除
      ボタン (×) が機能すること、(4) 返信の「全員に返信」や mailto:
      リンク経由で Cc/Bcc に値が入った状態で開いたとき、ピルをタップ
      しなくても最初から Cc/Bcc 行が展開済みで見えることを確認する。
      優先度: 中 / 所要時間: 10分 / 詳細: [PENDING.md「Task #156: 作成画面
      iOS フラットデザイン化」節](PENDING.md#task-156-作成画面-ios-フラットデザイン化--ccbcc展開署名行添付行の実機確認)

## 2. 実アカウントでの確認 (自分の認証情報が必要)

- [x] **Google OAuth Client ID を発行し、実 Gmail アカウントで確認** (2026-07-28 確認済み) —
      Google Cloud Console でプロジェクト作成 → OAuth 同意画面設定 →
      iOS 用 Client ID 発行 → `Config/Local.xcconfig` に設定 → 実際に
      Gmail アカウントを追加し、INBOX 同期・送信 (Sent への二重保存が
      起きないこと)・アクセストークン失効後の自動リフレッシュ・アクセス
      取り消し後の「再認証」バナーからの復旧を確認する。**アバター強化
      バッチ「Google プロフィール写真」で `contacts.other.readonly`・
      `contacts.readonly` の2スコープを追加した** (どちらも機密性の高い
      スコープ — 配布ビルドを出す場合のみ Google の OAuth 審査に影響、
      `docs/oauth-setup.md`「`contacts.other.readonly`・`contacts.readonly`」
      節参照)。新規追加アカウントは何もせず両スコープを持つ。
      **済 (2026-07-27)**: People API の有効化・`contacts.other.readonly`
      の同意画面へのスコープ追加・公開ステータスへの切替 (未検証のまま
      運用、7日期限は解消)。**済 (追記時点)**: `contacts.readonly` も
      同意画面のスコープに追加済み — 下の「保存済み連絡先を含む Google
      プロフィール写真」項目の残作業 (OTA 反映 → 再認証 → 確認) 参照。
      優先度: 高 (Gmail 対応を謳う以上、実接続確認は必須) / 所要時間: 30分
      (Client ID 発行) + 20分 (確認項目一式) / 手順: [docs/oauth-setup.md](docs/oauth-setup.md)、[PENDING.md「M6: Google OAuth Client ID の発行」](PENDING.md#m6-google-oauth-client-id-の発行)
- [x] **`contacts.readonly` 対応ビルドを反映し、既存 Gmail アカウントを (2026-07-28 確認済み)
      再接続して Google プロフィール写真 (保存済み連絡先を含む) を確認**
      — Gravatar 未登録の差出人 (Gmail 公式アプリでは写真が出る人) の
      写真が実機で出ない不具合の修正。原因は
      (a) 旧実装の `otherContacts.search` が PROFILE ソース (相手の
      Google アカウント自体のプロフィール写真) を取得できていなかった、
      (b) 保存済み連絡先はそもそも `otherContacts` に含まれず別スコープ
      (`contacts.readonly`) が要る、の2点。両方を修正した
      (`otherContacts.list`/`people/me/connections` の索引方式への
      書き換え、`contacts.readonly` スコープの追加)。
      **済**: Google Cloud Console の OAuth 同意画面へ `contacts.readonly`
      スコープを追加。
      残作業:
      1. この修正を含むビルドを OTA で端末に配信する。
      2. 設定 → アカウント → 該当の Gmail アカウント →「再認証」で
         再接続する (削除・再作成は不要、同じ OAuth フローの再実行で
         新スコープが付与される)。
      3. **再接続後、同じ画面を開き直して**「認証」節の「連絡先の写真:
         許可済み (完全)」表示になっていることを確認する (「許可済み
         (基本)」や「未許可」のままなら Console 側の設定がまだ反映されて
         いない — 詳細と対処は `docs/oauth-setup.md`「実機バグ: 再接続
         してもスコープが増えない場合」節)。
      4. Gravatar 未登録の差出人 (保存済み連絡先の相手を含む) からの
         メールで、一覧のプロフィールアイコンが Google のプロフィール
         写真に変わることを確認する (「許可済み (完全)」にならない場合
         でもアプリは問題なく動く — この情報源だけ一部/全部効かない
         状態が続くだけ)。
      優先度: 中 (既存ユーザー影響、実 Gmail アカウントでの動作確認は自動化
      対象外) / 所要時間: 10分 / 手順: [docs/oauth-setup.md](docs/oauth-setup.md)「`contacts.other.readonly`・`contacts.readonly`」節
- [x] **`profile` スコープ対応ビルドを反映し、自分のプロフィール写真を (2026-07-28 確認済み)
      確認 (Task #54)** — 実機の「アカウント編集」→「アバター診断」画面で
      `people/me` が 403 `Request requires one of the following scopes:
      [profile]` を返すことを確認済み (`otherContacts`/`connections` は
      正常)。`GoogleOAuthEndpoints.scope` に `https://www.googleapis.com/auth/userinfo.profile`
      を追加して修正した (`docs/oauth-setup.md`「Task #54 追記」節参照)。
      残作業:
      1. この修正を含むビルドを OTA で端末に配信する。
      2. 設定 → アカウント → 該当の Gmail アカウント →「再認証」で
         再接続する。
      3. 再接続後、「アカウント編集」→「アバター診断」画面を開き直し、
         `people/me` 行の HTTP ステータスが 200 になっていることを確認
         する。
      4. 差出人一覧・スレッド一覧で自分自身のメールアドレス宛/CC のメール
         を開き、自分のプロフィール写真がアイコンに出ることを確認する。
      優先度: 中 (既存ユーザー影響、実 Gmail アカウントでの動作確認は自動化
      対象外) / 所要時間: 10分 / 手順: [docs/oauth-setup.md](docs/oauth-setup.md)「Task #54 追記」節
- [x] **iCloud App用パスワードで実アカウント確認** (2026-07-28 確認済み) — appleid.apple.com
      で App 用パスワードを発行し、iCloud メールアドレス + App用パスワード
      でアカウントを追加、INBOX同期・送信・返信のスレッド接続を確認する。
      ログインに失敗する場合、IMAP/SMTP ユーザー名が現在フルアドレス
      (`user@icloud.com`) 実装になっている点を疑い、iCloud が短縮形
      (`user` のみ) を要求する場合は `ICloudAccountSetupView` の実装を
      切り替える (影響範囲は数行のみ)。
      優先度: 高 / 所要時間: 15分 / 詳細: [PENDING.md「M6: iCloud App用パスワードでの実アカウント確認」](PENDING.md#m6-icloud-app-用パスワードでの実アカウント確認)
- [x] **実2台間の iCloud アカウント同期確認 (同一 Apple ID)** (2026-07-28 確認済み) — iPhone実機
      + Mac の両方に同じ署名設定でビルド・インストールし、(1) 片方で
      追加したアカウントがもう片方に自動的に出現するか、(2) 逆方向も、
      (3) 片方で削除したらもう片方でも消えるか、(4) 同期トグルを片方だけ
      OFFにした時の挙動、(5) **両方のデバイスで独立に同じメールアカウント
      を追加した場合に重複挿入されず1つに統合されるか** (重複挿入バグ
      修正の実機2台間での最終確認、これまではシミュレータ1台への直接DB
      注入でのみ検証済み) を確認する。
      優先度: 中 / 所要時間: 30〜60分 (2台の実機/Mac が必要) / 手順:
      [PENDING.md「M11: iCloudアカウント同期の実機2台間確認」](PENDING.md#m11-icloud-アカウント同期の実機-2-台間確認)、[docs/icloud-sync.md「重複挿入バグとその修正」](docs/icloud-sync.md)
- [x] **Task #116 (第1段): Yahoo / Yahoo! JAPAN / Exchange の実接続確認** —
      (2026-07-29 解決) Yahoo! JAPAN は IMAP アクセス有効化の上で実接続・
      受信確認済み (当初の「アクセスできない」は Yahoo 側の IMAP 無効が
      原因)。ユーザーの一括実機確認でクリア。
- [ ] **Task #116 (第2段): Azure AD アプリ登録 + Outlook/Office365 の実接続確認** —
      Microsoft OAuth (XOAUTH2) は実 Azure AD アプリでの E2E がこの
      セッションでは未実施 (OSS Client ID 問題、Gmail と同じ制約)。
      (1) [docs/oauth-setup.md](docs/oauth-setup.md)の「Microsoft OAuth
      Client ID の取得」節に従い Azure Portal でアプリを登録し、
      リダイレクト URI `com.mtkg.otegami.msauth://oauth2redirect` を
      「モバイルアプリケーションおよびデスクトップアプリケーション」
      プラットフォームに登録、「パブリック クライアント フローを許可
      する」を有効化する。(2) 発行された Client ID を
      `Config/Local.xcconfig`の`OTEGAMI_MICROSOFT_CLIENT_ID`に設定し、
      `make ios`/`make mac`で再ビルド。(3)「アカウントを追加」→
      「Outlook」(個人 Outlook.com/Hotmail アカウント) と「Office365」
      (会社・学校の Microsoft 365 アカウント) の両方で実際にサインイン
      し、INBOX 同期・送信・アクセストークン失効後の自動リフレッシュ・
      アクセス取り消し後の「再認証」バナーからの復旧を確認する。
      優先度: 中 (Outlook/Office365 対応を謳う前に必須、ただし配布判断は
      別途) / 所要時間: 20分 (Azure アプリ登録) + 15分 (確認項目一式) /
      詳細: [docs/oauth-setup.md「Microsoft OAuth Client ID の取得」節](docs/oauth-setup.md)

## 3. インフラ・運用まわり

- [x] **CI の最新 run が緑か確認** (2026-07-28 確認済み) — `ci-app`/`ci-server` の GitHub
      Actions ワークフロー、および自宅サーバー上でセルフホストしている
      otegami 用の CI/自動化コンテナを使っている場合はその最新実行結果も
      あわせて確認する (このリポジトリの GitHub Actions バッジは
      README.md 冒頭のバッジで確認できる)。
      優先度: 中 / 所要時間: 5分
- [x] **APNs `.p8` キーのバックアップ** (2026-07-28 完了) — `.p8` キーは Apple から一度しか
      ダウンロードできない (紛失すると Apple Developer 側で失効・再発行
      が必要)。ダウンロードフォルダに置きっぱなしになっていないか確認し、
      パスワードマネージャや暗号化ボリュームなど、より安全な場所に移動
      する。
      優先度: 中 / 所要時間: 5分 / 参照: [docs/relay-deployment.md](docs/relay-deployment.md)
- [x] **プライベート CA の秘密鍵 (rootCA.key 相当) を git 管理外に置く**
      — (2026-07-29 対応済み) 管理場所を変更したとユーザー確認。

## 4. 公開・配布に向けて (App Store / TestFlight を目指す場合)

- [x] **Google OAuth の審査** — (2026-07-29 決定) 申請しない方針。
      テストユーザー運用 (審査不要・100人上限) を継続する。将来申請する
      場合の前提 (ブランディング検証・プライバシーポリシー URL・デモ動画・
      制限付きスコープの CASA) は検証センターで確認済み。
- [ ] **macOS ビルドの Developer ID 署名 + notarization (Task #143)** —
      (2026-07-29 ワークフロー整備済み、次回タグで実地検証) tag push
      (`v*`) / `workflow_dispatch` で GitHub Actions
      (`.github/workflows/release-macos.yml`) が macOS を Archive →
      Developer ID 署名 → notarization → GitHub Release 添付まで自動で
      行うようになった。署名・notarize に必要な secrets (`SIGNING_IDENTITY`
      等6つ) は登録済み。**このセッションではローカルで未署名ビルド・
      手動 codesign の検証まで行ったが、実際の notarization・GitHub
      Actions ランナー上での実行・iCloud KVS entitlement が配布ビルドで
      実際に機能するかは未検証** — 次回タグを打つ (または先に
      `workflow_dispatch` で単体実行する) 際に、Actions の run が緑に
      なるか、Gatekeeper (`spctl -a -vvv`) を越えるか、iCloud アカウント
      同期が動くかを確認してほしい。手順・確認ポイントの詳細は
      [docs/release.md](docs/release.md)。
      優先度: 低 (配布を決めてから、ただし着手自体は完了) / 所要時間:
      次回タグ push 時に Actions の run を見るだけ (数分) / 参照:
      [docs/release.md](docs/release.md)、[PENDING.md「公開時に必要な対応」](PENDING.md#公開時に必要な対応-まとめ)
- [x] **サードパーティライセンス表記 (`NOTICE`) の確認** — (2026-07-29
      確認済み)。以後は依存を追加/更新する PR の際にエージェント側で
      NOTICE を追随させる運用 (人間の定期作業からは外す)。
- [x] **`com.apple.developer.mail-client` entitlement の申請・承認後の (申請済み 2026-07-28、承認待ち)
      有効化 (Task #48)** — まだ申請していなければ
      [Request a Mail App Entitlement](https://developer.apple.com/contact/request/default-mail-client/)
      から Account Holder ロールで申請する。承認されたら (1) Developer
      Portal で対象 App ID の Mail capability を有効化、(2)
      `Config/Local.xcconfig` に `OTEGAMI_MAIL_CLIENT_ENTITLEMENT = YES`
      を追加、(3) 実機ビルドで「デフォルトのメールアプリに設定」からの
      設定 App 遷移・実際にデフォルトとして選択できることを確認する。
      申請日・承認状況は `PENDING.md` に追記して進捗を追えるようにする
      こと。
      優先度: 低 (申請自体は今すぐ着手可、以降は Apple の承認待ち) /
      所要時間: 申請自体は30分程度、承認後の有効化は10分 / 参照:
      [docs/default-mail-app.md](docs/default-mail-app.md)
- [x] **Xcode Cloud のワークフローを作成する (Task #49)** (2026-07-28 完了) — App Store
      Connect にアプリレコードを作成 (Bundle ID `com.mtkg.otegami`) →
      Xcode の Report Navigator → Cloud タブからワークフローを作成し
      リポジトリを接続 → Archive アクション + TestFlight (内部テスト)
      の Post-Action を設定 → 環境変数
      (`OTEGAMI_DEVELOPMENT_TEAM`/`OTEGAMI_GOOGLE_CLIENT_ID` は Secret
      指定) を設定 → cloud signing (証明書/プロビジョニングプロファイル
      の自動管理) を許可 → 初回ビルドが Archive 成功し TestFlight に
      ビルドが表示されることを確認する。`ci_scripts/`・
      `ITSAppUsesNonExemptEncryption`・`CFBundleVersion` の CI 連動は
      実装・ローカル検証済みだが、実際の cloud signing・TestFlight 配信
      はこの手順で人間が初めて確認することになる。
      優先度: 中 (配布を決めてから) / 所要時間: 初回セットアップ1時間
      程度、以降のビルドは自動 / 参照:
      [docs/xcode-cloud.md](docs/xcode-cloud.md)
- [ ] **対応済み — TestFlight ビルドで通知が届くことを確認する
      (Task #57)** — TestFlight (Distribution 署名) のビルドは実際の
      APNs 環境が production になるが、アプリは otegami-relay への
      デバイス登録時に `environment: .sandbox` を固定で送っていたため、
      TestFlight ビルドではプッシュ通知が届かなかった。実行時に
      `embedded.mobileprovision` の `aps-environment` を読んで
      sandbox/production を判定するよう修正済み
      (`APNSEnvironmentDetector`、
      `packages/OtegamiKit/Sources/PushRelayClient/
      APNSEnvironmentDetector.swift`) — プロビジョニングプロファイルが
      見つからない場合は production にフォールバックする。`server/
      otegami-relay` 側は元々環境ごとの APNs 送信振り分けに対応済み
      だったため変更不要。ユニットテスト
      (`APNSEnvironmentDetectorTests`、`APNsSenderTests`) は追加済みだが、
      **実際に TestFlight ビルドをインストールした端末にプッシュ通知が
      届くかどうかは Apple 実機環境が必要でこの環境からは確認できない**
      — 新しい TestFlight ビルドをインストールし、push を有効化した状態で
      新着メールが届いた際に通知が表示されることを確認してほしい。
      優先度: 中 (次回 TestFlight ビルド配布時に確認) / 所要時間: 数分
      (既存の push 設定を一度無効化→再有効化して端末トークンを
      production 用として再登録させる必要がある) / 参照:
      [docs/xcode-cloud.md](docs/xcode-cloud.md)「既知の注意点」節、
      [PENDING.md](PENDING.md#公開時に必要な対応-まとめ)

---

## 優先度の目安

- **高**: 機能が「実際に動く」ことの確認そのものであり、未確認のままだと
  README/PENDING の「未検証」表記を外せない項目。
- **中**: 品質・体験に関わるが、今すぐ止める理由ではない項目。
- **低**: 公開・配布を具体的に検討し始めてから、または不具合報告があった
  時にだけ着手すればよい項目。
