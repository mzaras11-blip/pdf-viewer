import SwiftUI
import PDFKit

/// Thumbnail grid for navigation AND page management:
///   - tap a thumbnail to jump to that page,
///   - drag thumbnails to reorder pages,
///   - long-press (context menu) to rotate or delete a page.
/// While this sheet is up, the ad timer is blocked (a natural break
/// boundary) — ReaderView owns that flag.
struct ThumbnailsView: View {
    @ObservedObject var controller: ReaderController
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(0..<controller.pageCount, id: \.self) { index in
                        cell(for: index)
                    }
                }
                .padding()
            }
            .navigationTitle("Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(for index: Int) -> some View {
        let isCurrent = index == controller.currentPageIndex
        VStack(spacing: 6) {
            ThumbnailImage(page: controller.document.page(at: index))
                .frame(width: 96, height: 128)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isCurrent ? Color.accentColor : Color.secondary.opacity(0.35),
                                lineWidth: isCurrent ? 3 : 1)
                )
                .shadow(radius: 2, y: 1)
            Text("\(index + 1)")
                .font(.caption)
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .fontWeight(isCurrent ? .bold : .regular)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            controller.goToPage(index)
            dismiss()
        }
        .draggable(String(index))
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let source = Int(raw),
                  source != index else { return false }
            controller.movePage(from: source, to: index)
            return true
        }
        .contextMenu {
            Button {
                controller.goToPage(index)
                dismiss()
            } label: {
                Label("Go to Page", systemImage: "arrow.right.doc.on.clipboard")
            }
            Button {
                controller.rotatePage(at: index)
            } label: {
                Label("Rotate Page", systemImage: "rotate.right")
            }
            if controller.pageCount > 1 {
                Button(role: .destructive) {
                    controller.deletePage(at: index)
                } label: {
                    Label("Delete Page", systemImage: "trash")
                }
            }
        }
    }
}

/// Renders one page's thumbnail (PDFKit does the rasterizing).
private struct ThumbnailImage: View {
    let page: PDFPage?

    var body: some View {
        if let page {
            Image(uiImage: page.thumbnail(of: CGSize(width: 192, height: 256), for: .mediaBox))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Color.secondary.opacity(0.15)
        }
    }
}
