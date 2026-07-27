# PENDING — ユーザー対応待ち事項

このファイルは、開発を進める上でユーザー本人の判断・手動作業が必要になった項目を記録する。
実装は各項目をモック/スキップ/dev mailstack 代替で進めており、開発の手を止めていない。
都合の良いときに対応し、必要であれば `Config/Local.xcconfig` 等の git 管理外ファイルに値を設定すること。

同じ内容を「今日やることリスト」の形に行動単位で並べ替えたものが
[`HUMAN_TASKS.md`](HUMAN_TASKS.md) にある。背景・理由・切り分けの経緯を
知りたい場合はこのファイル、次に何をやればいいかだけ知りたい場合は
`HUMAN_TASKS.md` を見ること。

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
- Gmail (`.oauth2`) アカウントのプッシュ通知: v1 のリレーは
  `WatchAuth.Kind.password` のみ対応 (プラン: "LOGIN/XOAUTH2 なし可:
  password のみ v1")。`AppEnvironment.enablePushNotifications` は
  `.password` アカウントのみ watch を作成し、Gmail アカウントは黙って
  スキップする — UI 上に「Gmail は現バージョン未対応」という文言は
  `PushNotificationSettingsView` の同意ダイアログに含めたが、Gmail
  アカウント一覧上で個別に無効化理由を出す UI までは実装していない。
  XOAUTH2 対応 (refresh token を預かる形) は M10 以降の課題。
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

## 起動/フォアグラウンド復帰時の本文バックグラウンドプリフェッチ — 実機での体感速度確認

**実装状況**: 「さっき読んだメールも、アプリを起動し直すと読み込みが
入る?表示まで時間がかかる」報告のうち、未オープンメッセージ
(`bodyState == .notFetched`) が初回オープン時にネットワーク取得を待つ
分を軽減する`SyncCoordinator.prefetchUnifiedInboxBodiesIfNeeded`を実装・
単体テスト済み (`UnifiedInboxPrefetchTests`、`FakeIMAPSession`で候補選定・
デバウンス・オフライン時の無言スキップ・認証エラー時の該当アカウントのみ
スキップを検証)。`make test`/`make ios`/`make mac`すべて green。詳細は
`docs/design-system.md`「C: 一度表示したメールを再度開くと毎回読み込みが
入る、体感が遅い」節のフォローアップ段落参照。

- **未確認**: dev mailstack (Dovecot) 越しの単体テスト以外での、実機
  (実 IMAP サーバー、実際のネットワーク遅延) を使った「起動直後に一覧を
  スクロールしてもすぐ本文が表示される」体感速度の確認。特に複数
  アカウント環境での逐次プリフェッチが実際の起動直後の数秒でどこまで
  終わるか (アカウント数・回線速度依存) は計測していない。
- **対応手順**: 実機またはより実回線に近いシミュレータで、複数アカウント
  (できれば実 Gmail/iCloud を含む) を登録した状態でアプリを再起動し、
  起動直後に統合受信トレイの上位30件前後を開いて本文が即座に表示される
  かを確認する。

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
