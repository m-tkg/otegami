# OTA (Ad Hoc) デプロイ

TestFlight や App Store を使わず、Apple の「Ad Hoc 配布 + itms-services」
の仕組みで、Mac から手元でビルドした Otegami を登録済みの iPhone に
OTA (Over-The-Air) でインストールするための仕組み。自分で管理する
サーバー (自宅サーバー・VPS など、HTTPS で公開できるものであれば何でも)
にホストする前提。

## 仕組み

1. Mac で `xcodebuild archive` → `xcodebuild -exportArchive` (Ad Hoc 配布、
   `apps/Otegami/Config/Local.xcconfig` の `DEVELOPMENT_TEAM` で署名) して
   `.ipa` を書き出す。
2. `manifest.plist` (iOS の itms-services が読む形式) を生成する。
   `software-package` の URL は `OTA_BASE_URL` (下記) 配下の
   `otegami.ipa` — itms-services はこの URL が **https であることを
   要求する** (http だとインストールが始まらない)。
3. `.ipa` + `manifest.plist` + 簡単な日本語インストールページ
   (`index.html`) を `ssh`/`scp` で `OTA_PI_HOST`/`OTA_PI_DIR`
   (下記) にアップロードする。アップロード先は `OTA_BASE_URL` で
   HTTPS 公開されている必要がある (nginx 等でこのディレクトリを配信
   するようリバースプロキシ設定しておく — 具体的な web サーバー設定は
   このリポジトリの対象外)。
4. iPhone の Safari で `OTA_BASE_URL` を開き「インストール」リンク
   (`itms-services://?action=download-manifest&url=...`) をタップすると
   インストールが始まる。

## 設定

`scripts/deploy-ota.sh` は配信先を表す3つの環境変数を要求する
(未設定だと分かりやすいエラーで停止する)。1回だけ設定すればよいので、
`scripts/deploy-ota.local.sh.sample` を `scripts/deploy-ota.local.sh`
(git 管理外) にコピーして埋めておく:

```sh
cp scripts/deploy-ota.local.sh.sample scripts/deploy-ota.local.sh
# scripts/deploy-ota.local.sh を編集して OTA_PI_HOST/OTA_PI_DIR/OTA_BASE_URL を設定
```

| 変数 | 内容 |
|---|---|
| `OTA_PI_HOST` | アップロード先への SSH 接続先 (`user@host` 形式) |
| `OTA_PI_DIR` | アップロード先のディレクトリ (存在しなければ作成される) |
| `OTA_BASE_URL` | そのディレクトリを配信する公開 HTTPS URL (末尾に `/ota` 等) |

環境変数として直接渡すこともできる (`scripts/deploy-ota.local.sh` より
優先される)。

## 使い方

```sh
make deploy-ota
```

内部で `scripts/deploy-ota.sh` を実行する。手順:
`xcodegen generate` → Release 構成で `xcodebuild archive` → `-exportArchive`
(Ad Hoc) → `manifest.plist`/`index.html` 生成 → 設定した配信先へ `scp`。

完了したら iPhone の Safari で `OTA_BASE_URL` を開き、「インストール」を
タップする。ホーム画面に追加されたら、設定 → 一般 → VPN とデバイス管理で
開発元 (`DEVELOPMENT_TEAM`) を信頼していることを確認してから起動する
(初回インストール時に案内される)。

## 前提

- **アップロード先が HTTPS で公開されており、プライベート CA を使う場合は
  それが iPhone にインストール・信頼済みであること** (`docs/relay-deployment.md`
  の「運用例: 宅内サーバー」参照。設定 → 一般 → 情報 → 証明書信頼設定 で
  明示的に有効化する手順を忘れずに)。
- **対象 iPhone の UDID が Apple Developer の Devices に登録済みで、
  Ad Hoc 配布用の Provisioning Profile に含まれていること**。
  `xcodebuild -allowProvisioningUpdates` が自動で処理するが、未登録の
  端末は Ad Hoc の仕組み上インストールできない (後述)。
- Mac からアップロード先への SSH 接続が通ること。
- `apps/Otegami/Config/Local.xcconfig` に実チームの `DEVELOPMENT_TEAM`
  が設定済みであること (README の「署名について」参照)。

## 制約

- **Ad Hoc 配布は Provisioning Profile に含まれる UDID の端末でしか
  インストールできない**。新しい端末を追加するには Apple Developer で
  UDID を登録し、プロファイルを作り直す必要がある (`-allowProvisioningUpdates`
  である程度自動化されるが、初回は数分かかることがある)。
- Apple Developer Program の年間契約ごとに登録できる端末数の上限がある
  (通常 100 台/デバイス種別)。
- Provisioning Profile には有効期限があり (通常 1 年)、切れると
  インストール済みのアプリも起動できなくなる。定期的な `make deploy-ota`
  の再実行 (＝プロファイルの更新) が実質的な対策になる。
- App Store 配布と違い、審査もサンドボックスの緩和もない。**個人・家族
  内利用の想定** であり、不特定多数に配る用途には向かない
  (`docs/relay-deployment.md` の脅威モデルと同じ前提)。

## トラブルシューティング

iPhone で「インストールできません」/ アプリが起動しない場合の典型的な
原因:

| 症状 | 典型的な原因 |
|---|---|
| リンクをタップしても何も起きない | `OTA_BASE_URL` に https でアクセスできていない (ネットワーク未接続、または `manifest.plist` の URL が http になっている) |
| 「"Otegami"を検証できません」等の署名エラー | プライベート CA が iPhone で信頼されていない、または Provisioning Profile の期限切れ |
| インストールは終わるが起動時に落ちる/開けない | 対象端末の UDID が Ad Hoc プロファイルに含まれていない (登録漏れ) |
| `manifest.plist` の取得でエラー | `software-package` の URL のドメイン/パスが実際にアップロードした場所とずれている。`curl -k <OTA_BASE_URL>/manifest.plist` で内容を確認する |
| `scripts/deploy-ota.sh` が `ssh` で落ちる | Mac 側からアップロード先へ到達できていない、またはホスト名/ユーザー名が変わった (`scripts/deploy-ota.local.sh` を更新) |
| `xcodebuild archive`/`-exportArchive` が署名エラーで落ちる | `Config/Local.xcconfig` の `DEVELOPMENT_TEAM` が未設定、または Apple Developer 側で証明書/プロファイルが失効している |

`scripts/deploy-ota.sh` は Xcode のバージョンによって `-exportArchive` の
`method` が `ad-hoc` と `release-testing` のどちらを要求するか変わりうる
ことを踏まえ、両方を試して動く方を使う。両方が「No signing certificate」
等の署名理由で失敗した場合は、さらに development 署名 (`debugging`
method) へフォールバックする — 配布先の実機はいずれも開発デバイス
登録済みなので、development 署名の IPA でも itms-services 経由で
インストールできるという割り切り。3段階すべて失敗した場合はログ
(`dist/ota/export.log`) にその時点のエラーがそのまま残る。

アップロード時は、アップロード先に既にある `otegami.ipa` を
`otegami-prev.ipa` へ1世代だけ退避してから新しい IPA を置く — 配信直後に
問題が見つかったとき、直前のビルドへ手動で戻せるようにするため。
