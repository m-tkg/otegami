# Xcode Cloud / TestFlight 配布

Otegami を Xcode Cloud でビルドし、TestFlight の内部テストグループに
配布できるようにするための設定・手順をまとめる。App Store Connect 側の
ワークフロー作成そのものはブラウザ/Xcode の GUI 操作なので人間が行う
(手順は下記)。このリポジトリ側で用意したのは、その GUI 操作が動く前提
となる `ci_scripts/`・`project.yml`/Info.plist の設定・検証結果。

## 全体像

```
GitHub の main ブランチに push
  → Xcode Cloud がリポジトリを clone
  → ci_scripts/ci_post_clone.sh (apps/Otegami/ci_scripts/) が実行される
      - xcodegen をインストール
      - 環境変数から Config/Local.xcconfig を生成
      - xcodegen generate で Otegami.xcodeproj を生成
  → Xcode Cloud が (Local.xcconfig 込みで生成された) プロジェクトを
    Archive アクションでビルド・cloud signing で署名
  → TestFlight の内部テストグループに自動配布
```

`apps/Otegami/Otegami.xcodeproj` は XcodeGen の生成物で git 管理外
(`.gitignore`) — ローカル開発でも `apps/Otegami/project.yml` 変更後は
`xcodegen generate` (`make` の各ターゲットが自動で実行する) が必要な
のと同じ理由で、Xcode Cloud 側もクローン直後に自分で生成しなければ
ビルド対象のプロジェクトファイルが存在しない。これが `ci_post_clone.sh`
の主目的。

## `ci_scripts` の配置場所

`apps/Otegami/ci_scripts/ci_post_clone.sh` に置いた
(リポジトリルートの `ci_scripts/` **ではない**)。Apple のドキュメント・
複数の実装例が一致して示す規約: **`ci_scripts` ディレクトリは、
ワークフローがビルド対象とする `.xcodeproj`/`.xcworkspace` と同じ階層に
置く**。このリポジトリでは `Otegami.xcodeproj` が (生成後に)
`apps/Otegami/` に置かれるので、`ci_scripts` もそこに置く。リポジトリ
ルートに置くのは、プロジェクトファイル自体がリポジトリルートにある
構成の場合の書き方であり、このリポジトリのようにモノレポの一部
(`apps/Otegami/`) にアプリがある場合は誤り (Xcode Cloud がスクリプトを
検出できない)。

サポートされるフック名は `ci_post_clone.sh`/`ci_pre_xcodebuild.sh`/
`ci_post_xcodebuild.sh` の3つ。今回使うのは `ci_post_clone.sh` (clone
直後、プロジェクトの依存解決より前に走る) のみ。

## `ci_post_clone.sh` がやっていること

`apps/Otegami/ci_scripts/ci_post_clone.sh` (実行可能ビット付き、
`set -euo pipefail`)。ローカルでも同じスクリプトをそのまま
ドライラン可能 (環境変数だけで分岐、実際の secrets は使わない):

```sh
OTEGAMI_DEVELOPMENT_TEAM=TESTTEAM1234 \
OTEGAMI_BUNDLE_ID=com.example.otegami.citest \
  apps/Otegami/ci_scripts/ci_post_clone.sh
```

1. **`xcodegen` のインストール** — Xcode Cloud の macOS イメージには
   Homebrew はプリインストールされているが XcodeGen は無いので
   `brew install xcodegen`。`.github/workflows/ci-app.yml` の同名ステップ
   と同じ理由・同じコマンド。
2. **`Config/Local.xcconfig` の生成** — このリポジトリは各開発者が
   git 管理外の `Config/Local.xcconfig` で Team ID 等を設定する方式
   (`Config/Local.xcconfig.sample` 参照)。Xcode Cloud にはそのファイルが
   無い (git 管理外なので clone されない) ので、ワークフローの環境変数
   から同じ内容を生成する。マッピングは:

   | Xcode Cloud 環境変数 | 書き込み先 (`Local.xcconfig`) | 必須 | 備考 |
   |---|---|---|---|
   | `OTEGAMI_DEVELOPMENT_TEAM` | `DEVELOPMENT_TEAM` | 実質必須 (無いと未署名ビルドにしかならず Archive できない) | Apple Developer の Team ID |
   | `OTEGAMI_BUNDLE_ID` | `OTEGAMI_BUNDLE_ID` | 任意 (既定 `com.mtkg.otegami` のまま) | 別の Team でこの Bundle ID が既に登録済みの場合のみ変更 |
   | `OTEGAMI_GOOGLE_CLIENT_ID` | `GOOGLE_OAUTH_CLIENT_ID` | 任意 (未設定なら Gmail 追加ボタンが無効なビルドになる) | `docs/oauth-setup.md` |
   | `OTEGAMI_RELAY_REGISTRATION_SECRET` | `OTEGAMI_RELAY_REGISTRATION_SECRET` | 任意 (未設定なら自分のリレーの `POST /v1/devices` にシークレットを送らないビルドになる — リレー側がそれを要求していなければ無関係) | `docs/relay-deployment.md` |
   | `OTEGAMI_PUSH_RELAY_URL` | `OTEGAMI_PUSH_RELAY_URL` | 任意 (未設定なら「プッシュ通知」画面の「プッシュ通知を有効にする」トグルが無効なビルドになる) | `docs/relay-deployment.md`。**値は素の URL のまま登録する** (`https://relay.example.test`) — `ci_post_clone.sh` が xcconfig の `//` コメント問題を回避する形式に自動変換して書き出すので、この環境変数自体に `$(...)` 構文を含める必要はない |
   | `OTEGAMI_MAIL_CLIENT_ENTITLEMENT` | `OTEGAMI_MAIL_CLIENT_ENTITLEMENT` | 任意 (既定 `NO`) | Apple から entitlement 許可が下りてから `YES` |

   いずれも未設定なら該当行を書かず、コミット済みの既定値
   (`Config/Shared.xcconfig`/`Signing.xcconfig`) がそのまま使われる —
   ローカル開発で `Local.xcconfig` を作らなくても `make ios`/`make mac`
   が動くのと同じフォールバック。

   **Xcode Cloud のワークフロー設定でこれらを追加する際は、
   `OTEGAMI_DEVELOPMENT_TEAM`/`OTEGAMI_GOOGLE_CLIENT_ID`/
   `OTEGAMI_RELAY_REGISTRATION_SECRET`/`OTEGAMI_PUSH_RELAY_URL` を
   "Secret" にチェックして値をマスクすること** (App Store Connect の
   Xcode Cloud → ワークフロー編集 → Environment → 環境変数追加画面に
   そのチェックボックスがある。`OTEGAMI_PUSH_RELAY_URL` の値自体は秘密
   ではないが、プライベートホスト名をビルドログに残さないため同じ扱い
   にする)。
3. **`CI_BUILD_NUMBER` → `CURRENT_PROJECT_VERSION`** — Xcode Cloud が
   ワークフロー実行ごとに払い出すビルド番号
   ([Environment variable reference](https://developer.apple.com/documentation/xcode/environment-variable-reference))。
   `Local.xcconfig` に `CURRENT_PROJECT_VERSION = <値>` として書き込む。
   `apps/Otegami/project.yml` 側は `CFBundleVersion: $(CURRENT_PROJECT_VERSION)`
   (Otegami ターゲット・NotificationService ターゲットの両方) と
   マクロ参照にしてあるので、ビルド時にこの値がそのまま
   `CFBundleVersion` に埋め込まれる (`GOOGLE_OAUTH_CLIENT_ID` など、
   他の環境依存キーと同じ仕組み)。XcodeGen の `info.path` モードは
   このキーを明示しないと固定リテラル `"1"` を自動生成してしまうため、
   何もしなければ2回目以降の TestFlight アップロードが「同じビルド番号の
   重複」として App Store Connect に拒否される — 今回の変更で初めて
   `$(CURRENT_PROJECT_VERSION)` 参照にした。
4. **`xcodegen generate`** — `apps/Otegami/` で実行し、
   `Otegami.xcodeproj` を生成する。

## `project.yml`/Info.plist に加えた TestFlight 対応

- **`ITSAppUsesNonExemptEncryption: false`** (Otegami ターゲットの
  Info.plist properties) — TestFlight へのアップロードは輸出規制
  (Export Compliance) の申告を要求する。このアプリが使う暗号化は
  IMAP/SMTP over TLS (MailCore2)・HTTPS (`URLSession`、Google OAuth/
  otegami-relay 通信)・Keychain (OS 標準) のみで、独自の暗号アルゴリズム
  実装や輸出規制対象国向けの特別な強度の暗号は含まない — 標準的な
  TLS/HTTPS のみを使うアプリは輸出規制の対象外 (exempt) に分類される。
  このキーを `false` にしておくことで、アップロードのたびに
  App Store Connect の Web UI で同じ質問に答える手間を省ける。
- **`CFBundleVersion: $(CURRENT_PROJECT_VERSION)`** — 上記
  「`CI_BUILD_NUMBER` → `CURRENT_PROJECT_VERSION`」参照。
- **共有スキーム** — Xcode Cloud はビルド対象に共有スキーム
  (`xcshareddata/xcschemes/`) を要求する。`project.yml` の
  `schemes: Otegami:` は XcodeGen の既定で共有スキームとして書き出される
  ことを、実際に `xcodegen generate` した `Otegami.xcodeproj` に
  `xcshareddata/xcschemes/Otegami.xcscheme` が生成されることで確認済み。
- **署名方式** — `Config/Signing.xcconfig` は既に `CODE_SIGN_STYLE:
  Automatic` (project.yml の `settings.base`)。Xcode Cloud の
  cloud signing は Automatic signing 前提で動くので、追加の変更は
  不要だった。

## 検証したこと・していないこと

### 検証済み (ローカルで再現できる範囲)

- **クリーンクローン → `ci_post_clone.sh` → `xcodegen generate`**:
  一時ディレクトリにこのリポジトリを `git clone` し、テスト用の
  ダミー環境変数 (`OTEGAMI_DEVELOPMENT_TEAM=TESTTEAM1234` 等、実際の
  Team ID ではない) で `ci_post_clone.sh` を実行 → `Local.xcconfig` が
  期待通り生成され、`xcodegen generate` が成功することを確認した。
- **ビルド番号・輸出規制キーの実際の反映**: 上記クリーンクローンで
  `CI_BUILD_NUMBER=42` を渡して未署名ビルド (`CODE_SIGNING_ALLOWED=NO`、
  `.github/workflows/ci-app.yml` と同じ方式) を実行し、生成された
  `Otegami.app/Contents/Info.plist` を確認 —
  `CFBundleVersion` は `42`、`ITSAppUsesNonExemptEncryption` は
  `false` として実際に埋め込まれていた (マクロ参照が machinery として
  機能することの確認)。
- **既存のローカルビルドを壊していないこと**: 変更後の `project.yml`
  で `make test`/`make ios`/`make mac` がいずれも成功することを確認
  (このリポジトリの実 Team ID・実 Bundle ID で署名する通常の開発ビルド)。
- **実 Team ID での Release archive**: `apps/Otegami/Config/Local.xcconfig`
  (このマシンの実 Team ID) を使って `xcodebuild archive`
  (`-configuration Release`, `-destination generic/platform=iOS`,
  Automatic signing) を実行し、成功することを確認した。

### 検証できていないこと

Apple Developer / App Store Connect 側の実際の操作が必要で、このリポジトリの外の話のため:

- **Xcode Cloud の実ワークフローでのビルド** — App Store Connect 上での
  ワークフロー作成・cloud signing の実行はこの環境からは行えない。
  上記のローカル検証は「Xcode Cloud が実行する手順のうち、このリポジトリ
  内で完結する部分」を模擬したものであり、Apple 側のインフラ固有の
  問題 (証明書の自動発行、TestFlight への実際の配信など) は初回の実行で
  初めて確認できる。
- **cloud signing による実際の App Store 配布用アーカイブ** —
  ローカルで確認した Release archive は Automatic signing が実際に
  選んだ **Development 証明書・Development プロビジョニングプロファイル**
  で署名されたもので (`xcodebuild archive` を単体で叩いた場合の既知の
  挙動 — Xcode の GUI から Archive してエクスポート方法を選ぶ、または
  Xcode Cloud 自身がワークフローの Archive アクションとして実行する
  場合は Distribution 証明書が使われる)、TestFlight に実際に提出できる
  App Store 配布用アーカイブそのものではない。下記の APNs の注意点も
  この差異に関係する。

## 既知の注意点

### APNs 環境の自動判定 (TestFlight は常に production)

Apple の仕様上の制約: `aps-environment` の実際の値は署名に使う
プロビジョニングプロファイルの種類で決まり、Development プロファイルは
`development` しか持てず、Distribution 系プロファイル (Ad Hoc/App Store)
は `production` しか持てない。`apps/Otegami/Config/Otegami-iOS.entitlements`
の `aps-environment` ソース側の値は (Automatic signing の下では) 実際に
割り当てられるプロファイルに応じて署名時に上書きされるため
`development` 固定のままで構わない。

アプリ側は、ビルド設定 (Debug/Release) で分岐させる方式ではなく、
実行時にこのバイナリが実際にどちらの環境で署名されたかを
`embedded.mobileprovision` の `Entitlements.aps-environment` を読んで
判定する方式を採っている —
`packages/OtegamiKit/Sources/PushRelayClient/APNSEnvironmentDetector.swift`
(`APNSEnvironmentDetector.detectedEnvironment(bundle:)`)。埋め込み
プロビジョニングプロファイルが存在しない/parse できない場合は
`.production` にフォールバックする — App Store/TestFlight 配布では
`embedded.mobileprovision` が同梱されない (または簡単には見つけられない)
ことがあるため、「見つからない = production」が安全なデフォルトになる
(Debug/Ad Hoc ビルドは必ずプロファイルを同梱するので、このフォール
バックが実際に踏まれるのは配布ビルドだけ)。`AppEnvironment.swift` の
デバイス登録呼び出し (`registerDevice`/`updateDeviceToken`) はこの判定
結果を送る。

`server/otegami-relay`/`server/otegami-relay-go` 自体はデバイスごとに
`sandbox`/`production` を切り替えられる設計 (`OtegamiRelayAPI
.RegisterDeviceRequest.Environment`、`APNsSender.host(for:)`) なので、
リレー側の変更は不要 — この判定はアプリ側だけで完結する。

`APNSEnvironmentDetectorTests`
(`packages/OtegamiKit/Tests/PushRelayClientTests/`) がプロビジョニング
プロファイルのパース (development→sandbox / production→production /
欠落・不正値→production フォールバック) をユニットテストで検証している。
**既知の制限**: 実際に TestFlight ビルドでプッシュが届くことの確認
(E2E) は Apple の実機・実インフラが必要で、この開発環境からは確認
できない。TestFlight ビルドを配布した際は一度実機で確認すること。

### Google OAuth が「未検証アプリ」のまま TestFlight 内部テストで使われる

`docs/oauth-setup.md` の通り、Gmail 連携 (Google OAuth) の審査は
**配布ビルド (App Store/TestFlight) を出す場合にのみ**必要になる。
審査を通していない (OAuth 同意画面が「テスト」ステータスのままの) 状態で
TestFlight 内部テストを配る場合:

- OAuth 同意画面に**明示的に追加した「テストユーザー」の Google
  アカウントでしか** Gmail ログインが成功しない。TestFlight の内部
  テスターを増やす場合は、その人の Gmail アドレスも Google Cloud
  Console の OAuth 同意画面「テストユーザー」に個別に追加する必要が
  ある (最大 100 件までという Google 側の上限があるが、内部テストの
  規模なら通常問題にならない)。
- テストユーザーに追加していないアカウントでログインしようとすると
  Google 側が拒否する (「このアプリは Google の確認を受けていません」
  という警告だけでなく、テストユーザー未登録なら同意画面自体に
  到達できない)。
- Gmail 以外のアカウント (パスワード認証の IMAP/SMTP アカウント) は
  この制約を受けない。TestFlight での動作確認を Gmail 以外のアカウントで
  行うなら審査・テストユーザー登録は不要。
- 本番審査 (OAuth 同意画面を「本番」に切り替え) が必要になるのは、
  不特定多数への一般公開 (App Store 公開審査に相当するタイミング) を
  する場合のみ — `contacts.other.readonly`/`contacts.readonly` は
  機密性の高いスコープとして追加の審査項目になる点も
  `docs/oauth-setup.md`「`contacts.other.readonly`・`contacts.readonly`」
  節を参照。

## Apple Developer / App Store Connect 側の手順 (ユーザー本人が行う)

このリポジトリの外側、App Store Connect の Web UI・Xcode の GUI 操作。

1. **App Store Connect にアプリレコードを作成する** — App Store Connect
   → 「マイ App」→ 「+」→「新規 App」。Bundle ID は
   `com.mtkg.otegami` (`Config/Signing.xcconfig` の既定値。別の
   Bundle ID を使っている場合はそちらに合わせる) を、Apple Developer の
   「識別子」に事前登録した上で選択する。
2. **Xcode で Xcode Cloud のワークフローを作成する** — ローカルで
   `apps/Otegami` を `xcodegen generate` して開いた `Otegami.xcodeproj`
   を Xcode で開き、Report Navigator (⌘9) →「Cloud」タブ →「Get Started」
   →「Otegami」ターゲットを選択 → 使用する Apple ID (App Store Connect
   への権限を持つもの) でサインインし、リポジトリ (この GitHub
   リポジトリ) への接続を許可する。
3. **ワークフローを設定する** — 既定で提案されるワークフローを編集し:
   - **Start Condition**: `main` ブランチへの push (必要に応じて調整)。
   - **Actions**: Archive を追加 (iOS destination)。
   - **Post-Actions**: 「TestFlight (Internal Testing Only)」を追加し、
     配布先の内部テスターグループを選択 (無ければここで新規作成)。
4. **環境変数を設定する** — ワークフロー編集画面の「Environment」→
   「Environment Variables」で上表 (「`ci_post_clone.sh` がやっている
   こと」節) の変数を追加する。`OTEGAMI_DEVELOPMENT_TEAM`/
   `OTEGAMI_GOOGLE_CLIENT_ID`/`OTEGAMI_RELAY_REGISTRATION_SECRET`/
   `OTEGAMI_PUSH_RELAY_URL` は「Secret」にチェックを入れる。
5. **署名 (cloud signing) を有効化する** — 初回のワークフロー作成時に
   Xcode Cloud が「Xcode Cloud が証明書/プロビジョニングプロファイルを
   自動管理してよいか」を確認するダイアログを出す。許可すると
   Distribution 証明書・App Store プロビジョニングプロファイルを
   Xcode Cloud が自動発行・管理する (Apple Developer Program の
   Account Holder/Admin 権限が必要)。
6. **初回ビルドを確認する** — ワークフローを保存すると初回ビルドが
   自動的にキックされる (または Xcode の Cloud タブから手動トリガー)。

   > **このリポジトリの実運用**: リリース用ワークフローの開始条件は
   > **git tag** に設定してある。リリース
   > したいコミットに tag を打って push すると Xcode Cloud が
   > Archive → TestFlight 配布を実行する。ブランチ push では
   > リリースビルドは走らない。開発中の即時配信は従来どおり
   > `make deploy-ota` (Ad Hoc) を併用する。
   Archive アクションが成功し、TestFlight の対象アプリに新しいビルドが
   表示され、「処理中」→「テスト可能」になることを確認する。失敗した
   場合は Xcode の Cloud タブ、または App Store Connect の Xcode Cloud
   セクションからビルドログを確認できる — 上記「既知の注意点」の
   APNs entitlements 起因のエラーが出ないか特に確認すること。
7. **内部テスターを追加する** — App Store Connect →「TestFlight」→
   対象アプリ →「内部テスト」グループにテスターの Apple ID (メール
   アドレス) を追加する。テスターがそのメールアドレスで Gmail 連携を
   試す場合は、上記「Google OAuth が『未検証アプリ』のまま」節の通り
   Google Cloud Console 側のテストユーザーにも同じアドレスを追加する
   こと。

## 関連ドキュメント

- [docs/oauth-setup.md](oauth-setup.md) — Google OAuth Client ID の
  発行・テストユーザー・審査。
- [docs/relay-deployment.md](relay-deployment.md) — otegami-relay
  (プッシュ通知) のデプロイ・APNs `.p8` キー。
- [docs/ota-deploy.md](ota-deploy.md) — App Store Connect を経由しない
  もう一つの配布経路 (Ad Hoc + itms-services)。Xcode Cloud/TestFlight
  とは独立に今後も使える。
- [docs/default-mail-app.md](default-mail-app.md) —
  `com.apple.developer.mail-client` entitlement。
- [docs/ci.md](ci.md) — GitHub Actions (`ci-app`/`ci-server`) 側の CI。
  Xcode Cloud はこれを置き換えるものではなく、TestFlight 配布に特化した
  別の CI パイプラインとして並行して使う。
- [docs/release.md](release.md) — 同じ tag push で並行して走る macOS 側
  のリリースパイプライン (GitHub Actions → Developer ID 署名 +
  notarization → GitHub Release 添付)。
