import CoreText
import Foundation
import PDFKit
import UIKit
import Vision

/// Progress + cancellation plumbing shared by the long-running
/// tools (OCR, compress, image export). The engine runs on a
/// background task; the UI owns a sink, reads progress through the
/// callback, and cancels through the same object.
final class ProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledFlag = false

    /// Called with (pagesDone, pagesTotal) as work proceeds.
    var onProgress: ((Int, Int) -> Void)?

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledFlag
    }

    func cancel() {
        lock.lock()
        cancelledFlag = true
        lock.unlock()
    }

    func report(_ done: Int, _ total: Int) {
        onProgress?(done, total)
    }
}

/// The Acrobat-style document tools, as pure PDFKit/Vision
/// operations on a PDFDocument. Every function takes a document the
/// caller loaded fresh from its file (never the reader's live
/// document) and returns a NEW document; the caller registers the
/// result in the library as its own copy. The source is never
/// modified.
enum PDFTools {

    // MARK: - Page rendering

    /// Rasterizes one page at the given resolution. The page is
    /// drawn with PDFKit's own page drawing (the same recipe the
    /// signature burn-in uses), so the image matches what the
    /// reader shows for ordinary, unrotated pages.
    static func renderedPageImage(_ page: PDFPage, dpi: CGFloat) -> UIImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = dpi / 72
        let pixelSize = CGSize(width: bounds.width * scale,
                               height: bounds.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        return renderer.image { context in
            let cg = context.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: pixelSize))
            cg.saveGState()
            cg.translateBy(x: 0, y: pixelSize.height)
            cg.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: cg)
            cg.restoreGState()
        }
    }

    /// Builds a one-page PDF page that shows the given image at the
    /// given page bounds. When jpegQuality is set, the image is
    /// round-tripped through JPEG first so the stored page is
    /// actually compressed rather than an embedded PNG.
    static func imagePage(image: UIImage, bounds: CGRect,
                          jpegQuality: CGFloat?) -> PDFPage? {
        var toDraw = image
        if let quality = jpegQuality,
           let data = image.jpegData(compressionQuality: quality),
           let recompressed = UIImage(data: data) {
            toDraw = recompressed
        }
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            context.beginPage()
            toDraw.draw(in: bounds)
        }
        guard let document = PDFDocument(data: data) else { return nil }
        return document.page(at: 0)
    }

    /// Best-effort copy of an annotation (same approach as the
    /// signature burn-in). Form widgets are never copied: their
    /// field values do not survive a rebuild, so callers filter
    /// them out before calling this.
    static func copyAnnotation(_ source: PDFAnnotation) -> PDFAnnotation? {
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

    /// Copies a page's non-widget annotations onto a rebuilt page.
    static func copyAnnotations(from source: PDFPage, to target: PDFPage) {
        for annotation in source.annotations
        where annotation.type != PDFAnnotationSubtype.widget.rawValue {
            if let copy = copyAnnotation(annotation) {
                target.addAnnotation(copy)
            }
        }
    }

    // MARK: - OCR (Make Searchable)

    /// Adds an invisible text layer to every page that lacks one,
    /// using the on-device Vision recognizer, and returns the new
    /// document. Pages that already carry real text pass through
    /// untouched. The recognized words are drawn invisibly over the
    /// re-rendered page image at their recognized positions, so
    /// search, selection, and copy work on the result. Nothing
    /// leaves the device.
    static func ocrDocument(_ source: PDFDocument, sink: ProgressSink) -> PDFDocument? {
        let total = source.pageCount
        guard total > 0 else { return nil }
        let output = PDFDocument()
        for index in 0..<total {
            if sink.cancelled { return nil }
            guard let page = source.page(at: index) else { continue }
            let existing = page.string?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if existing.count > 20 {
                output.insert(page, at: output.pageCount)
                sink.report(index + 1, total)
                continue
            }
            guard let image = renderedPageImage(page, dpi: 200),
                  let cgImage = image.cgImage else {
                output.insert(page, at: output.pageCount)
                sink.report(index + 1, total)
                continue
            }
            let words = recognizeWords(cgImage: cgImage)
            if words.isEmpty {
                output.insert(page, at: output.pageCount)
                sink.report(index + 1, total)
                continue
            }
            let bounds = page.bounds(for: .mediaBox)
            let observations: [(String, CGRect)] = words.map { text, box in
                (text, CGRect(x: box.minX * bounds.width,
                              y: box.minY * bounds.height,
                              width: box.width * bounds.width,
                              height: box.height * bounds.height))
            }
            if let newPage = searchablePage(from: page, observations: observations) {
                copyAnnotations(from: page, to: newPage)
                output.insert(newPage, at: output.pageCount)
            } else {
                output.insert(page, at: output.pageCount)
            }
            sink.report(index + 1, total)
        }
        return output.pageCount > 0 ? output : nil
    }

    /// Runs Vision text recognition over a page image and returns
    /// (text, normalized bounding box) pairs. Vision boxes are
    /// normalized with a bottom-left origin — the same orientation
    /// as PDF page space, which is why the mapping in ocrDocument
    /// is a plain scale.
    private static func recognizeWords(cgImage: CGImage) -> [(String, CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let results = request.results else { return [] }
        return results.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return (candidate.string, observation.boundingBox)
        }
    }

    /// Rebuilds one page as: original page content, plus the
    /// recognized words drawn as invisible text at their positions.
    private static func searchablePage(from page: PDFPage,
                                       observations: [(String, CGRect)]) -> PDFPage? {
        let bounds = page.bounds(for: .mediaBox)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            context.beginPage()
            let cg = context.cgContext
            cg.saveGState()
            cg.translateBy(x: 0, y: bounds.height)
            cg.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: cg)
            cg.restoreGState()
            for (text, box) in observations {
                // Convert PDF space (bottom-left origin) into the
                // renderer's UIKit space (top-left origin).
                let rect = CGRect(x: box.minX,
                                  y: bounds.height - box.maxY,
                                  width: box.width,
                                  height: box.height)
                drawInvisibleText(text, in: rect, cg: cg)
            }
        }
        guard let document = PDFDocument(data: data) else { return nil }
        return document.page(at: 0)
    }

    /// Draws one recognized line as invisible text (CoreText text
    /// rendering mode "invisible"): the words land in the page's
    /// text layer — searchable, selectable, copyable — without
    /// changing how the page looks. The font is sized to the
    /// recognized box, then stretched to the box's width.
    private static func drawInvisibleText(_ text: String, in rect: CGRect, cg: CGContext) {
        guard rect.width > 2, rect.height > 2 else { return }
        func makeLine(fontSize: CGFloat) -> CTLine {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize),
            ]
            let attributed = NSAttributedString(string: text, attributes: attributes)
            return CTLineCreateWithAttributedString(attributed)
        }
        var line = makeLine(fontSize: rect.height)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        if width > 1 {
            let adjusted = rect.height * (rect.width / CGFloat(width))
            if abs(adjusted - rect.height) > 0.5 {
                line = makeLine(fontSize: adjusted)
            }
        }
        cg.saveGState()
        cg.setTextDrawingMode(.invisible)
        cg.translateBy(x: rect.minX, y: rect.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.textMatrix = .identity
        cg.textPosition = CGPoint(x: 0, y: 0)
        CTLineDraw(line, cg)
        cg.restoreGState()
    }

    // MARK: - Compress

    /// Quality presets for Compress, as render resolutions.
    enum CompressQuality: String, CaseIterable, Identifiable {
        case screen
        case balanced
        case print

        var id: String { rawValue }

        var label: String {
            switch self {
            case .screen: return "Screen · 150 dpi"
            case .balanced: return "Balanced · 200 dpi"
            case .print: return "Print · 300 dpi"
            }
        }

        var dpi: CGFloat {
            switch self {
            case .screen: return 150
            case .balanced: return 200
            case .print: return 300
            }
        }
    }

    /// Rebuilds the document with every page re-rendered as a JPEG
    /// image at the chosen resolution — the standard way to shrink
    /// a scan-heavy PDF for email. Annotations (except form fields)
    /// are carried over as annotations; the page content itself
    /// becomes an image, so text in the output is not selectable.
    /// Note: compressing a document that is already lean text can
    /// make the copy BIGGER, not smaller — the tools sheet shows
    /// the before/after sizes so the result is never a surprise.
    static func compressedDocument(_ source: PDFDocument,
                                   quality: CompressQuality,
                                   sink: ProgressSink) -> PDFDocument? {
        let total = source.pageCount
        guard total > 0 else { return nil }
        let output = PDFDocument()
        for index in 0..<total {
            if sink.cancelled { return nil }
            guard let page = source.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            if let image = renderedPageImage(page, dpi: quality.dpi),
               let newPage = imagePage(image: image, bounds: bounds, jpegQuality: 0.72) {
                copyAnnotations(from: page, to: newPage)
                output.insert(newPage, at: output.pageCount)
            } else {
                output.insert(page, at: output.pageCount)
            }
            sink.report(index + 1, total)
        }
        return output.pageCount > 0 ? output : nil
    }

    // MARK: - Split / extract

    /// Builds a new document holding only the given pages (0-based
    /// indexes, in document order).
    static func extractedDocument(_ source: PDFDocument,
                                  pageIndexes: [Int]) -> PDFDocument? {
        let wanted = pageIndexes
            .filter { $0 >= 0 && $0 < source.pageCount }
            .sorted()
        guard !wanted.isEmpty else { return nil }
        let output = PDFDocument()
        for index in wanted {
            if let page = source.page(at: index) {
                output.insert(page, at: output.pageCount)
            }
        }
        return output.pageCount > 0 ? output : nil
    }

    // MARK: - PDF to images

    /// Renders the given pages to PNG-ready images at 200 dpi,
    /// returned as (page index, image) pairs in document order.
    static func pageImages(_ source: PDFDocument,
                           pageIndexes: [Int],
                           sink: ProgressSink) -> [(Int, UIImage)] {
        var images: [(Int, UIImage)] = []
        let wanted = pageIndexes
            .filter { $0 >= 0 && $0 < source.pageCount }
            .sorted()
        for (offset, index) in wanted.enumerated() {
            if sink.cancelled { break }
            if let page = source.page(at: index),
               let image = renderedPageImage(page, dpi: 200) {
                images.append((index, image))
            }
            sink.report(offset + 1, wanted.count)
        }
        return images
    }

    // MARK: - Rebuild (for password removal)

    /// Copies every page into a brand-new document. Saving this —
    /// rather than the document that was loaded from an encrypted
    /// file — is what actually drops the encryption: PDFKit's write
    /// preserves the source file's encryption dictionary when the
    /// document came from one, but a fresh document has none to
    /// preserve.
    static func rebuiltDocument(from source: PDFDocument) -> PDFDocument {
        let output = PDFDocument()
        for index in 0..<source.pageCount {
            if let page = source.page(at: index) {
                output.insert(page, at: output.pageCount)
            }
        }
        return output
    }

    // MARK: - Redaction rendering

    /// Burns redaction boxes into a page: the page is rasterized at
    /// print quality (300 dpi) with the boxes painted solid black,
    /// and the raster becomes the new page. Because the output page
    /// is a picture, the text under the boxes is not hidden — it is
    /// gone from the file. Annotations on the page are deliberately
    /// NOT carried over (an annotation could itself hold the text
    /// being redacted). The rebuilt page is upright in media-box
    /// space; any rotation the original page carried is not
    /// re-applied.
    static func redactedPage(from page: PDFPage, boxes: [CGRect],
                             dpi: CGFloat = 300) -> PDFPage? {
        guard !boxes.isEmpty,
              let image = renderedPageImage(page, dpi: dpi) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let burned = UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            image.draw(at: .zero)
            UIColor.black.setFill()
            for box in boxes {
                // PDF space (bottom-left origin) → image space
                // (top-left origin), scaled to pixels.
                let rect = CGRect(x: box.minX * scale,
                                  y: (bounds.height - box.maxY) * scale,
                                  width: box.width * scale,
                                  height: box.height * scale)
                context.fill(rect)
            }
        }
        return imagePage(image: burned, bounds: bounds, jpegQuality: 0.85)
    }

    // MARK: - Background color sampling (cover & retype)

    /// Estimates the page's background color around a rectangle by
    /// averaging small patches just outside its corners and edge
    /// midpoints — the color a "cover" patch should be painted so
    /// the covered text disappears into the page.
    static func sampleBackgroundColor(page: PDFPage, rect: CGRect) -> UIColor {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0,
              let image = renderedPageImage(page, dpi: 144),
              let cgImage = image.cgImage else { return .white }
        let scale = CGFloat(cgImage.width) / bounds.width
        let outset: CGFloat = 5
        let candidates: [CGPoint] = [
            CGPoint(x: rect.minX - outset, y: rect.minY - outset),
            CGPoint(x: rect.maxX + outset, y: rect.minY - outset),
            CGPoint(x: rect.minX - outset, y: rect.maxY + outset),
            CGPoint(x: rect.maxX + outset, y: rect.maxY + outset),
            CGPoint(x: rect.midX, y: rect.minY - outset),
            CGPoint(x: rect.midX, y: rect.maxY + outset),
            CGPoint(x: rect.minX - outset, y: rect.midY),
            CGPoint(x: rect.maxX + outset, y: rect.midY),
        ]
        var colors: [UIColor] = []
        for point in candidates {
            let clamped = CGPoint(x: min(max(point.x, 1), bounds.width - 1),
                                  y: min(max(point.y, 1), bounds.height - 1))
            // Page space (bottom-left origin) → image pixels
            // (top-left origin).
            let pixelCenter = CGPoint(x: clamped.x * scale,
                                      y: (bounds.height - clamped.y) * scale)
            let patch = CGRect(x: pixelCenter.x - 3, y: pixelCenter.y - 3,
                               width: 6, height: 6)
                .intersection(CGRect(x: 0, y: 0,
                                     width: cgImage.width, height: cgImage.height))
            guard !patch.isNull, patch.width >= 1, patch.height >= 1,
                  let cropped = cgImage.cropping(to: patch) else { continue }
            if let average = averageColor(of: cropped) {
                colors.append(average)
            }
        }
        guard !colors.isEmpty else { return .white }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        for color in colors {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            red += r; green += g; blue += b; alpha += a
        }
        let count = CGFloat(colors.count)
        return UIColor(red: red / count, green: green / count,
                       blue: blue / count, alpha: alpha / count)
    }

    /// The average color of a small image, via a 1x1 bitmap draw.
    private static func averageColor(of image: CGImage) -> UIColor? {
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(red: CGFloat(pixel[0]) / 255,
                       green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255,
                       alpha: CGFloat(pixel[3]) / 255)
    }
}
