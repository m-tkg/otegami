# MailCore2 の調達方法

`packages/OtegamiKit/Sources/MailTransportMailCore` は `MailTransport` プロトコル層の
MailCore2 実装アダプタである。このドキュメントは MailCore2 本体をどう調達したか、
その判断理由、再現手順、既知の注意点を記録する。

## 結論: 自前 XCFramework ビルドではなく SPM ソースビルドを採用

当初計画では `scripts/build-mailcore2.sh` が MailCore2 を clone してビルドし、
`packages/OtegamiKit/Vendor/MailCore2.xcframework` を生成する想定だった。実際に調査・
試行した結果、**MailCore2 公式リポジトリ ([MailCore/mailcore2](https://github.com/MailCore/mailcore2))
の `readdle` フォーク ([readdle/mailcore2](https://github.com/readdle/mailcore2), ブランチ
`feature/spm-support`) が提供する、ソースから直接ビルドする Swift Package Manager 定義を
そのまま利用する** 方針に変更した。`packages/OtegamiKit/Package.swift` に

```swift
.package(url: "https://github.com/readdle/mailcore2.git", revision: "44c63329df67e9a0d597627edbebe65002d3fcd8"),
```

を追加し、`MailTransportMailCore` ターゲットが `.product(name: "MailCore", package: "mailcore2")`
に依存する形。`swift build` / `swift test` / Xcode でのビルドいずれも、この 1 依存を
追加するだけで MailCore2 本体・libetpan・ctemplate・tidy-html5・(Apple 版) ICU4Darwin
まで含めてソースから自動的にビルドされる。`scripts/build-mailcore2.sh` は
XCFramework を生成するスクリプトではなく、上記の解決・ビルドが通ることを確認する
検証スクリプトとして再定義した (実行内容は下記)。

### 判断理由

1. **自前 XCFramework ビルドは実際に試み、部分的に成功したが、実用上の再現性リスクが
   高いと判断した。** 検証の過程で分かったこと:
   - MailCore2 本体 (`build-mac/mailcore2.xcodeproj`) の Objective-C++/C++ ソース自体は
     Xcode 27 / arm64 でパッチなしにコンパイルが通った (懸念していた `OSAtomic` 等の
     廃止 API 依存は今回のリビジョンには存在しなかった)。
   - しかし付属の `scripts/build-mailcore2-xcframework.sh` は `ARCHS=x86_64` 固定
     (2019年頃の Intel Mac / iOS シミュレータ前提) で、Apple Silicon 対応には手を
     入れる必要がある。
   - 依存ライブラリ (ctemplate, libetpan, iOS 版はさらに tidy-html5, cyrus-sasl) の
     プリビルド済みバイナリ (`https://d.etpan.org/mailcore2-deps/`) は x86_64/armv7 等の
     旧アーキテクチャのみで、arm64 macOS・arm64 iOS シミュレータ向けには存在しない。
     自前ビルドが必要。
   - ctemplate・libetpan は同梱の `build-*-osx.sh`/`build-*-ios.sh` を軽く手直しすれば
     arm64 化はできそうだったが、iOS 版に必要な **cyrus-sasl (libsasl2) は
     autotools のクロスコンパイルを自前で組む必要があり** (`libetpan/build-mac/dependencies/prepare-cyrus-sasl.sh`
     が `armv7`/`armv7s` 前提の 2015 年頃のスクリプトで、`config.guess`/`config.sub` の
     更新や `configure --host` の調整が必要)、ここが最も時間を要し、かつ壊れやすい
     箇所だった。
   - 以上を全部自前で解決する労力に対して、次点の選択肢がそのまま動いたため、
     自前ビルドは採用しなかった (実装は残していない。パッチも作成していない)。

2. **`readdle/mailcore2` の `feature/spm-support` ブランチは、上記の依存関係
   (libetpan・ctemplate・tidy-html5・cyrus-sasl・ICU) を全て個別の SwiftPM パッケージ
   (`readdle/libetpan`, `readdle/ctemplate`, `readdle/tidy-html5`, `readdle/swift-unicode`)
   としてソースから解決するよう既に整備済みで、Apple Silicon 含む全アーキテクチャの
   ビルドが SwiftPM の標準ビルドグラフに乗る。** cyrus-sasl も
   `readdle/libetpan` パッケージ内にソースごと同梱されており、クロスコンパイルの
   自前実装が一切不要になる。Readdle 社は自社の Spark Mail アプリで実運用しており、
   各依存は `2.2.3-readdle.4` 等の tag で固定版が存在する (mailcore2 自体は
   tag 運用されていないため commit revision 固定)。
   プランの「SPM 対応フォークの利用...を調査して最も再現性の高い手段を選ぶ」という
   代替方針に該当する。

3. **「IMAP プロトコル実装を自作しない」という制約は満たしている**: 引き続き
   MailCore2 (と、その基盤である libetpan) が実際の IMAP/SMTP 通信を担う。今回の
   変更は「XCFramework を自前ビルドするか、ソースを SPM 経由で直接ビルドするか」という
   配布形態の選択にすぎない。

### 副次的なメリット

- `MailTransport` の抽象化により M1 で書いたコードは変更不要。`MailCoreIMAPSession`
  はいつも通り MailCore2 の Swift API (`MCOIMAPSession` 等、後述) をラップしている
  だけで、SPM 経由か XCFramework 経由かはリンク方法の違いでしかない。
- iOS 実機・シミュレータ・macOS の 3 ターゲットを個別に `xcodebuild archive` +
  `-create-xcframework` する手順が丸ごと不要になり、Xcode の通常の SPM 解決
  (`xcodegen generate` → `xcodebuild`) だけで完結する。
- CI (`macos-26` ランナー、Xcode 27) でも特別な事前ビルドステップなしに動く見込み
  (下記「CI への影響」参照)。

### トレードオフ・注意点

- `readdle/mailcore2` は MailCore2 公式ではなく Readdle 社のフォークである。
  `feature/spm-support` ブランチは tag 化されておらず、`Package.swift` では
  **ブランチ名ではなくコミット revision を固定** することで再現性を確保している
  (`44c63329df67e9a0d597627edbebe65002d3fcd8`, 2024-10-28 時点)。更新する場合は
  このファイルと `packages/OtegamiKit/Package.swift` の両方を書き換え、
  `dev/mailstack` を使った統合テスト (下記) を再実行して確認すること。
- MailCore2 の Swift ポート (`src/swift/`) は Objective-C 版 API をほぼ 1:1 で
  Swift に移植したもので、`ConnectionType` のように **Clang がそのまま struct
  (`init(rawValue:)` のみ、named case なし) としてインポートしている型**が
  混在している。`MailCoreIMAPSession+Mapping.swift` のコメントに詳細と根拠を
  記載した。
- ビルドは完全にソースからのコンパイルになるため、キャッシュが無い環境での初回
  `swift build` は libetpan/ctemplate/tidy-html5/MailCore2 本体のフルビルドが走るが、
  実測では十数秒〜数十秒程度で完了する (予想よりかなり軽い)。

## 既知の問題: SwiftPM のバイナリアーティファクトダウンロードがハングすることがある

`readdle/swift-unicode` (ICU の XCFramework, `readdle/icu4darwin` からダウンロード)
は `binaryTarget` として提供されている。開発中、`swift build`/`swift package resolve`
自身のダウンローダが **このアーティファクト (約 110MB) の取得だけで無限にハングする**
事象を観測した (同じ URL への `curl` は数秒で完了する。ネットワーク自体の問題では
なく、サンドボックス化された実行環境における SwiftPM 内蔵ダウンローダ固有の問題と
みられる)。GitHub Actions のような素の実行環境では発生しない可能性が高いが、念のため
`scripts/build-mailcore2.sh` に **`curl` で該当 URL を取得し、SwiftPM の共有アーティ
ファクトキャッシュ (`~/Library/Caches/org.swift.swiftpm/artifacts/<sanitized-url>`)
に直接配置してからビルドする** ワークアラウンドを実装した。チェックサムを
照合してから配置するため、`swift-unicode` 側のバージョンが変わってもチェックサム
不一致で安全に無視され、通常のダウンロードにフォールバックする。

同様の症状 (`swift build` が `Downloading binary artifact ...` の行で進捗なく止まる)
に遭遇した場合は、まず `scripts/build-mailcore2.sh` を実行するか、手動で:

```sh
curl -fL -o /tmp/icu.zip "https://github.com/readdle/icu4darwin/releases/download/68.2/icu68-2-darwin-no-strip-xcframework-dynamic.zip"
mkdir -p ~/Library/Caches/org.swift.swiftpm/artifacts
mv /tmp/icu.zip ~/Library/Caches/org.swift.swiftpm/artifacts/https___github_com_readdle_icu4darwin_releases_download_68_2_icu68_2_darwin_no_strip_xcframework_dynamic_zip
```

## `scripts/build-mailcore2.sh` の内容

1. 上記のダウンロードハング対策として、SwiftPM 共有アーティファクトキャッシュを
   `curl` で事前に埋める (キャッシュ済み・ダウンロード失敗時は何もせず通常経路に
   フォールバックするため、常に安全に実行できる)。
2. `packages/OtegamiKit` で `swift package resolve` → `swift build --target
   MailTransportMailCore` を実行し、MailCore2 込みで実際にビルドが通ることを確認する。

XCFramework 成果物は生成しない (生成すべきものが無いため)。`packages/OtegamiKit/Vendor/`
ディレクトリも使用していない。

## CI への影響

- `.github/workflows/ci-app.yml` (macOS ランナー) は `swift test` で
  `MailTransportMailCoreTests` を含む OtegamiKit 全体をビルドする。MailCore2 は
  ソースから取得・ビルドされるため、XCFramework の欠如によるビルド breakage は
  そもそも発生しない (これが SPM ソースビルド方式を選んだ理由の一つでもある)。
  `ci-app.yml` の実行結果は README 冒頭のバッジで確認できる。ローカルでの
  macOS / Xcode 27 環境での `make test` 相当の実行では、`dev/mailstack` を
  使った統合テストも含めて全て green (下記「統合テスト」参照)。
- `.github/workflows/ci-server.yml` (ubuntu ランナー) は Go 製の
  `server/otegami-relay-go` のみを検証し、`packages/OtegamiKit` には依存
  しないため無関係。
- `packages/OtegamiKit` を Linux 上で素の `swift test` (フィルタなし) 実行すると、
  `MailTransportMailCoreTests`/`MailTransportMailCore` は Objective-C++ ソースを
  含むため恐らくビルドに失敗する。現状の CI 構成 (ci-app.yml は macOS のみ、
  ci-server.yml は OtegamiKit に触れない) ではこのケースは発生しないため、
  ワークフロー自体の変更は行っていない。将来 Linux 上で OtegamiKit の一部だけ
  テストする CI ジョブを追加する場合は、`swift test --skip MailTransportMailCoreTests`
  のように対象を絞ること。

## 統合テスト (`Tests/MailTransportMailCoreTests`)

`dev/mailstack` の Dovecot に対する統合テストを追加した (環境変数
`OTEGAMI_TEST_IMAP_HOST` 未設定時は自動的に skip される)。実行手順:

```sh
make mailstack-up
make mailstack-seed
cd packages/OtegamiKit
OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter MailCoreIMAPSessionIntegrationTests
cd ../..
make mailstack-down
```

平文 (`localhost:1143`) ・TLS (`OTEGAMI_TEST_IMAP_TLS=1`, `localhost:1993`)
の両方で 3 テスト全て green。

### Dovecot 側の設定について

`dev/mailstack` の Dovecot はベースイメージの既定設定のままだと
`disable_plaintext_auth` 相当の設定 (Dovecot 2.4 系では設定名が
`auth_allow_cleartext`) が有効になり、平文ポート (`1143`) での `LOGIN` が
`NO [PRIVACYREQUIRED]` で拒否される。`docs/dev-mailstack.md` が前提とする
「IMAP: localhost:1143 で平文接続できる」を成立させるため、
`dev/mailstack/dovecot/conf.d/auth.conf` に `auth_allow_cleartext = yes` を
設定している (TLS ポート `1993` はこの設定に関係なく動作する)。

### MailCore2 アダプタ実装で踏んだ落とし穴 (`MailCoreIMAPSession+Mapping.swift` にも記載)

- `X-GM-THRID`/`X-GM-MSGID` の FETCH 属性は、サーバが `X-GM-EXT-1` (Gmail 拡張) を
  advertise していなくても libetpan がそのまま `UID FETCH` コマンドに含めてしまい、
  Dovecot 等の非 Gmail サーバは `BAD Unknown parameter: X-GM-THRID` で **FETCH
  コマンド全体を拒否する**。`connect()` 時に取得した capability を見て、Gmail
  拡張が無い場合はこれらの request kind を付けないよう `MailCoreIMAPSession` を
  修正した。
- `MCOMessageHeader.messageID`/`.references`/`.inReplyTo` は RFC 5322 の
  山括弧 (`<...>`) を取り除いた値を返す。`MailTransport.FetchedEnvelope` の
  ドキュメント上の契約 (山括弧付き) を保つため、アダプタ側で山括弧を再付与している。
- `MCOIndexSet(range: MailCoreRange(location:length:))` の `length` は要素数では
  なく「閉区間の終点までの距離」(`location...location+length` を表す) — ドキュメント
  化されていなかったため実機検証で確認した。
