import SwiftUI
import VisionKit

/// Apple's document camera — the same scanner UI as the Notes app:
/// automatic edge detection, perspective correction, multi-page
/// capture, and color / grayscale / black-and-white filters, with
/// flash control. The delegate hands the captured page images back
/// to the library, which assembles them into a single PDF
/// (LibraryStore.importScan) exactly like an imported file.
struct DocumentScanner: UIViewControllerRepresentable {
    var onScan: ([UIImage]) -> Void
    var onCancel: () -> Void
    var onError: (Error) -> Void

    @Environment(\.dismiss) private var dismiss

    /// True on hardware that can run the document camera. It needs a
    /// real camera, so this is false in the Simulator and on any
    /// device where the system disables it.
    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let parent: DocumentScanner

        init(_ parent: DocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.onScan(images)
            parent.dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
            parent.dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            parent.onError(error)
            parent.dismiss()
        }
    }
}
