# QA 探索的スイープ: 所見メモ

`docs/verify.md` に記録済みの実機バグ4連発 (VoIP ソケット/部分同期→スレッド
未割当/空応答→全削除/状態復元→UI崩壊・livelock) を踏まえ、シミュレータ上で
実ユーザーの雑な操作列 (kill/再起動連打、画面遷移の乱打、同期中の操作、
オフライン遷移の組合せ、Composer 境界ケース、境界データ、設定往復) を
`OtegamiQASweepUITests`/`OtegamiQASweepScenario2UITests`/
`OtegamiQASweepOfflineUITests` として XCUITest 化して実行したセッションの
所見。バグを見つけて修正できたものは各コミット + `docs/verify.md` に記録済み
(コールドランチがサイドバー最上位を素通りする問題、直前に選択していた行の
再タップが効かない問題 — commit `19fc366`)。本ファイルには、それ以外の
「修正不能級/設計判断が要る」項目、および「軽微な見た目の違和感 (真バグで
ないもの)」を記録する。

## 修正した実バグ (再掲・参照)

- コールドランチが (サイドバー最上位ではなく) 統合受信トレイ/メッセージ一覧
  から始まる。修正: `apps/Otegami/Sources/OtegamiApp.swift`/`SidebarView.swift`。
  詳細は `docs/verify.md`「実機バグ (続報2)」節。
- 「直前に選択していた行」(統合受信トレイ、開いていたスレッド) だけ再タップ
  してもタップ不能。同上の修正でカバー。

## 深掘りしたが「バグではなかった」項目 (記録価値のある調査)

### オフライン中の既読スワイプが「サーバーに反映されない」ように見えた件

`OtegamiQASweepOfflineUITests` 初版で、オフライン中に一覧の直前フェーズが
開いた (=ローカルで既読化された) メッセージを、続くフェーズでさらに
「既読にする」スワイプすると、`toggleRead` の意図通りの動作 (=すでに既読
なので未読への toggle) が実行され、結果としてサーバー側では未読のまま
になる。`sqlite3` で `otegami.sqlite` を直接見て `message.flagsRaw`/`opQueue`
テーブルの中身を突き合わせ、両方のオフライン操作 (開封時の既読化 opQueue
エントリ、スワイプの取り消し opQueue エントリ) が両方とも正しく enqueue
され、オンライン復帰後どちらも正しく replay されていたことを確認 — バグは
テストシナリオの設計 (同じメッセージに対して衝突する2つの操作を意図せず
積んでいた) 側にあり、アプリのロジックは正しかった。詳細は commit
`e7ed426` のコミットメッセージ、および `.claude/skills/verify/SKILL.md` の
今回追加分を参照。

## 軽微な所見・今後の検討事項 (真バグではない)

- **`.confirmationDialog`/`Alert` のアクションボタンが XCUITest の完全一致
  identifier lookup で over-count する**: `.claude/skills/verify/SKILL.md`
  に記録済み。アプリの表示自体は正しい (実際のスクリーンショットで確認済み)
  — XCUITest 側の `.firstMatch` が必要なだけ。
- **空になった `TextField` の `XCUIElement.value` がプレースホルダーを
  エコーする**: 同上、SKILL.md に記録済み。`composer.sendButton` の
  `Disabled` トレイトなど、依存する UI 信号のほうが信頼できる。
- **dev mailstack の iCloud KVS 実アカウント汚染**: このセッション中、
  `simctl erase` 直後でも実 iCloud 経由で過去の verify 実行分のアカウント
  (test1/test2) が resurrect する現象に何度も遭遇した (M11 で既知、
  `docs/verify.md` に記録済み)。新規に追加した QA スイープ系テストは全て
  「アカウントが既に存在する場合はスキップ」の防御的パターンを踏襲済みで
  実害は無いが、今後このセッションで作られた大量の verify 実行履歴により
  `Dovecot Test1`/`Dovecot Test2` アカウントが今後の `simctl erase` 後も
  居座り続ける可能性がある点は留意 (対処は "本来の権限の外" — ユーザー側で
  iCloud 設定からのリセットが必要)。
- **dev mailstack の Dovecot 認証がこの開発機の高負荷時に単発でタイムアウト
  する**: このセッション中、`accountSetup.testConnectionButton` からの
  接続テストが2回、「認証に失敗しました」で失敗した (dovecot 側ログで
  `auth_request_finished` の `duration` が通常10ms程度のところ1483msに
  伸びていたことを確認 — クライアント側のタイムアウトが先に切れたと見られる)。
  いずれも即座の再実行で再現せず、本セッション中に多数の `xcodebuild`/
  `docker`/`simctl` プロセスを同時多発的に走らせたことによる一過性の
  リソース枯渇と判断 (`docs/verify.md` の M2/M11 節に既出の同種の flake と
  同じ扱い)。アプリ側のリトライ/タイムアウト設定を見直す価値があるかは
  今後の検討課題として残す (実プロバイダに対しては起きにくいと見られる)。
- **境界データ (件名なし・本文空メール) の表示は正常**: `(件名なし)` の
  フォールバック表示、本文が空のメールを開いた際のクラッシュ無し、を
  スクリーンショットで目視確認済み (`OtegamiQASweepScenario2UITests
  .testNoSubjectAndEmptyBodyMessagesDisplayGracefully`)。既存の
  `ThreadRow.subjectText`/`MessageView` のフォールバック実装で十分だった。
- **検索の境界クエリ (0件・1文字・記号 `% _ "`・絵文字) はいずれもクラッシュ
  /ハングせず**、結果またはからっぽ状態のいずれかに正しく収束することを
  確認済み (`OtegamiQASweepScenario2UITests.testBoundarySearchQueries`)。
  SQLite の `LIKE`/FTS5 エスケープ周りで `%`/`_` が特殊文字として素通し
  されている可能性はあるが (`SearchQuery` のエスケープ処理は本調査の対象
  外)、少なくともクラッシュ・無限ローディングには繋がらないことは確認済み。
  `%`/`_` を含む検索が「意図しない広いマッチ」を返していないかは、
  `SearchQuery` の実装を読んだ厳密な検証まではこのセッションでは行って
  いない — 今後 `LIKE` エスケープの単体テストを追加する価値はあるかもしれ
  ない。

## 総回帰で見つかった、この開発機固有の既存の不整合 (QA スイープと無関係)

- **`OtegamiM6TypeSelectionUITests.testAllThreeAccountTypesAreOfferedAndGmailIsDisabledWithoutAClientId`
  がこの開発機では失敗する**: `apps/Otegami/Config/Local.xcconfig` に実の
  `GOOGLE_OAUTH_CLIENT_ID` が設定されているため (この開発機で Gmail OAuth
  の実機能を検証する目的と見られる)、Gmail ボタンは実際には有効になる —
  「Client ID 未設定なら無効化される」というテストの前提とこの開発機の
  ビルド設定が根本的に食い違っている。QA スイープの変更とは無関係な
  pre-existing の環境依存 (このテストは `GOOGLE_OAUTH_CLIENT_ID` が空の
  ビルドでのみ通る設計)。`scripts/verify-ios-m6.sh` の他フェーズ
  (`OtegamiM6ICloudFormUITests`/`OtegamiM6OtherAccountFlowUITests`/
  `OtegamiM6TypeSelectionUITests.testCancelDismissesTheTypeSelectionSheet`)
  は個別実行では正常に green (`set -euo pipefail` により、このテストの
  失敗でスクリプト全体が早期終了していただけ)。対応不要 — このテストを
  「常に green」にするには `GOOGLE_OAUTH_CLIENT_ID` を空にしたビルドで
  別途実行する仕組みが要るが、それは今回のタスクの範囲外と判断した。

- **`OtegamiM9PushSettingsUITests.testEnablingPushOnSimulatorShowsGracefulDegradationMessage`
  が `simctl erase` 直後の初回実行でのみ間欠的に失敗する**: consent alert
  タップ後、`settings.push.errorMessage` が最大40秒待っても現れないことが
  数回に1回発生した。同じシミュレータを erase せず使い回す再実行では毎回
  再現せず (`sidebar.settingsButton` 到達性の別問題は
  `returnToSidebarRootIfNeeded` 追加で修正済み — こちらは別件)。この
  セッション中ずっと `load average` が 264 前後という高負荷状態だったこと
  (`uptime`/`docker stats` で確認済み) と、`simctl erase` 直後の初回起動は
  Keychain access group のプロビジョニングや GRDB 初期化などの一度きりの
  セットアップコストが乗ることを踏まえると、機体負荷起因の一過性遅延と
  判断 (`registerForRemoteNotifications()` 自体は権限プロンプトを出さない
  ため、システムダイアログが割り込んでいる可能性は低い)。タイムアウトを
  20秒→40秒に伸ばした上でなお時々失敗するため、真の意味での確定的な修正
  ではないが、実装コード自体に手を入れる根拠 (実機/低負荷環境での再現)
  はこのセッションでは得られなかった。

## 未実施・今後の課題

- スレッド境界を跨ぐ「宛先だけのメール」(本文どころか宛先以外の情報が
  ほぼ無いメール) のような、より極端な境界データフィクスチャは今回追加
  しなかった (件名なし・本文空の2種類のみ追加)。必要なら
  `dev/mailstack/seed/fixtures/19-*.eml` として追加を検討。
- macOS 側は `make mac` のビルド確認のみ (Bug A/B の修正は compact 幅
  (iPhone) のみに影響する設計だが、`make mac` の実際の起動・操作までは
  このセッションで自動検証していない — `docs/verify.md` M10 節の手順に
  倣った手動確認が今後望ましい)。
