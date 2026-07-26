#if os(iOS)
import SwiftUI
import UIKit

/// 表示・操作改善バッチ「添付ボタンの統合」の「写真を撮る」— wraps
/// `UIImagePickerController` with `sourceType == .camera` for
/// `.sheet(isPresented:)` presentation. SwiftUI has no native camera-capture
/// control (`PhotosPicker` only reaches the photo library, never the
/// camera), so this is the standard `UIViewControllerRepresentable`
/// workaround. Real-device only: `ComposerView.attachmentsMenu` gates the
/// menu entry that presents this on `UIImagePickerController
/// .isSourceTypeAvailable(.camera)`, which is always `false` in the
/// Simulator (no camera hardware to report) — this type itself doesn't
/// re-check that, since a caller that ignores the availability gate and
/// presents this anyway on the Simulator would just get an empty/black
/// capture screen from `UIImagePickerController` itself, not a crash.
struct CameraPicker: UIViewControllerRepresentable {
    /// Called with the captured photo's JPEG bytes once the user taps
    /// "写真を使用" — `nil` if they cancelled instead. Either way the caller
    /// is expected to dismiss the sheet from this callback (this type
    /// doesn't dismiss itself, matching `PhotosPicker`'s own "caller owns
    /// presentation" convention already used elsewhere in `ComposerView`).
    var onCapture: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (Data?) -> Void

        init(onCapture: @escaping (Data?) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.editedImage] as? UIImage ?? info[.originalImage] as? UIImage
            onCapture(image?.jpegData(compressionQuality: 0.9))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }
    }
}
#endif
