import Foundation
import PDFKit
import UIKit

/// One PDF in the app's library. The file itself lives in the app's
/// own Documents/Imports folder (imported as a copy), so the original
/// in Files/iCloud is never modified by editing.
struct RecentDocument: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    /// Display name (file name without extension at import time).
    var name: String
    /// File name inside Documents/Imports.
    var fileName: String
    var addedAt: Date
    var lastOpenedAt: Date
    /// Last page read, restored on open.
    var lastPage: Int
    var isFavorite: Bool
    var pageCount: Int
}

/// A bookmark on a specific page of a specific document.
struct PageBookmark: Identifiable, Codable, Equatable {
    var id: UUID
    var documentID: UUID
    var pageIndex: Int
    var label: String
    var createdAt: Date
}

/// Owns the on-device library: the recents list, favorites, page
/// bookmarks, and the imported PDF files themselves. Everything is
/// persisted as one JSON file in Application Support; nothing leaves
/// the device.
final class LibraryStore: ObservableObject {
    @Published private(set) var recents: [RecentDocument] = []
    @Published private(set) var bookmarks: [PageBookmark] = []

    private let storeFileName = "library.json"

    init() {
        load()
    }

    // MARK: - Locations

    private var importsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Imports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var storeFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent(storeFileName)
    }

    func fileURL(for document: RecentDocument) -> URL {
        importsDirectory.appendingPathComponent(document.fileName)
    }

    // MARK: - Import / open / delete

    /// Copies a picked PDF into the library and registers it. Picking
    /// the same file again refreshes the existing entry instead of
    /// duplicating it (matched by file name + page count + size).
    @discardableResult
    func importPDF(from pickedURL: URL) throws -> RecentDocument {
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }

        guard let probe = PDFDocument(url: pickedURL) else {
            throw LibraryError.notAPDF
        }
        let pageCount = probe.pageCount
        let baseName = pickedURL.deletingPathExtension().lastPathComponent

        let pickedSize = (try? pickedURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        if let existing = recents.first(where: { candidate in
            guard candidate.name == baseName, candidate.pageCount == pageCount else { return false }
            let size = (try? fileURL(for: candidate).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -2
            return size == pickedSize
        }) {
            touch(existing, page: existing.lastPage)
            return recents.first(where: { $0.id == existing.id }) ?? existing
        }

        let id = UUID()
        let fileName = "\(id.uuidString).pdf"
        let destination = importsDirectory.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: pickedURL, to: destination)

        let entry = RecentDocument(
            id: id,
            name: baseName,
            fileName: fileName,
            addedAt: Date(),
            lastOpenedAt: Date(),
            lastPage: 0,
            isFavorite: false,
            pageCount: pageCount
        )
        recents.insert(entry, at: 0)
        save()
        return entry
    }

    /// Loads the working PDFDocument for a library entry.
    func openDocument(_ entry: RecentDocument) -> PDFDocument? {
        PDFDocument(url: fileURL(for: entry))
    }

    /// Removes a document from the library and deletes its file.
    func delete(_ entry: RecentDocument) {
        try? FileManager.default.removeItem(at: fileURL(for: entry))
        recents.removeAll { $0.id == entry.id }
        bookmarks.removeAll { $0.documentID == entry.id }
        save()
    }

    /// Records that a document was opened / read to a page.
    func touch(_ entry: RecentDocument, page: Int) {
        guard let index = recents.firstIndex(where: { $0.id == entry.id }) else { return }
        recents[index].lastOpenedAt = Date()
        recents[index].lastPage = page
        recents.sort { $0.lastOpenedAt > $1.lastOpenedAt }
        save()
    }

    /// Updates the cached page count after page-level edits.
    func updatePageCount(_ entry: RecentDocument, pageCount: Int) {
        guard let index = recents.firstIndex(where: { $0.id == entry.id }) else { return }
        recents[index].pageCount = pageCount
        save()
    }

    func toggleFavorite(_ entry: RecentDocument) {
        guard let index = recents.firstIndex(where: { $0.id == entry.id }) else { return }
        recents[index].isFavorite.toggle()
        save()
    }

    // MARK: - Bookmarks

    func bookmarks(for documentID: UUID) -> [PageBookmark] {
        bookmarks
            .filter { $0.documentID == documentID }
            .sorted { $0.pageIndex < $1.pageIndex }
    }

    func isBookmarked(documentID: UUID, pageIndex: Int) -> Bool {
        bookmarks.contains { $0.documentID == documentID && $0.pageIndex == pageIndex }
    }

    func toggleBookmark(documentID: UUID, pageIndex: Int, documentName: String) {
        if let existing = bookmarks.first(where: {
            $0.documentID == documentID && $0.pageIndex == pageIndex
        }) {
            bookmarks.removeAll { $0.id == existing.id }
        } else {
            bookmarks.append(PageBookmark(
                id: UUID(),
                documentID: documentID,
                pageIndex: pageIndex,
                label: "\(documentName) — page \(pageIndex + 1)",
                createdAt: Date()
            ))
        }
        save()
    }

    func removeBookmark(_ bookmark: PageBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        save()
    }

    // MARK: - Merge

    /// Combines the given library documents, in order, into one new
    /// library entry. Returns the new entry, or nil if nothing could
    /// be merged (needs at least two readable documents).
    func merge(documents entries: [RecentDocument]) -> RecentDocument? {
        let sources = entries.compactMap { openDocument($0) }
        guard sources.count >= 2 else { return nil }

        let merged = PDFDocument()
        for source in sources {
            for index in 0..<source.pageCount {
                if let page = source.page(at: index) {
                    merged.insert(page, at: merged.pageCount)
                }
            }
        }
        guard merged.pageCount > 0 else { return nil }

        let id = UUID()
        let fileName = "\(id.uuidString).pdf"
        let destination = importsDirectory.appendingPathComponent(fileName)
        guard merged.write(to: destination) else { return nil }

        let name = "Merged — " + entries.map(\.name).joined(separator: " + ")
        let entry = RecentDocument(
            id: id,
            name: name,
            fileName: fileName,
            addedAt: Date(),
            lastOpenedAt: Date(),
            lastPage: 0,
            isFavorite: false,
            pageCount: merged.pageCount
        )
        recents.insert(entry, at: 0)
        save()
        return entry
    }

    // MARK: - Scan

    /// Assembles scanned page images (from the document camera) into
    /// one PDF and registers it in the library, exactly like an
    /// imported file: the PDF lives in Documents/Imports under its
    /// own copy, appears in recents, and every reader/editor feature
    /// works on it. Each page keeps the image's own aspect ratio,
    /// fitted inside a US Letter page (612 x 792 pt), so a portrait
    /// sheet of paper becomes a near-letter portrait PDF page.
    /// Returns the new entry, or nil if the PDF couldn't be written.
    @discardableResult
    func importScan(images: [UIImage], name: String) -> RecentDocument? {
        guard !images.isEmpty else { return nil }

        let id = UUID()
        let fileName = "\(id.uuidString).pdf"
        let destination = importsDirectory.appendingPathComponent(fileName)

        UIGraphicsBeginPDFContextToFile(destination.path, .zero, nil)
        for image in images {
            let prepared = Self.downscaled(image, maxDimension: 2048)
            let pageRect = Self.scanPageRect(for: prepared.size)
            UIGraphicsBeginPDFPageWithInfo(pageRect, nil)
            prepared.draw(in: pageRect)
        }
        UIGraphicsEndPDFContext()

        guard let written = PDFDocument(url: destination), written.pageCount > 0 else {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }

        let entry = RecentDocument(
            id: id,
            name: name,
            fileName: fileName,
            addedAt: Date(),
            lastOpenedAt: Date(),
            lastPage: 0,
            isFavorite: false,
            pageCount: written.pageCount
        )
        recents.insert(entry, at: 0)
        save()
        return entry
    }

    /// The page size for one scanned image: the image's aspect ratio
    /// fitted inside a US Letter box.
    private static func scanPageRect(for imageSize: CGSize) -> CGRect {
        let letter = CGSize(width: 612, height: 792)
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: letter)
        }
        let scale = min(letter.width / imageSize.width, letter.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(origin: .zero, size: size)
    }

    /// Caps a scan image's long edge so multi-page scans stay a
    /// sensible file size; smaller images pass through untouched.
    private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let factor = maxDimension / longest
        let target = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    // MARK: - Persistence

    private struct PersistedLibrary: Codable {
        var recents: [RecentDocument]
        var bookmarks: [PageBookmark]
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeFileURL),
              let decoded = try? JSONDecoder().decode(PersistedLibrary.self, from: data)
        else { return }
        recents = decoded.recents
        bookmarks = decoded.bookmarks
    }

    private func save() {
        let payload = PersistedLibrary(recents: recents, bookmarks: bookmarks)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: storeFileURL, options: [.atomic])
        }
    }
}

enum LibraryError: LocalizedError {
    case notAPDF

    var errorDescription: String? {
        switch self {
        case .notAPDF: return "That file couldn't be read as a PDF."
        }
    }
}
