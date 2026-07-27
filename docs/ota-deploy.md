# OTA (Ad Hoc) デプロイ

Tailscale 経由でしか到達できない iPhone に、Mac から手元でビルドした
Otegami を OTA (Over-The-Air) でインストールするための仕組み。TestFlight
や App Store を使わず、Apple の「Ad Hoc 配布 + itms-services」を自宅の
Raspberry Pi (miscpi) の nginx 経由で行う。

## 仕組み

1. Mac で `xcodebuild archive` → `xcodebuild -exportArchive` (Ad Hoc 配布、
   `apps/Otegami/Config/Local.xcconfig` の `DEVELOPMENT_TEAM` で署名) して
   `.ipa` を書き出す。
2. `manifest.plist` (iOS の itms-services が読む形式) を生成する。
   `software-package` の URL は `https://otegami.mtkg/ota/otegami.ipa`
   — itms-services はこの URL が **https であることを要求する** (http だと
   インストールが始まらない)。
3. `.ipa` + `manifest.plist` + 簡単な日本語インストールページ
   (`index.html`) を、`ssh` 経由で自宅の Pi
   (`~/miscpi-container/otegami-ota/`) にアップロードする。このディレク
   トリは miscpi-nginx-container の `nginx` サービスに bind mount されて
   おり、`https://otegami.mtkg/ota/` 配下に配信される
   (`conf.d/services/otegami.conf` の `location /ota/`)。同じホスト名
   `otegami.mtkg` の `location /` は otegami-relay (プッシュ通知 API) への
   proxy のままで、`/ota/` の追加はそれとは独立したパスなので既存の
   `/v1/` `/health` には影響しない。
4. iPhone の Safari で `https://otegami.mtkg/ota/` を開き「インストール」
   リンク (`itms-services://?action=download-manifest&url=...`) をタップ
   するとインストールが始まる。

具体的なファイルの置き場所・nginx 設定は otegami リポジトリの外
(`mtkg-org/miscpi-nginx-container`, `mtkg-org/miscpi-container`, いずれも
private ではないが本書の対象外) にある。ここでは otegami 側の手順のみ
扱う。

## 使い方

```sh
make deploy-ota
```

内部で `scripts/deploy-ota.sh` を実行する。手順:
`xcodegen generate` → Release 構成で `xcodebuild archive` → `-exportArchive`
(Ad Hoc) → `manifest.plist`/`index.html` 生成 → Pi へ `scp`。

完了したら iPhone の Safari で `https://otegami.mtkg/ota/` を開き、
「インストール」をタップする。ホーム画面に追加されたら、設定 →
一般 → VPN とデバイス管理で開発元 (`DEVELOPMENT_TEAM`) を信頼している
ことを確認してから起動する (初回インストール時に案内される)。

## 前提

- **プライベート CA が iPhone にインストール・信頼済みであること**
  (`docs/relay-deployment.md` の「運用例: 宅内サーバー」参照。設定 →
  一般 → 情報 → 証明書信頼設定 で明示的に有効化する手順を忘れずに)。
- **対象 iPhone の UDID が Apple Developer の Devices に登録済みで、
  Ad Hoc 配布用の Provisioning Profile に含まれていること**。
  `xcodebuild -allowProvisioningUpdates` が自動で処理するが、未登録の
  端末は Ad Hoc の仕組み上インストールできない (後述)。
- Mac から `ssh masaki@miscpi.mtkg`(既定。`OTA_PI_HOST` で上書き可) が
  通ること (Tailscale 経由)。
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
| リンクをタップしても何も起きない | `https://otegami.mtkg/ota/` に https でアクセスできていない (Tailscale 未接続、または `manifest.plist` の URL が http になっている) |
| 「"Otegami"を検証できません」等の署名エラー | プライベート CA が iPhone で信頼されていない、または Provisioning Profile の期限切れ |
| インストールは終わるが起動時に落ちる/開けない | 対象端末の UDID が Ad Hoc プロファイルに含まれていない (登録漏れ) |
| `manifest.plist` の取得でエラー | `software-package` の URL のドメイン/パスが実際にアップロードした場所とずれている。`curl -k https://otegami.mtkg/ota/manifest.plist` で内容を確認する |
| `scripts/deploy-ota.sh` が `ssh` で落ちる | Mac 側が Tailscale に接続していない、または Pi 側のホスト名/ユーザー名が変わった (`OTA_PI_HOST` で上書き) |
| `xcodebuild archive`/`-exportArchive` が署名エラーで落ちる | `Config/Local.xcconfig` の `DEVELOPMENT_TEAM` が未設定、または Apple Developer 側で証明書/プロファイルが失効している |

`scripts/deploy-ota.sh` は Xcode のバージョンによって `-exportArchive` の
`method` が `ad-hoc` と `release-testing` のどちらを要求するか変わりうる
ことを踏まえ、両方を試して動く方を使う。両方失敗した場合はログ
(`dist/ota/export.log`) にその時点のエラーがそのまま残る。
