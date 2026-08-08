import CoreGraphics
import Foundation
import ImageIO
import PushRelayClient
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Communication Notification 対応: `AvatarImageResolving`のデコレータ。
/// `base`(`CompositeAvatarImageResolver`)へ解決をそのまま委譲しつつ、
/// **非`nil`が返ったときだけ**その画像を`SharedAvatarStore`(App Group
/// 共有ディレクトリ、`packages/OtegamiKit/Sources/PushRelayClient/
/// SharedAvatarStore.swift`のドキュメントコメント参照)へミラーする —
/// Notification Service Extension は別プロセス・別コンテナで、`Contacts`/
/// `URLSession`を叩き直す時間もその権限も無いため、アプリ本体が既に解決
/// 済みの画像を「書いておくだけ」で共有する側に回る。
///
/// **`base`の戻り値は常にそのまま返す** — ミラー書き込みの成否
/// (ディスク容量不足・App Group 未設定等)を`SenderAvatar`の描画に一切
/// 影響させない。`SharedAvatarStore.write(_:for:)`自体が
/// `@discardableResult`でベストエフォート実装なのと同じ設計思想。
///
/// **既存エントリがあれば書き直さない** — `SenderAvatar`は一覧のスクロール
/// のたびに`.task(id:)`で解決要求を出す (`SenderAvatar.swift`のドキュメント
/// コメント参照) ので、毎回同じ画像を PNG に再エンコードしてディスクへ
/// 書き直すのは無駄な CPU/IO でしかない。`SharedAvatarStore.imageURL(for:)`
/// が TTL (30日, `SharedAvatarStore.defaultTimeToLive`) 内の非`nil`を
/// 返す間は据え置き、期限切れ後の次回解決で自然に上書きされる。
///
/// **画像の正規化 (128×128 aspect-fill センタークロップ→不透明 PNG)**:
/// `INImage(url:)`に渡すファイルは`Communication Notification`のアバター
/// として円形にクロップ表示される。情報源 (Google プロフィール写真/
/// Gravatar/BIMI・favicon)ごとに元画像のサイズ・アスペクト比・透明度が
/// バラバラなままファイルへ書くと、NSE 側でクロップ結果が情報源によって
/// 微妙に変わってしまう — ここで一度共通の正方形へ正規化しておけば NSE 側
/// は「128×128 の不透明 PNG をそのまま渡す」以上のことを考えずに済む。
/// 背景色 (`OtegamiColor.avatarImageBackdrop`, `SenderAvatar`の同トークン
/// と同値)で先に塗ってから描画するのは、透明度を持つ元画像 (favicon 等)
/// をそのまま PNG 化すると`INImage`のレンダリング結果が情報源によって
/// 透明部分の見え方が変わりうるため — 不透明化して一貫させる。
actor MirroringAvatarImageResolver: AvatarImageResolving {
    /// `SharedAvatarStore`に書き出す正方形の一辺のピクセル数。
    /// `CompanyLogoAvatarResolver.bimiRenderedPixelSize`(160)より一段
    /// 小さいのは、Communication Notification のアバターは lock screen
    /// 上で小さく表示されるだけで、この用途に 160 まで持つ意味が無いため。
    static let outputPixelSize = 128

    private let base: any AvatarImageResolving
    private let store: SharedAvatarStore?

    /// - Parameters:
    ///   - base: 実際の解決を担う既存の合成リゾルバ (`CompositeAvatarImageResolver`)。
    ///   - store: `nil`なら App Group が使えない環境 (macOS 常時、または
    ///     iOS でも App Group エンタイトルメントが効いていないビルド) —
    ///     その場合`resolveAvatarImageData`は`base`への単純な委譲になり、
    ///     ミラー書き込みは一切発生しない (`SharedAvatarStore.init?
    ///     (appGroupIdentifier:)`のドキュメントコメント参照)。
    init(wrapping base: any AvatarImageResolving, store: SharedAvatarStore?) {
        self.base = base
        self.store = store
    }

    func resolveAvatarImageData(displayName: String?, address: String) async -> Data? {
        let resolved = await base.resolveAvatarImageData(displayName: displayName, address: address)
        guard let resolved, let store else { return resolved }

        // 既存エントリが TTL 内ならスキップ (型のドキュメントコメント参照)。
        guard store.imageURL(for: address) == nil else { return resolved }

        // 正規化に失敗した (デコードできない画像等) 場合もミラーせず、
        // `base`の戻り値だけをそのまま返す — このデコレータ自身の都合で
        // 呼び出し元への結果を変えてはいけない。
        guard let normalized = Self.normalizedPNGData(resolved) else { return resolved }
        store.write(normalized, for: address)
        return resolved
    }

    // MARK: - Normalization

    /// `data`をデコードし、128×128 の aspect-fill センタークロップ→不透明
    /// PNG へ変換する。デコードできない/`CGImage`が取れない場合は`nil`。
    static func normalizedPNGData(_ data: Data) -> Data? {
        guard let sourceImage = decodeCGImage(data) else { return nil }
        return renderNormalized(sourceImage)
    }

    /// `BIMISVGRenderer.render(_:pixelSize:)`と同じ「固定サイズの
    /// `CGContext`へ描いて`CGImageDestination`で PNG 化する」形。あちらが
    /// letterbox (収める) なのに対し、こちらは**aspect-fill** (短辺を
    /// キャンバスに合わせ、はみ出した長辺側を左右/上下均等に切り落とす) —
    /// 顔写真中心の情報源 (Google プロフィール写真等)は余白を作るより
    /// 中央を大きく見せる方が円形クロップ後の見栄えが良いため。
    private static func renderNormalized(_ sourceImage: CGImage) -> Data? {
        let size = outputPixelSize
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(avatarBackdropCGColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        let sourceWidth = Double(sourceImage.width)
        let sourceHeight = Double(sourceImage.height)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        // aspect-fill: 短辺をキャンバスちょうどに合わせるスケール
        // (`min`ではなく`max`を使うのが`BIMISVGRenderer`のletterboxとの
        // 唯一の違い)。`CGContext`はビットマップの外側を自動的にクリップ
        // するので、はみ出した分を切り落とすための明示的な`clip`は不要。
        let scale = max(Double(size) / sourceWidth, Double(size) / sourceHeight)
        let drawWidth = sourceWidth * scale
        let drawHeight = sourceHeight * scale
        let originX = (Double(size) - drawWidth) / 2
        let originY = (Double(size) - drawHeight) / 2
        context.draw(sourceImage, in: CGRect(x: originX, y: originY, width: drawWidth, height: drawHeight))

        guard let outputImage = context.makeImage() else { return nil }
        return pngData(from: outputImage)
    }

    /// `data`から`CGImage`を取り出す唯一の箇所 — `SenderAvatar
    /// .platformImage`と同じ理由で型全体を`#if`で囲まず、この関数だけ
    /// プラットフォーム分岐する。
    private static func decodeCGImage(_ data: Data) -> CGImage? {
        #if canImport(UIKit)
        return UIImage(data: data)?.cgImage
        #elseif canImport(AppKit)
        guard let nsImage = NSImage(data: data) else { return nil }
        var proposedRect = CGRect(origin: .zero, size: nsImage.size)
        return nsImage.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        #else
        return nil
        #endif
    }

    /// `OtegamiColor.avatarImageBackdrop`(`SenderAvatar`が円の塗りに使う
    /// のと同じトークン)を`CGColor`へ変換する。新しい色をその場で追加
    /// せず、既存トークンをそのまま経由するのがこのリポジトリの規約
    /// (`CLAUDE.md`「UI デザイン方針」)。
    ///
    /// このトークンは light/dark 両対応の動的な`Color`
    /// (`DynamicColor.swift`)なので、ファイルへ焼き込む1枚の PNG に対して
    /// どちらか一方を選ぶ必要がある — dark 側を選んだ: Communication
    /// Notification は lock screen (既定で dark な場面が多い)に出ることが
    /// 多く、`SenderAvatar`自身がライブ描画では都度正しい方に自動追随する
    /// のに対しこの1枚だけは固定になる、という非対称は許容している
    /// (透明部分が無い画像ならこの背景色はそもそも見えない — 実際に見える
    /// のは favicon 等ごく一部の情報源だけ)。
    #if canImport(UIKit)
    private static var avatarBackdropCGColor: CGColor {
        UIColor(OtegamiColor.avatarImageBackdrop)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            .cgColor
    }
    #elseif canImport(AppKit)
    private static var avatarBackdropCGColor: CGColor {
        // `NSColor(Color)`は`DynamicColor.swift`の`dynamicProvider`を
        // 積んだ`NSColor`を返す — 何もしないまま`.cgColor`を読むと解決に
        // 使われる appearance が不定になるため、
        // `performAsCurrentDrawingAppearance`で明示的に dark aqua を
        // current にしてから解決する (iOS 側の`resolvedColor(with:)`と
        // 同じ「どちらを選ぶかを明示する」目的)。`NSApp`(`@MainActor`)には
        // 触れない — この`actor`から呼べる必要があるため、`NSAppearance
        // (named: .darkAqua)`(システム標準の appearance で、常に非`nil`)
        // だけで解決する。macOS では`OtegamiAppGroup.identifier`が常に
        // `nil`で`store`も`nil`になりこの関数は実行時には呼ばれない
        // (`make mac`の型チェックのためだけに存在する)が、値そのものは
        // 正しく求まるようにしておく。
        // 初期値もトークン経由 — `NSAppearance(named: .darkAqua)`が`nil`に
        // なることは実際には無いが、その場合でも「その時点で current な
        // appearance で解決した同じトークンの値」に落ちるようにしておく
        // (ここで具体的な色をリテラルで書くと、トークンが変わったときに
        // 追随しない2つ目の定義になってしまう)。
        var resolved = NSColor(OtegamiColor.avatarImageBackdrop).cgColor
        if let appearance = NSAppearance(named: .darkAqua) {
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor(OtegamiColor.avatarImageBackdrop).cgColor
            }
        }
        return resolved
    }
    #endif

    /// `BIMISVGRenderer.pngData(from:)`と同一実装 — 2箇所目で共通化する
    /// ほどの複雑さではない (10行程度)ので、`BIMI`に依存する
    /// `BIMISVGRenderer`側を`import`して使い回すよりこの型が自己完結する
    /// 方を選んだ。
    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        let type: CFString
        #if canImport(UniformTypeIdentifiers)
        type = UTType.png.identifier as CFString
        #else
        type = "public.png" as CFString
        #endif
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
