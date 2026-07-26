# PENDING — ユーザー対応待ち事項

このファイルは、開発を進める上でユーザー本人の判断・手動作業が必要になった項目を記録する。
実装は各項目をモック/スキップ/dev mailstack 代替で進めており、開発の手を止めていない。
都合の良いときに対応し、必要であれば `Config/Local.xcconfig` 等の git 管理外ファイルに値を設定すること。

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
は実装済み・単体テスト済み (`AccountCloudSyncTests`、15 件、`make test` に
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
     を seed 済み) を開き、翻訳バーが実際に訳文を表示するか確認する。
  4. 実機でも同じ `LanguageModelError -1` が出る場合はコード側の不具合
     の可能性が高まるので調査を再開する。実機では成功する場合は
     Simulator 固有の制限として `docs/translation.md` に確定情報を追記
     し、この節を消す。

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
