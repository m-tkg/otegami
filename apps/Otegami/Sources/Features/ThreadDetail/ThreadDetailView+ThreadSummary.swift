import Foundation
import SwiftUI
import GRDB
import OtegamiCore
import OtegamiStore
import OtegamiTranslation

// MARK: - Task #153: スレッド全体のAI要約

extension ThreadDetailView {
    /// ナビゲーションタイトル横のトグルボタン (`!isFlatModeEntry`のときだけ
    /// `body`の`.toolbar`から呼ばれる) — アイコンは`MessageToolbarAction
    /// .summarize`と同じ`"sparkles"`(`MessageDetailFooterToolbar
    /// .summarizeButton`と見た目を揃える一貫性のため)。単一メッセージの
    /// `summarizeButton`と違い有効/無効の複雑な条件は無く、`messages`が
    /// まだ空 (スレッド読み込み中) の間だけ無効化する。
    var threadSummarizeToolbarButton: some View {
        Button(action: handleThreadSummarizeTap) {
            if threadSummaryState.isSummarizing {
                ProgressView()
            } else {
                Image(systemName: "sparkles")
            }
        }
        .disabled(messages.isEmpty)
        .accessibilityIdentifier("threadDetail.toolbar.summarizeThread")
        .accessibilityLabel(Text(threadSummarizeAccessibilityLabel))
    }

    /// `MessageDetailFooterToolbar.handleSummarizeTap()`と同じ形 — 未生成/
    /// 失敗時は生成を起動し、いずれの状態でも (生成中・生成済みも含め)
    /// シートを開く。
    private func handleThreadSummarizeTap() {
        switch threadSummaryState {
        case .none, .failed:
            requestThreadSummary()
        case .summarizing, .summarized:
            break
        }
        isShowingThreadSummarySheet = true
    }

    private var threadSummarizeAccessibilityLabel: String {
        switch threadSummaryState {
        case .none: String(localized: "スレッドを要約")
        case .summarizing: String(localized: "要約中")
        case .summarized: String(localized: "スレッドの要約を表示")
        case .failed: String(localized: "スレッドの要約を再試行")
        }
    }

    /// `MessageView.summarySheet`と同じ構造 (生成中/完成/失敗の3状態 +
    /// 「再生成」) — 単一メッセージ版と違い「詳しく要約」の2択は無い
    /// (Task #153の範囲外)。`SummaryText`(`MessageView.swift`、Task #153で
    /// `private`を外して共有化) をそのまま再利用: `"■"`始まりの行を太字に
    /// するだけの汎用的な整形。Task #160フォローアップ5 (最終形の簡素化)
    /// で`summarizeThread`の出力から■経緯/■現状のラベル自体が無くなった
    /// ので、太字化は今は実質発火しない (空行区切りのper-message抽出結果
    /// がそのまま地の文で並ぶ) — それでも`SummaryText`を差し替えていない
    /// のは、ラベル文字列の有無に依存しない汎用実装のままで問題なく動く
    /// ため。
    var threadSummarySheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OtegamiSpacing.md) {
                    switch threadSummaryState {
                    case .none:
                        EmptyView()
                    case .summarizing:
                        VStack(spacing: OtegamiSpacing.sm) {
                            ProgressView()
                                .accessibilityIdentifier("threadDetail.summarySheet.loading")
                            // Task #160: メッセージ単位でモデルを複数回
                            // 実行するようになった分、生成に時間がかかる
                            // ことがある — `threadSummaryProgress`が届き
                            // 次第「今n通目/m通中」を出す (届く前の一瞬は
                            // `ProgressView`だけ)。動的な数値の埋め込みで
                            // 固定文言部分の意味は変わらないため、通常の
                            // 文字列補間`Text`のままでよい (CLAUDE.mdが
                            // `Text(verbatim:)`を求めているのはアカウント
                            // 表示名・検索クエリのような外部由来の動的
                            // 文字列がMarkdown解釈で事故る場合の話で、ここ
                            // は整数2つだけ)。
                            if let progress = threadSummaryProgress {
                                Text("\(progress.current)/\(progress.total) 通目を要約中…")
                                    .font(OtegamiFont.caption())
                                    .foregroundStyle(OtegamiColor.inkSecondary)
                                    .accessibilityIdentifier("threadDetail.summarySheet.progress")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, OtegamiSpacing.xl)
                    case .summarized(let text):
                        SummaryText(text: text)
                            .accessibilityIdentifier("threadDetail.summarySheet.text")
                    case .failed(let failureMessage):
                        // `MessageView.summarySheet`と同じ理由で非ローカライズ
                        // (実行時の値を含むため)。
                        Text("要約に失敗しました: \(failureMessage)")
                            .font(OtegamiFont.subheadline())
                            .foregroundStyle(OtegamiColor.destructive)
                            .accessibilityIdentifier("threadDetail.summarySheet.footnote")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("スレッドの要約")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { isShowingThreadSummarySheet = false }
                        .accessibilityIdentifier("threadDetail.summarySheet.closeButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if threadSummaryState.isSummarizing {
                        ProgressView()
                    } else {
                        Button("再生成") { requestThreadSummary() }
                            .accessibilityIdentifier("threadDetail.summarySheet.regenerateButton")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// `MessageView.requestSummary(message:)`と同じ形 (`summaryTask`と同じ
    /// 「既に実行中なら二重起動しない」ガード、`TranslationServiceError`を
    /// `.userFacingMessage`へ変換する同じcatch) だが、対象は現在展開中の
    /// 1通ではなく`messages`全件 — ソーステキストは
    /// `threadSummarySourceEntries()`、呼び出す先は`summarizeThread`
    /// (per-message抽出結果を時系列に並べたリスト、`TranslationService`の
    /// doc comment参照)。
    ///
    /// Task #160: `onProgress`で「今n通目/m通中」を`threadSummaryProgress`
    /// へ反映する — `summarizeThread`のdoc comment参照のとおり、この
    /// クロージャは`@MainActor @Sendable`なので`self`(このView自身、
    /// 非Sendableな`struct`)を直接キャプチャして`@State`へ書き込んでも
    /// 安全 (MainActor隔離そのものがSendableが要求する安全性の裏付けに
    /// なる)。
    private func requestThreadSummary() {
        guard threadSummaryTask == nil else { return }
        threadSummaryState = .summarizing
        threadSummaryProgress = nil
        let translator = environment.translationService
        let targetLanguage: TranslationLanguage = LocalizationSettingsStore.effectiveLanguageCode == "en" ? .english : .japanese
        threadSummaryTask = Task {
            let entries = await threadSummarySourceEntries()
            guard !entries.isEmpty else {
                threadSummaryState = .failed("本文を取得できませんでした。しばらくしてからもう一度お試しください。")
                threadSummaryTask = nil
                return
            }
            do {
                let result = try await translator.summarizeThread(entries, targetLanguage: targetLanguage) { current, total in
                    threadSummaryProgress = (current, total)
                }
                guard !Task.isCancelled else { return }
                threadSummaryState = .summarized(result)
            } catch {
                guard !Task.isCancelled else { return }
                if let serviceError = error as? TranslationServiceError {
                    threadSummaryState = .failed(serviceError.userFacingMessage)
                } else {
                    threadSummaryState = .failed(error.localizedDescription)
                }
            }
            threadSummaryProgress = nil
            threadSummaryTask = nil
        }
    }

    /// Task #153 (入力の組み立て) → Task #160 (メッセージ単位のmap段への
    /// 変更) → Task #160フォローアップ (二重圧縮の根治、`header`の日付
    /// フォーマットを短縮): `messages`(時系列順、`ThreadQuery
    /// .messages(threadId:db:)`の`ORDER BY internalDate, uid`のdoc comment
    /// 参照)の各メッセージについて、`TranslationService.summarizeThread(_:
    /// targetLanguage:onProgress:)`のマップ段が読む`ThreadDigestMessage`を
    /// 1件組み立てる — `header`は`"[M/d] 差出人:"`(モデルには決して生成
    /// させない確定文字列。`summarizeThread`が組み立てる`■経緯`の箇条書き
    /// と、`■現状`用モデル入力の各行、両方でそのまま使われる)、`text`は
    /// そのメッセージの新規本文のみ (`ThreadDigestMessage`のdoc comment
    /// 参照 — マップ段の`summarizeThreadEntry`モデル呼び出しは`text`だけを
    /// 見る)。`SummaryInputBuilder`は使わない — あれは単一メッセージ要約
    /// 専用の「引用の有無だけを伝える注記」ラッパーで、スレッド全体の
    /// ダイジェストが必要とする「各メッセージの新規本文をそのまま並べる」
    /// 入力とは形が違う(タスク仕様どおり)。
    ///
    /// **日付フォーマットをTask #160の`"yyyy/MM/dd HH:mm"`から`"M/d"`
    /// (`.dateTime.month().day()`) へ短縮**: 以前は経緯パート自体もこの
    /// フォーマットの行を並べたものをモデルへ渡すだけだったので日時の
    /// 精度がそのまま経緯パートの精度になっていたが、今は`■経緯`が
    /// アプリ側の箇条書き表示そのものであり、ユーザーが読む一覧として
    /// 「月/日」程度の粒度の方が簡潔で読みやすい (`ThreadDetailView`の
    /// 新しい`■経緯`はチャット風の箇条書きであり、時刻までは通常不要)。
    ///
    /// 本文がまだローカルにキャッシュされていないメッセージ (`bodyState`が
    /// `.notFetched`のまま — このスレッドの「開いている1通」以外は
    /// `MessageView`の`load()`が走っていないため、まだ未取得のことがある)
    /// は、`MessageView.retryBodyFetchForSummary(message:)`と同じ考え方で
    /// 一度だけネットワーク越しの取得を試みる — 失敗すればそのメッセージは
    /// 静かにスキップする (ベストエフォート、スレッド全体の要約自体は
    /// 取得できた分だけで続行する)。差出人名は`message.fromAddresses.first?
    /// .name ?? .address ?? "?"` — `EmailAddress.description`(`"名前
    /// <address>"`形式)は使わない: タスク仕様「差出人名は入力に書かれて
    /// いる名前のみ使用・推測禁止」を守るため、モデルに渡す文字列に
    /// アドレスを機械的に付加するようなことをせず、本文中の`From:`名前
    /// (無ければアドレスそのもの) だけをそのまま渡す。
    private func threadSummarySourceEntries() async -> [ThreadDigestMessage] {
        guard let accountId, let account = environment.accounts.first(where: { $0.id == accountId }) else { return [] }
        var entries: [ThreadDigestMessage] = []
        for message in messages {
            guard let messageId = message.id else { continue }
            var bodyRecord = try? await Self.fetchBodyRecord(messageId: messageId, db: environment.database.dbWriter)
            if bodyRecord == nil {
                await fetchBodyOverNetworkForThreadSummary(message: message, account: account)
                bodyRecord = try? await Self.fetchBodyRecord(messageId: messageId, db: environment.database.dbWriter)
            }
            guard let bodyRecord, let newText = Self.newTextForThreadSummary(bodyRecord: bodyRecord, isReply: message.inReplyTo != nil) else { continue }
            let senderName = message.fromAddresses.first?.name ?? message.fromAddresses.first?.address ?? "?"
            let dateText = (message.date ?? message.internalDate).formatted(.dateTime.month().day())
            entries.append(ThreadDigestMessage(header: "[\(dateText)] \(senderName):", text: newText))
        }
        return entries
    }

    private nonisolated static func fetchBodyRecord(messageId: Int64, db dbWriter: any DatabaseWriter) async throws -> MessageBodyRecord? {
        try await dbWriter.read { db in try MessageBodyRecord.fetchOne(db, key: messageId) }
    }

    /// `MessageView.fetchBodyOverNetwork(message:)`と同じ経路 (`SyncCoordinator
    /// .fetchBody(for:mailboxPath:account:auth:)`) だが、失敗を伝播せず
    /// 常にベストエフォートで握り潰す — `threadSummarySourceEntries()`は
    /// 取得できなかったメッセージをそのままスキップして続行する契約のため。
    private func fetchBodyOverNetworkForThreadSummary(message: MessageRecord, account: AccountRecord) async {
        guard let auth = try? await environment.auth(for: account) else { return }
        guard let mailboxPath = try? await Self.mailboxPath(mailboxId: message.mailboxId, db: environment.database.dbWriter) else { return }
        try? await environment.syncCoordinator.fetchBody(for: message, mailboxPath: mailboxPath, account: account, auth: auth)
    }

    private nonisolated static func mailboxPath(mailboxId: Int64, db dbWriter: any DatabaseWriter) async throws -> String? {
        try await dbWriter.read { db in try MailboxRecord.fetchOne(db, key: mailboxId)?.path }
    }

    /// `MessageView.sourceTextForSummary()`と同じ「新規/引用分離 → 安全網
    /// としてもう一度`HTMLTextExtractor`」の経路だが、`SummaryInputBuilder`
    /// は経由しない (このメソッドのdoc comment参照) — `newText`をそのまま
    /// 返す。
    private nonisolated static func newTextForThreadSummary(bodyRecord: MessageBodyRecord, isReply: Bool) -> String? {
        guard let separated = QuoteStripper.separatingQuotedText(plainText: bodyRecord.plainText, html: bodyRecord.html, isReply: isReply) else {
            return nil
        }
        let newText = HTMLTextExtractor.plainText(fromHTML: separated.newText)
        return newText.isEmpty ? nil : newText
    }
}
