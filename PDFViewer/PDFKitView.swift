import SwiftUI
import PDFKit

/// Reading background choices from Settings. Applied to the PDFView's
/// backdrop; the page itself keeps its true colors.
enum ReadingBackground: String, CaseIterable, Identifiable {
    case white
    case sepia
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .white: return "White"
        case .sepia: return "Sepia"
        case .dark: return "Night"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .white: return .systemGroupedBackground
        case .sepia: return UIColor(red: 0.93, green: 0.87, blue: 0.73, alpha: 1)
        case .dark: return UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1)
        }
    }
}

/// SwiftUI wrapper around PDFKit's PDFView — the real, native PDF
/// renderer (no web view anywhere near the documents).
///
/// The Coordinator registers the live PDFView with the ReaderController
/// and forwards page-change notifications, so every other part of the
/// reader (toolbar, search, editor tools, ad page guard) works against
/// the same view.
struct PDFKitView: UIViewRepresentable {
    @ObservedObject var controller: ReaderController
    var readingBackground: ReadingBackground
    /// True for single-page mode, false for continuous scrolling.
    var singlePageMode: Bool

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayDirection = .vertical
        pdfView.pageBreakMargins = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        pdfView.pageShadowsEnabled = true
        pdfView.document = controller.document
        context.coordinator.attach(pdfView)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        if pdfView.document !== controller.document {
            pdfView.document = controller.document
        }
        pdfView.backgroundColor = readingBackground.uiColor
        let desiredMode: PDFDisplayMode = singlePageMode ? .singlePage : .singlePageContinuous
        if pdfView.displayMode != desiredMode {
            pdfView.displayMode = desiredMode
        }
    }

    final class Coordinator: NSObject {
        private let controller: ReaderController
        private weak var pdfView: PDFView?

        init(controller: ReaderController) {
            self.controller = controller
        }

        func attach(_ pdfView: PDFView) {
            self.pdfView = pdfView
            controller.pdfView = pdfView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged),
                name: .PDFViewPageChanged,
                object: pdfView
            )
            // Restore the reader's last page for this document.
            controller.restoreInitialPage()
        }

        @objc private func pageChanged() {
            guard let pdfView, let page = pdfView.currentPage else { return }
            let index = pdfView.document?.index(for: page) ?? 0
            controller.noteCurrentPage(index)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
