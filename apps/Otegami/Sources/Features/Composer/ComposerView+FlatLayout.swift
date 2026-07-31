import SwiftUI

extension ComposerView {
    // MARK: - iOS flat layout
    //
    // 2026-07-29デザイン指示 (Spark ダークモード参考): `Form`/`Section`の
    // カード的なグループ化をやめ、背景に直接フィールドが並ぶミニマムな
    // フラットデザインへ。区切りは`.otegamiRowDivider()`（罫線1本）か余白の
    // みで、見出しラベルは基本置かない — 差出人/宛先/Cc/Bccだけは「ラベル:
    // フィールド」という最小限のインライン表記 (宛先/Cc/Bccは Task #200
    // で`RecipientInputField`の`.flat`スタイルへ置き換え済み) を使う。
    // 件名/本文はプレースホルダのみで、ラベル自体を出さない。
    //
    // このセクション全体を1つの`ScrollView`にまとめて`body`に直接書くと
    // （`Form`のときと同じ理由で）CI の型チェックタイムアウトを再発させる
    // 恐れがあるため、`flatContent`は各行を個別の computed property/型に
    // 割った上で並べるだけの薄いラッパーにしている。

    #if os(iOS)
    var flatContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OtegamiSpacing.lg) {
                flatFromRow
                flatRecipientsSection
                flatSubjectRow
                flatBodySection
                flatSignatureRow
                // Task #125 「添付UIの位置」: 添付ボタン/添付済み一覧は本文＋
                // 署名の下 — 署名選択で本文末尾が変わっても、添付欄の位置が
                // それに引きずられて動かないようにする。Task #161: 添付を
                // "追加する"アクション自体 (`attachmentsMenu`) は下部バーに
                // 移した — ここに残るのは追加済みファイルの一覧のみ。
                flatAttachmentsSection
                if let errorMessage {
                    Text(errorMessage)
                        .font(OtegamiFont.subheadline())
                        .foregroundStyle(OtegamiColor.destructive)
                        .accessibilityIdentifier("composer.errorMessage")
                }
            }
            .padding(.horizontal, OtegamiSpacing.lg)
            .padding(.vertical, OtegamiSpacing.md)
        }
        .background(OtegamiColor.background)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { flatBottomActionBar }
    }

    /// Task #161 (下部バーのSpark準拠再構成): pinned above the keyboard
    /// (`.safeAreaInset(edge: .bottom)` on `flatContent`'s `ScrollView`, not
    /// scrolling away with the rest of the form) — the formatting bar
    /// itself (only while `isFormattingBarVisible`) stacked directly above
    /// a persistent action row: 左に「T」(書式バーの開閉), その右にこれまで
    /// 本文の下に置いていた添付/テンプレートの各アクション。Spark の作成画面の
    /// 下部バー構成 (左にT、中央に添付/テンプレート群) に合わせた、既存の
    /// flat デザイン (da4d3a9/8f29a4b) と同じトーンの`surface`背景+罫線。
    ///
    /// A `VStack` of two already-small pieces (a conditional
    /// `RichTextFormattingBar` call, and a flat `HStack` of a handful of
    /// buttons) — kept this shallow deliberately, same
    /// type-check-timeout-avoidance reasoning as everywhere else in this
    /// file's "MARK: -" doc comments.
    private var flatBottomActionBar: some View {
        VStack(spacing: 0) {
            if isFormattingBarVisible {
                RichTextFormattingBar(controller: richTextEditingController, hasSelection: bodySelectedRange.length > 0)
                    .otegamiRowDivider()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: OtegamiSpacing.sm) {
                    FormatBarToggleButton(isActive: isFormattingBarVisible) {
                        isFormattingBarVisible.toggle()
                    }
                    Divider().frame(height: 20)
                    attachmentsMenu
                    flatTemplateSection
                }
                .padding(.horizontal, OtegamiSpacing.lg)
                .padding(.vertical, OtegamiSpacing.xs)
            }
        }
        .background(OtegamiColor.surface)
    }

    /// 「差出人 (From アカウント) 行は現行機能を維持しつつ同トーンの控えめな
    /// 行に」— `macOS`側の`fromSection`と同じ`Picker`/`selectedAccountId`
    /// バインディングをそのまま使い、ラベルだけ他の行 (宛先/Cc/Bcc) と揃えた
    /// 見た目にする。`.labelsHidden()`で`Picker`自身の既定ラベルを隠し、
    /// 手前の`Text("差出人:")`だけを見せているのは、他の行がすべて
    /// 「ラベル: 値」という共通の形なのに揃えるため。
    private var flatFromRow: some View {
        HStack(spacing: OtegamiSpacing.sm) {
            Text("差出人:")
                .font(OtegamiFont.subheadline())
                .foregroundStyle(OtegamiColor.inkSecondary)
            // 実機フィードバック (2026-07-29「アカウント選択が崩れてる」):
            // `.pickerStyle(.menu)`は選択中の行`Text`をそのままラベルに使う
            // ため、「表示名 <アドレス>」が長いと行内で3行に折り返れて崩れる。
            // `Menu`+`Picker`の入れ子 (選択チェックマークは`Picker`が維持) に
            // し、閉じた状態のラベルだけ1行・中間省略で描く。
            Menu {
                Picker("差出人", selection: $selectedAccountId) {
                    ForEach(environment.accounts) { account in
                        Text("\(account.displayName) <\(account.email)>")
                            .tag(Optional(account.id))
                    }
                }
            } label: {
                // Task #170 (実機報告「英語設定なのに日本語が出ている」):
                // was `Text(verbatim: flatFromLabel)` — `flatFromLabel`
                // mixes dynamic account data (never localize: display
                // name/email, e.g. "a@example.com <a@example.com>") with a
                // fixed fallback string ("アカウントを選択") for when no
                // account is selected yet, so plain `Text(flatFromLabel)`
                // (the `Text(String)` verbatim overload,
                // docs/localization.md's "`Text(String)`は自動でローカラ
                // イズされない" section) was correct for the dynamic case
                // but silently skipped the catalog for the fallback.
                // `LocalizedStringKey(_:)` is docs/localization.md's
                // documented fix for exactly this shape (§3, same
                // technique `AccountFilterChip` already uses): dynamic
                // values that don't match any catalog key just render as
                // themselves (safe), while the fallback now picks up its
                // `en` translation.
                Text(LocalizedStringKey(flatFromLabel))
                    .font(OtegamiFont.body())
                    .foregroundStyle(OtegamiColor.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityIdentifier("composer.fromPicker")
            Spacer(minLength: 0)
        }
        // 実機フィードバック (2026-07-29「文字の一番下のラインが切れてる」):
        // `otegamiRowDivider()`は行コンテンツの下端に重ねる overlay で、
        // この行は`Menu`ラベルの`Text`高がコンテンツ高そのもの — 罫線が
        // ちょうど descender (g 等の下部) に被る。`TextField`の行 (宛先など)
        // は field 自身の内側余白で自然に逃げているので、この行だけ罫線の
        // 内側に最小トークン分の余白を足して揃える。
        .padding(.bottom, OtegamiSpacing.xs)
        .otegamiRowDivider()
        .padding(.bottom, OtegamiSpacing.sm)
    }

    /// `flatFromRow`の閉じた状態のラベル文字列。表示名とアドレスが同じ
    /// (表示名未設定でアドレスがそのまま入っている) アカウントでは
    /// 「a@example.com <a@example.com>」と冗長になるのでアドレス1本にする。
    private var flatFromLabel: String {
        guard let account = environment.accounts.first(where: { $0.id == selectedAccountId }) else {
            return "アカウントを選択"
        }
        if account.displayName.isEmpty || account.displayName == account.email {
            return account.email
        }
        return "\(account.displayName) <\(account.email)>"
    }

    /// 宛先行 (常に表示) + 「Cc: Bcc:」ピルボタン (`isShowingCcBcc`が`false`の
    /// 間だけ、宛先行の右端に表示) + Cc/Bcc行 (`isShowingCcBcc`が`true`に
    /// なったら表示、ピルは消える) — 詳細は`isCcBccExpandedByUser`/
    /// `isShowingCcBcc`の doc comment 参照。
    private var flatRecipientsSection: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.sm) {
            RecipientInputField(
                style: .flat("宛先:"), text: $toText,
                accessibilityIdentifier: "composer.to", occurrences: recipientOccurrences,
                trailing: {
                    if !isShowingCcBcc {
                        ComposerCcBccPillButton { isCcBccExpandedByUser = true }
                    }
                }
            )
            if isShowingCcBcc {
                RecipientInputField(
                    style: .flat("Cc:"), text: $ccText,
                    accessibilityIdentifier: "composer.cc", occurrences: recipientOccurrences
                )
                RecipientInputField(
                    style: .flat("Bcc:"), text: $bccText,
                    accessibilityIdentifier: "composer.bcc", occurrences: recipientOccurrences
                )
            }
        }
        .otegamiRowDivider()
        .padding(.bottom, OtegamiSpacing.sm)
    }

    /// 「プレースホルダのみのプレーン入力」— ラベルなし、`Form`の見出しも
    /// なし。件名の値そのものにはプレースホルダと違う色を使いたいわけでは
    /// ないので、`TextField`本体の既定のプレースホルダ描画に任せている。
    private var flatSubjectRow: some View {
        TextField("件名", text: $subject)
            .font(OtegamiFont.body())
            .accessibilityIdentifier("composer.subject")
            .otegamiRowDivider()
            .padding(.bottom, OtegamiSpacing.sm)
    }

    /// 本文: `RichTextEditor`自体はプレースホルダを知らない
    /// (`RichTextEditor`のdoc comment参照) ので、空のときだけ`ZStack`で
    /// プレースホルダの`Text`を重ねている — `UITextView`の既定の
    /// `textContainerInset`(top/bottom 8pt)/`lineFragmentPadding`(5pt)に
    /// おおよそ合わせた`padding`で、入力済みテキストの先頭とほぼ同じ位置に
    /// 見えるようにしている（厳密なピクセル一致は狙っていない — 1文字でも
    /// 入力されればプレースホルダ自体が消えるので実害は小さい）。
    private var flatBodySection: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.sm) {
            ZStack(alignment: .topLeading) {
                if attributedBodyText.string.isEmpty {
                    Text("本文を入力してください")
                        .font(OtegamiFont.body())
                        .foregroundStyle(OtegamiColor.inkTertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                RichTextEditor(
                    attributedText: $attributedBodyText,
                    selectedRange: $bodySelectedRange,
                    controller: richTextEditingController,
                    accessibilityIdentifier: "composer.body"
                )
            }
            .frame(minHeight: 240)
        }
    }

    @ViewBuilder
    private var flatTemplateSection: some View {
        if !availableTemplates.isEmpty {
            Menu {
                ForEach(availableTemplates) { template in
                    Button(template.name) { applyTemplate(template) }
                }
            } label: {
                Label("テンプレートを挿入", systemImage: "doc.on.doc")
                    .font(OtegamiFont.subheadline())
                    .foregroundStyle(OtegamiColor.accentText)
            }
            .accessibilityIdentifier("composer.insertTemplateMenu")
        }
    }

    /// 「署名: 本文下に「署名: なし」/「署名: <名前>」というグレーテキスト行 —
    /// タップで既存の署名選択。署名選択済みなら署名内容をその下にプレビュー
    /// 表示 (`signatureBodyPreview`)。」実機フィードバック「いきなり『なし』
    /// だけだと分かりにくい」を受けて、ラベルは常に「署名: 」を前置きする
    /// (`selectedSignatureLabel`)。
    ///
    /// 実機フィードバック続報 (2026-07-29「まだ『署名』という項目名がない」):
    /// 当初の `Picker(selection:label:)` + `.pickerStyle(.menu)` は、iOS では
    /// カスタムラベルを無視して**選択中の選択肢の`Text`(「なし」) をそのまま
    /// 表示する** — `flatFromRow`の差出人行が踏んだのと同じ落とし穴。同じ
    /// 修正 (`Menu`+`Picker`入れ子 — 選択チェックマークは内側の`Picker`が
    /// 維持し、閉じた状態の見た目は`Menu`の`label:`が完全に支配する) を
    /// 適用した。選択そのもの (`selectedSignatureId`、
    /// `selectedSignatureIdBinding`経由) はmacOS側の`signatureSection`と
    /// 完全に同じ状態を共有している。
    @ViewBuilder
    private var flatSignatureRow: some View {
        if !availableSignatures.isEmpty {
            VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
                Menu {
                    Picker(selection: selectedSignatureIdBinding) {
                        Text("なし").tag(Int64?.none)
                        ForEach(availableSignatures) { signature in
                            Text(signature.name).tag(Optional(signature.id))
                        }
                    } label: { EmptyView() }
                } label: {
                    Text(selectedSignatureLabel)
                        .font(OtegamiFont.subheadline())
                        .foregroundStyle(OtegamiColor.inkTertiary)
                }
                .accessibilityIdentifier("composer.signaturePicker")
                signatureBodyPreview
            }
        }
    }

    /// 添付済みファイル一覧: 装飾を他の行と同トーンに（`Section`の見出しなし）。
    /// macOS側の`attachmentsSection`が`List`の`.onDelete`（スワイプ削除）に
    /// 頼っているのに対し、`ScrollView`+`VStack`の中では`.onDelete`が機能
    /// しないため、各行に明示的な削除ボタン (`AttachmentRow(onRemove:)`) を
    /// 渡している。Task #161: 添付を追加するアクション自体
    /// (`attachmentsMenu`) は下部バー (`flatBottomActionBar`) に移した —
    /// ここは追加済みファイルが1件もなければ何も描画しない。
    @ViewBuilder
    private var flatAttachmentsSection: some View {
        if !pendingAttachments.isEmpty {
            VStack(alignment: .leading, spacing: OtegamiSpacing.sm) {
                ForEach(pendingAttachments) { attachment in
                    AttachmentRow(attachment: attachment) {
                        pendingAttachments.removeAll { $0.id == attachment.id }
                    }
                }
            }
        }
    }
    #endif
}

/// 2026-07-29デザイン指示: 宛先行の右端に出す「Cc: Bcc:」丸角アウトライン
/// ピルボタン。`OtegamiRadius`は原則フラット（角丸0）だが、`SearchTopBar`
/// が検索画面のトップバーで既に確立した「カプセル/円は個別ビュー内だけの
/// 閉じたスコープの例外として`Capsule()`/`Circle()`を直接使う」という前例
/// (`OtegamiBorder.swift`のdoc comment参照) に倣い、ここでも新しい
/// `OtegamiRadius`トークンを追加せず`Capsule()`をこのビュー内だけで使う。
#if os(iOS)
/// Task #161 (下部バーのSpark準拠再構成): the "T" button that toggles
/// `RichTextFormattingBar`'s visibility in `flatBottomActionBar` — same
/// small-leaf-view shape as `RichTextFormattingBar`'s own `FormatBarButton`
/// (not reused directly since that one is `private` to that file and this
/// button's highlighted-when-open state is `ComposerView`'s own concern,
/// not the formatting bar's).
private struct FormatBarToggleButton: View {
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: "T")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 32)
                .foregroundStyle(isActive ? OtegamiColor.accentText : OtegamiColor.inkSecondary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? OtegamiColor.paleBaseStrong : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("composer.formatBarToggle")
    }
}
#endif

private struct ComposerCcBccPillButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: "Cc: Bcc:")
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkSecondary)
                .padding(.horizontal, OtegamiSpacing.md)
                .padding(.vertical, OtegamiSpacing.xs)
                .overlay(
                    Capsule().strokeBorder(OtegamiColor.dividerSubtle, lineWidth: OtegamiStroke.secondary)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("composer.showCcBccButton")
    }
}
