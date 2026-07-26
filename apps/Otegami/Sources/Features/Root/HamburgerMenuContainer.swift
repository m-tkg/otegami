import SwiftUI

/// 新画面構成 (1): iOS のハンバーガーメニュー — 下部タブバー廃止に伴う置き換え。
/// leading-edge のサイドドロワーとして実装 (シートではなく): ハンドオフの
/// 「開くと現在のフォルダシートの内容」相当を、モーダルシートではなく常設の
/// ドロワーとして重ねる形にした。理由:
///
/// - `FolderListSheet` の中身 (統合受信トレイ/アカウント別ツリー/下書き等の
///   行) が「別のシートを開く」導線を持っているため、この一枚自体がシートの
///   ままだと「シートからシートを開く」というこのアプリで既知の壊れ方
///   (`FolderListSheet.swift` の旧ドキュメントコメント参照) を踏む。ドロワー
///   ならメニュー自身はシートではないので、行タップで直接
///   `showingOutbox = true` 等を立てるだけでよく、`MailTabView` 側の
///   `onDismiss` 経由の間接呼び出し (旧 `pendingPostFolderAction`) が丸ごと
///   不要になった。
/// - iOS の作法として、Gmail/多くのメールアプリのハンバーガーメニューは
///   ボトムシートではなく左からのドロワーが通例。
///
/// スワイプでの開閉は「ドロワーを閉じる」方向のみ実装 (ドラッグで追従し、
/// 一定距離を超えたら閉じる)。エッジスワイプでの「開く」ジェスチャーは
/// 実装していない — このアプリの `NavigationStack` の戻るジェスチャー
/// (画面端からのスワイプ) と競合するリスクがあり
/// (`.claude/skills/verify/SKILL.md` に蓄積されているジェスチャー競合の
/// 前例: `.onLongPressGesture` が `.swipeActions` を止めた話など)、
/// ハンバーガーボタン自体が確実な開閉手段として常にあるため、閉じる方向
/// だけを「あると嬉しいおまけ」として実装するに留めた。
struct HamburgerMenuContainer<Menu: View, Content: View>: View {
    @Binding var isOpen: Bool
    @ViewBuilder var menu: () -> Menu
    @ViewBuilder var content: () -> Content

    private let drawerWidth: CGFloat = 320

    @GestureState private var dragTranslation: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            content()
                .accessibilityHidden(isOpen)
                .allowsHitTesting(!isOpen)

            if isOpen {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .accessibilityIdentifier("hamburgerMenu.scrim")
                    .onTapGesture { close() }
                    .transition(.opacity)
            }

            menu()
                .frame(width: drawerWidth)
                .frame(maxHeight: .infinity)
                .background(OtegamiColor.surface)
                .offset(x: currentOffset)
                .gesture(closeDragGesture)
                .accessibilityIdentifier("hamburgerMenu.drawer")
                .accessibilityHidden(!isOpen)
        }
        .animation(.easeInOut(duration: 0.25), value: isOpen)
    }

    private var currentOffset: CGFloat {
        (isOpen ? 0 : -(drawerWidth + 40)) + dragTranslation
    }

    private var closeDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragTranslation) { value, state, _ in
                // Only ever follows a leftward (closing) drag — a rightward
                // drag on the already-fully-open drawer has nothing further
                // to reveal.
                state = min(0, value.translation.width)
            }
            .onEnded { value in
                if value.translation.width < -drawerWidth * 0.3 {
                    close()
                }
            }
    }

    private func close() {
        isOpen = false
    }
}
