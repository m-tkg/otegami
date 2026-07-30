# HUMAN_TASKS — 人間 (ユーザー本人) がやる作業一覧

このファイルは「人間の行動」視点で、otegami の開発を進める上でユーザー
本人にしかできない作業をまとめたチェックリスト。完了したら削除する
運用 (完了項目の履歴は git log で追える)。

[`PENDING.md`](PENDING.md) は「何が技術的に未検証で、なぜか」を機能単位で
詳しく記録したドキュメント (設計判断の理由は各機能の doc — 主に
`docs/design-system.md`/`docs/qa-findings.md`/`docs/icloud-sync.md`/
`docs/translation.md`/`docs/relay-deployment.md` — に記録)。このファイルは
それを「今日やることリスト」として行動単位に並べ替えたもの。

---

## 1. 実機での確認 (シミュレータでは確認しきれなかったもの)

- [ ] **mailto: リンクの実機確認 (Task #48)** — 他のアプリ (メモ、Safari等)
      から `mailto:` リンクを開き、作成画面に to/cc/bcc/件名/本文がプリ
      フィルされること。設定 →「デフォルトのメールアプリに設定」の導線も
      確認。詳細: [docs/default-mail-app.md](docs/default-mail-app.md)
- [ ] **Task #44: Gmail「すべてのメール」の新着反映を実 Gmail アカウントで
      確認** — 単体テストのみ検証済み。他クライアントから新着を送った後、
      「すべてのメール」を開いたまま数分待ち、手動 pull-to-refresh なしで
      自動的に反映されることを確認する。詳細: [PENDING.md](PENDING.md)
      「Task #44」節。
- [ ] **Task #150: スレッド一覧で同じメールが2個ずつ表示される報告の詳細
      確認** — 再現しなかったため、実機で重複が見えたときの (a) 画面、
      (b) 一覧表示設定 (スレッドまとめ/フラット)、(c) 未読のみ/フラグ付き
      のみトグルの状態、(d) アカウントの種類・台数を教えてもらえると
      絞り込める。詳細: [PENDING.md](PENDING.md)「Task #150」節。
- [ ] **一連の新機能の画面確認 (Task #148/#156/#159/#160/#162/#165/#176/
      #178/#182/#184/#185/#186)** — それぞれ実装・単体テストは完了して
      いるが、タップ操作を伴う目視確認がシミュレータの既知不調で行え
      なかった。項目ごとの確認ポイントは [PENDING.md](PENDING.md) の
      該当節を参照。優先度が高いもの:
      - Task #184 (アーカイブ済みメールの「アーカイブ解除」表示) / Task
        #185 (件名表示) — 画面自体を一度も目視できていない。
      - Task #178 (文字色/ハイライトのダークモード黒文字化バグ修正) —
        ダークモードでの色選択→デフォルト復帰が核心の確認ポイント。
      - Task #162 (署名を本文に混在させない) — 署名選択・切替の見た目。
      - Task #129/#156/#161 (作成画面リッチテキスト化) — 書式バーの
        タップ操作全般、実メールクライアントでの受信側表示。

## 2. 実アカウントでの確認 (自分の認証情報が必要)

- [ ] **Task #116 (第2段): Azure AD アプリ登録 + Outlook/Office365 の実接続
      確認** — OSS のため Azure AD の Client ID をリポジトリに含めない
      方針。手順:
      1. [Azure Portal](https://portal.azure.com/) → Microsoft Entra ID
         → 「アプリの登録」で新規登録。「認証」→ リダイレクト URI
         `com.mtkg.otegami.msauth://oauth2redirect` を「モバイル
         アプリケーションおよびデスクトップアプリケーション」プラット
         フォームに登録し、「パブリック クライアント フローを許可する」
         を有効化する (未登録だと `redirect_uri_mismatch` で失敗する)。
      2. 発行された Client ID を `Config/Local.xcconfig` の
         `OTEGAMI_MICROSOFT_CLIENT_ID` に設定し、`make ios`/`make mac`
         で再ビルド。
      3. 「アカウントを追加」→「Outlook」/「Office365」で実際にサイン
         インし、INBOX 同期・送信・再認証・アクセス取り消し後の復旧を
         確認する。
      詳細: [docs/oauth-setup.md](docs/oauth-setup.md)「Microsoft OAuth
      Client ID の取得」節。
- [ ] **Task #175/#177: Gmail/Outlook アカウントのプッシュ通知を実機で確認**
      — リレーの `.oauth` watch (refresh token 交換) と
      `NotificationService` Extension の XOAUTH2 対応は実装・単体テスト
      済みだが、実 Google/Microsoft アカウント・実 push でのエンド
      ツーエンド確認はまだ。下記「3. インフラ・運用まわり」のリレー
      再デプロイ後、実際に通知を受け取り、差出人/件名が正しく書き換わる
      ことを確認する。詳細: [docs/relay-deployment.md](docs/relay-deployment.md)
      「既知の制約 / 今後」節。

## 3. インフラ・運用まわり

- [ ] **otegami-relay の再デプロイ (Task #169: SSRF/CRLFインジェクション等の
      セキュリティ修正、Task #175: Gmail/Outlook OAuth watch 対応)** —
      `server/otegami-relay`(Swift) または `server/otegami-relay-go`(Go
      移植版、Task #180 — ワイヤ/ストレージ完全互換) のいずれかで、
      通常の再デプロイ手順 (`docs/relay-deployment.md`「4. 起動
      (Docker)」) を実行し `main` の最新コミットで再ビルド・再起動する。
      Gmail の watch を使うなら `.env` に `RELAY_GOOGLE_CLIENT_ID` を、
      Outlook/Office365 なら `RELAY_MICROSOFT_CLIENT_ID` を設定する
      (アプリ側の同名 Client ID と同じ値にすること)。
      優先度: 高 (公開運用中のリレーに対する実際の脆弱性修正・Gmail/
      Outlookのプッシュ通知を有効化するために必須) / 参照:
      [docs/relay-deployment.md](docs/relay-deployment.md) の環境変数表・
      脅威モデル。
- [ ] **`RELAY_DEVICE_REGISTRATION_SECRET`/リレー URL をアプリのビルド設定
      に登録する (Task #171/#173)** — Google/Microsoft の OAuth Client ID
      と同じ仕組みで、配布経路ごとに3箇所 (`Config/Local.xcconfig`/
      GitHub Secrets/Xcode Cloud 環境変数) へ同じ値を設定する。**順序に
      注意**: リレー側を先に設定・再デプロイしてから、値を入れた次の
      ビルドを配布すること (逆順だと新規デバイス登録が一時的に失敗する)。
      未設定のビルドは「プッシュ通知」画面の「有効にする」ボタンが無効
      になるだけで、壊れるのではなく意図した縮退。詳細:
      [docs/relay-deployment.md](docs/relay-deployment.md)「設定値の
      全体像」節。

## 4. 公開・配布に向けて (App Store / TestFlight を目指す場合)

- [ ] **macOS ビルドの Developer ID 署名 + notarization (Task #143)** —
      GitHub Actions ワークフロー (`.github/workflows/release-macos.yml`)
      は整備済み、次回タグ push (または `workflow_dispatch`) の際に
      Actions の run が緑になるか、Gatekeeper (`spctl -a -vvv`) を越える
      か、iCloud 同期が動くかを確認する。参照:
      [docs/release.md](docs/release.md)。
- [ ] **`com.apple.developer.mail-client` entitlement — 承認後の有効化
      (Task #48)** — 申請済み (2026-07-28)、Apple の承認待ち。承認され
      たら (1) Developer Portal で対象 App ID の Mail capability を
      有効化、(2) `Config/Local.xcconfig` に
      `OTEGAMI_MAIL_CLIENT_ENTITLEMENT = YES` を追加、(3) 実機ビルドで
      「デフォルトのメールアプリに設定」からの設定 App 遷移を確認する。
      参照: [docs/default-mail-app.md](docs/default-mail-app.md)。
- [ ] **TestFlight ビルドで通知が届くことを確認する (Task #57)** —
      production/sandbox APNs 環境の自動判定は実装・単体テスト済みだが、
      実際に TestFlight ビルドをインストールした端末にプッシュ通知が
      届くかは Apple 実機環境が必要でこの環境からは確認できない。参照:
      [docs/xcode-cloud.md](docs/xcode-cloud.md)「既知の注意点」節。

---

## 優先度の目安

- **高**: 機能が「実際に動く」ことの確認そのものであり、未確認のままだと
  README/PENDING の「未検証」表記を外せない項目、または公開運用中のリレー
  に対する実際の脆弱性修正の適用。
- **中**: 品質・体験に関わるが、今すぐ止める理由ではない項目。
- **低**: 公開・配布を具体的に検討し始めてから、または不具合報告があった
  時にだけ着手すればよい項目。
