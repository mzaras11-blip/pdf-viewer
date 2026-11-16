import Foundation
import PDFKit
import UIKit

/// The editing tools the reader toolbar can arm. `.none` is plain
/// reading. Placement tools (text/note/erase) work by tapping the
/// page; draw and sign open their own flows.
enum ReaderTool: Equatable {
    case none
    case highlight
    case underline
    case draw
    case text
    case note
    case sign
    case erase
    case redact
    case coverText
}

/// One row of the outline sidebar.
struct OutlineItem: Identifiable {
    let id = UUID()
    let label: String
    let pageIndex: Int
    let depth: Int
}

/// One full-text search hit.
struct SearchResult: Identifiable {
    let id = UUID()
    let pageIndex: Int
    let snippet: String
    let selection: PDFSelection
}

/// The hub of the reader screen. Owns the open document, tracks the
/// current page, and performs every edit operation (annotations, ink,
/// signature burn-in, page surgery) against PDFKit. Views talk to the
/// controller; the controller talks to the live PDFView (registered by
/// PDFKitView's coordinator) and to the LibraryStore for persistence.
///
/// Saving model: annotation-level edits mark the document dirty and
/// are written when the tool closes, when the reader is left, or when
/// the reader taps Save. Structural edits (page ops, signature) are
/// written immediately. Either way, edits land in the app's imported
/// copy — the user's original file is never touched — and Share
/// exports a copy.
final class ReaderController: ObservableObject {
    let entry: RecentDocument
    private let library: LibraryStore

    @Published var document: PDFDocument
    @Published private(set) var currentPageIndex: Int = 0
    @Published private(set) var isDirty = false
    @Published var lastError: String?

    /// The live PDFView, registered by PDFKitView.
    weak var pdfView: PDFView?

    private var didRestoreInitialPage = false

    init(entry: RecentDocument, library: LibraryStore) {
        self.entry = entry
        self.library = library
        self.document = library.openDocument(entry) ?? PDFDocument()
        self.currentPageIndex = entry.lastPage
    }

    var pageCount: Int { document.pageCount }

    var currentPage: PDFPage? {
        document.page(at: currentPageIndex)
    }

    // MARK: - Navigation

    /// Called once the PDFView exists: jump to the page the reader
    /// left this document on.
    func restoreInitialPage() {
        guard !didRestoreInitialPage else { return }
        didRestoreInitialPage = true
        goToPage(entry.lastPage)
    }

    /// PDFView reports the visible page here.
    func noteCurrentPage(_ index: Int) {
        guard index != currentPageIndex else { return }
        currentPageIndex = index
        library.touch(entry, page: index)
        AdManager.shared.notePageChanged()
    }

    func goToPage(_ index: Int) {
        guard let pdfView, pageCount > 0 else { return }
        let clamped = min(max(index, 0), pageCount - 1)
        if let page = document.page(at: clamped) {
            pdfView.go(to: page)
            currentPageIndex = clamped
        }
    }

    func goToSelection(_ selection: PDFSelection) {
        guard let pdfView else { return }
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.go(to: selection)
    }

    // MARK: - Selection markup (highlight / underline)

    /// Applies the given markup type to the current text selection.
    /// Returns false when there is no usable selection.
    @discardableResult
    func applyMarkup(type: PDFAnnotationSubtype, color: UIColor) -> Bool {
        guard let selection = pdfView?.currentSelection else { return false }
        let lines = selection.selectionsByLine()
        guard !lines.isEmpty else { return false }
        var applied = false
        for line in lines {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
                annotation.color = color
                page.addAnnotation(annotation)
                applied = true
            }
        }
        if applied { markDirty() }
        return applied
    }

    // MARK: - Text boxes & sticky notes

    /// Adds a text box at a page-space point (top-left anchored).
    func addTextBox(text: String, at pagePoint: CGPoint, on page: PDFPage,
                    fontSize: CGFloat = 14) {
        let size = CGSize(width: 220, height: max(28, fontSize * 1.6))
        let bounds = CGRect(x: pagePoint.x,
                            y: pagePoint.y - size.height,
                            width: size.width,
                            height: size.height)
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = UIFont.systemFont(ofSize: fontSize)
        annotation.fontColor = .black
        annotation.color = .clear
        annotation.userName = "PVText"
        page.addAnnotation(annotation)
        markDirty()
    }

    /// Adds a sticky note: a small pale-yellow box carrying the note
    /// text, marked so the app can tell it from a plain text box.
    func addNote(text: String, at pagePoint: CGPoint, on page: PDFPage) {
        let size = CGSize(width: 160, height: 64)
        let bounds = CGRect(x: pagePoint.x,
                            y: pagePoint.y - size.height,
                            width: size.width,
                            height: size.height)
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = UIFont.systemFont(ofSize: 11)
        annotation.fontColor = .black
        annotation.color = UIColor(red: 1.0, green: 0.92, blue: 0.55, alpha: 0.95)
        annotation.userName = "PVNote"
        page.addAnnotation(annotation)
        markDirty()
    }

    // MARK: - Eraser (own annotations)

    private static let removableTypes: Set<String> = [
        PDFAnnotationSubtype.highlight.rawValue,
        PDFAnnotationSubtype.underline.rawValue,
        PDFAnnotationSubtype.ink.rawValue,
        PDFAnnotationSubtype.freeText.rawValue,
        PDFAnnotationSubtype.text.rawValue,
        PDFAnnotationSubtype.square.rawValue,
        PDFAnnotationSubtype.circle.rawValue,
        PDFAnnotationSubtype.line.rawValue,
        PDFAnnotationSubtype.stamp.rawValue,
    ]

    /// Removes the topmost removable annotation at a page-space point.
    /// Form fields (widgets) are never erased. Returns true on a hit.
    @discardableResult
    func eraseAnnotation(at pagePoint: CGPoint, on page: PDFPage) -> Bool {
        guard let annotation = page.annotation(at: pagePoint),
              let type = annotation.type,
              Self.removableTypes.contains(type) else { return false }
        page.removeAnnotation(annotation)
        markDirty()
        return true
    }

    // MARK: - Freehand ink

    /// Commits one drawn stroke (points in PDFView view coordinates)
    /// to the given page as a vector ink annotation.
    func commitStroke(points viewPoints: [CGPoint], color: UIColor,
                      lineWidthView: CGFloat, on page: PDFPage) {
        guard let pdfView, viewPoints.count > 1 else { return }
        var pagePoints: [CGPoint] = []
        pagePoints.reserveCapacity(viewPoints.count)
        for point in viewPoints {
            pagePoints.append(pdfView.convert(point, to: page))
        }
        let path = UIBezierPath()
        path.move(to: pagePoints[0])
        for point in pagePoints.dropFirst() { path.addLine(to: point) }

        // Ink annotation paths live in a coordinate space offset by the
        // annotation's bounds origin; using the full media box (origin
        // 0,0 on standard pages) keeps path space == page space.
        let pageBounds = page.bounds(for: .mediaBox)
        let annotation = PDFAnnotation(bounds: pageBounds, forType: .ink, withProperties: nil)
        annotation.add(path)
        annotation.color = color
        let border = PDFBorder()
        border.lineWidth = max(0.5, lineWidthView / max(pdfView.scaleFactor, 0.01))
        annotation.border = border
        annotation.userName = "PVInk"
        page.addAnnotation(annotation)
        markDirty()
    }

    // MARK: - Signature burn-in

    /// Stamps a signature image onto the current page. The image is
    /// burned into the page's content (so it survives in every reader,
    /// not just this app) by re-rendering the page at vector quality
    /// and re-adding its existing annotations. Form-field widgets on
    /// that page are not carried over — fill forms after stamping, or
    /// stamp a different page (see BUILD-NOTES.md).
    func stampSignature(image: UIImage, viewRect: CGRect) {
        guard let pdfView, let page = pdfView.currentPage else { return }
        let pageRect = pdfView.convert(viewRect, to: page)
        guard pageRect.width > 4, pageRect.height > 4 else { return }

        let pageIndex = document.index(for: page)
        let bounds = page.bounds(for: .mediaBox)
        let rotation = page.rotation
        let savedAnnotations = page.annotations.filter {
            $0.type != PDFAnnotationSubtype.widget.rawValue
        }

        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            context.beginPage()
            let cg = context.cgContext
            // Flip into PDF page space (origin bottom-left).
            cg.translateBy(x: 0, y: bounds.height)
            cg.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: cg)
            // Draw the image upright inside the same flipped space.
            cg.saveGState()
            cg.translateBy(x: pageRect.origin.x, y: pageRect.origin.y + pageRect.height)
            cg.scaleBy(x: 1, y: -1)
            image.draw(in: CGRect(x: 0, y: 0, width: pageRect.width, height: pageRect.height))
            cg.restoreGState()
        }
        guard let replacement = PDFDocument(data: data),
              let newPage = replacement.page(at: 0) else { return }
        newPage.rotation = rotation
        for annotation in savedAnnotations {
            if let copy = Self.copyAnnotation(annotation) {
                newPage.addAnnotation(copy)
            }
        }
        document.removePage(at: pageIndex)
        document.insert(newPage, at: pageIndex)
        refreshAfterStructureChange(keepingPage: pageIndex)
        persistEdits()
    }

    /// Best-effort copy of an annotation (used by signature burn-in).
    private static func copyAnnotation(_ source: PDFAnnotation) -> PDFAnnotation? {
        guard let type = source.type else { return nil }
        let copy = PDFAnnotation(bounds: source.bounds,
                                 forType: PDFAnnotationSubtype(rawValue: type),
                                 withProperties: nil)
        copy.color = source.color
        copy.contents = source.contents
        copy.font = source.font
        copy.fontColor = source.fontColor
        copy.userName = source.userName
        if let border = source.border {
            let newBorder = PDFBorder()
            newBorder.lineWidth = border.lineWidth
            copy.border = newBorder
        }
        if type == PDFAnnotationSubtype.ink.rawValue, let paths = source.paths {
            for path in paths { copy.add(path) }
        }
        return copy
    }

    // MARK: - Password unlock

    /// Tries to unlock a password-protected document for reading.
    /// Unlocking is in-memory only — the library file keeps its
    /// password; saving an unlocked copy is a separate tools action.
    @discardableResult
    func unlock(password: String) -> Bool {
        guard document.isLocked else { return true }
        guard document.unlock(withPassword: password) else { return false }
        objectWillChange.send()
        pdfView?.document = document
        return true
    }

    // MARK: - Redaction (pending boxes, burned in on apply)

    /// Redaction boxes the reader has drawn but not yet applied,
    /// keyed by page index. They live only in memory — nothing is
    /// written to the file until applyRedactions burns them in.
    @Published private(set) var pendingRedactions: [Int: [CGRect]] = [:]

    var pendingRedactionCount: Int {
        pendingRedactions.values.reduce(0) { $0 + $1.count }
    }

    func redactions(on pageIndex: Int) -> [CGRect] {
        pendingRedactions[pageIndex] ?? []
    }

    func addRedactionBox(_ rect: CGRect, pageIndex: Int) {
        pendingRedactions[pageIndex, default: []].append(rect)
    }

    func clearRedactions() {
        pendingRedactions = [:]
    }

    /// Burns every pending box into its page (PDFTools.redactedPage:
    /// the page is rasterized at print quality with the boxes
    /// painted black, so the covered text is removed from the file,
    /// not just hidden). Writes the document immediately.
    @discardableResult
    func applyRedactions() -> Bool {
        guard !pendingRedactions.isEmpty else { return false }
        var applied = false
        for (index, boxes) in pendingRedactions {
            guard let page = document.page(at: index),
                  let newPage = PDFTools.redactedPage(from: page, boxes: boxes)
            else { continue }
            document.removePage(at: index)
            document.insert(newPage, at: index)
            applied = true
        }
        guard applied else { return false }
        pendingRedactions = [:]
        refreshAfterStructureChange(keepingPage: currentPageIndex)
        markDirty()
        persistEdits()
        return true
    }

    // MARK: - Cover & retype (whiteout)

    /// "Edits" text the practical way: paints a patch in the page's
    /// own background color over the dragged rectangle, then puts a
    /// text box with the replacement words on top. Both halves are
    /// ordinary annotations committed on save, and both can be
    /// removed with the eraser. This is a cover-up, NOT a redaction:
    /// the original words stay in the file underneath the patch —
    /// use Redact for anything sensitive.
    func coverAndRetype(text: String, rect: CGRect, on page: PDFPage) {
        let background = PDFTools.sampleBackgroundColor(page: page, rect: rect)
        let cover = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        cover.color = background
        cover.interiorColor = background
        let border = PDFBorder()
        border.lineWidth = 0
        cover.border = border
        cover.userName = "PVCover"
        page.addAnnotation(cover)

        let fontSize = min(max(rect.height * 0.7, 9), 40)
        let replacement = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
        replacement.contents = text
        replacement.font = UIFont.systemFont(ofSize: fontSize)
        replacement.fontColor = .black
        replacement.color = .clear
        replacement.userName = "PVText"
        page.addAnnotation(replacement)
        markDirty()
    }

    // MARK: - Page operations

    func deletePage(at index: Int) {
        guard pageCount > 1, index >= 0, index < pageCount else { return }
        document.removePage(at: index)
        refreshAfterStructureChange(keepingPage: min(currentPageIndex, pageCount - 1))
        library.updatePageCount(entry, pageCount: pageCount)
        persistEdits()
    }

    func rotatePage(at index: Int) {
        guard let page = document.page(at: index) else { return }
        page.rotation = (page.rotation + 90) % 360
        refreshAfterStructureChange(keepingPage: currentPageIndex)
        persistEdits()
    }

    func movePage(from source: Int, to destination: Int) {
        guard source != destination,
              source >= 0, source < pageCount,
              destination >= 0, destination < pageCount
        else { return }
        let pages = (0..<pageCount).compactMap { document.page(at: $0) }
        guard pages.count == pageCount else { return }
        var order = pages
        let moved = order.remove(at: source)
        order.insert(moved, at: destination)
        let rebuilt = PDFDocument()
        for page in order { rebuilt.insert(page, at: rebuilt.pageCount) }
        guard rebuilt.pageCount == pageCount else { return }
        document = rebuilt
        refreshAfterStructureChange(keepingPage: destination)
        persistEdits()
    }

    /// After a structural change the PDFView gets its document
    /// re-assigned and is sent back to a sensible page.
    private func refreshAfterStructureChange(keepingPage page: Int) {
        guard let pdfView else { return }
        pdfView.document = document
        goToPage(page)
    }

    // MARK: - Search & outline

    /// Full-text search. Runs off the main thread; results carry the
    /// PDFSelection so tapping one can jump + highlight.
    func search(for query: String) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let doc = document
        return await Task.detached(priority: .userInitiated) {
            let selections = doc.findString(trimmed, withOptions: [.caseInsensitive])
            return selections.map { selection in
                let page = selection.pages.first
                let pageIndex = page.map { doc.index(for: $0) } ?? 0
                let line = selection.selectionsByLine().first?.string
                let snippet = (line ?? selection.string ?? trimmed)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return SearchResult(pageIndex: pageIndex, snippet: snippet, selection: selection)
            }
        }.value
    }

    func outlineItems() -> [OutlineItem] {
        guard let root = document.outlineRoot else { return [] }
        var items: [OutlineItem] = []
        func walk(_ node: PDFOutline, depth: Int) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                let pageIndex = child.destination?.page.map { document.index(for: $0) } ?? 0
                items.append(OutlineItem(label: child.label ?? "Untitled",
                                         pageIndex: pageIndex,
                                         depth: depth))
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return items
    }

    var hasOutline: Bool { document.outlineRoot != nil && document.outlineRoot!.numberOfChildren > 0 }

    // MARK: - Saving & export

    func markDirty() {
        isDirty = true
    }

    /// Writes the working document back to the library copy.
    func persistEdits() {
        guard isDirty else { return }
        if document.write(to: library.fileURL(for: entry)) {
            isDirty = false
        } else {
            lastError = "Couldn't save your changes to this document."
        }
    }

    /// Writes an exported copy to a temporary file for the share
    /// sheet. The library copy is updated first if there are unsaved
    /// edits, so what is shared is what is on screen.
    func exportURL() -> URL? {
        persistEdits()
        let name = entry.name.isEmpty ? "Document" : entry.name
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).pdf")
        if document.write(to: url) { return url }
        lastError = "Couldn't prepare this document for sharing."
        return nil
    }
}
