import SwiftUI
import PencilKit
import PDFKit

/// Persists the reader's saved signature (a transparent PNG) on the
/// device, so it can be stamped onto any document without redrawing.
enum SignatureStore {
    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("signature.png")
    }

    static func load() -> UIImage? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    static func save(_ image: UIImage) {
        if let data = image.pngData() {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// A PKCanvasView in SwiftUI clothing. The canvas instance is owned
/// by the parent view so toolbar buttons can undo/clear/commit it.
struct PencilCanvas: UIViewRepresentable {
    let canvasView: PKCanvasView
    var color: UIColor
    var width: CGFloat

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.drawingPolicy = .anyInput // finger or Apple Pencil
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.tool = PKInkingTool(.pen, color: color, width: width)
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // PKInkingTool is a value type: rebuild it when color/width change
        // rather than mutating a cast copy.
        if let tool = uiView.tool as? PKInkingTool,
           tool.color != color || tool.width != width {
            uiView.tool = PKInkingTool(.pen, color: color, width: width)
        }
    }
}

/// Full-page freehand drawing mode. The canvas sits exactly over the
/// PDFView; on Done, every stroke is converted to page coordinates by
/// the ReaderController and committed as a vector ink annotation on
/// the current page.
struct DrawingOverlayView: View {
    @ObservedObject var controller: ReaderController
    var onFinish: () -> Void

    @State private var canvasView = PKCanvasView()
    @State private var color: UIColor = .systemRed
    @State private var width: CGFloat = 3

    private let palette: [UIColor] = [.systemRed, .systemBlue, .black, .systemGreen, .systemOrange]

    var body: some View {
        ZStack(alignment: .bottom) {
            PencilCanvas(canvasView: canvasView, color: color, width: width)
                .ignoresSafeArea(edges: .horizontal)

            VStack(spacing: 10) {
                HStack(spacing: 14) {
                    ForEach(palette, id: \.self) { candidate in
                        Button {
                            color = candidate
                        } label: {
                            Circle()
                                .fill(Color(candidate))
                                .frame(width: 26, height: 26)
                                .overlay(Circle().stroke(Color.primary, lineWidth: color == candidate ? 2 : 0))
                        }
                    }
                    Divider().frame(height: 24)
                    ForEach([CGFloat(2), 4, 7], id: \.self) { candidate in
                        Button {
                            width = candidate
                        } label: {
                            Circle()
                                .fill(Color.primary)
                                .frame(width: candidate * 2.4, height: candidate * 2.4)
                                .padding(4)
                                .overlay(Circle().stroke(Color.secondary, lineWidth: width == candidate ? 1.5 : 0))
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button("Undo") { canvasView.undoManager?.undo() }
                    Button("Clear") { canvasView.drawing = PKDrawing() }
                    Spacer()
                    Button("Cancel", role: .cancel) { onFinish() }
                    Button("Done") { commit() }
                        .fontWeight(.semibold)
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
    }

    private func commit() {
        guard let page = controller.currentPage else { onFinish(); return }
        for stroke in canvasView.drawing.strokes {
            let points = (0..<stroke.path.count).map { stroke.path[$0].location }
            let strokeWidth = stroke.path.count > 0 ? stroke.path[0].size.width : width
            controller.commitStroke(points: points,
                                    color: stroke.ink.color,
                                    lineWidthView: strokeWidth,
                                    on: page)
        }
        canvasView.drawing = PKDrawing()
        onFinish()
    }
}

/// Sheet for drawing (or redrawing) the saved signature.
struct SignaturePadView: View {
    var onDone: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var canvasView = PKCanvasView()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Sign inside the box. This signature is saved on your device and can be stamped onto any page.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                PencilCanvas(canvasView: canvasView, color: .black, width: 3)
                    .frame(height: 220)
                    .background(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.4)))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                Button("Clear") { canvasView.drawing = PKDrawing() }
                    .buttonStyle(.bordered)

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Signature") {
                        let drawing = canvasView.drawing
                        guard !drawing.strokes.isEmpty else { return }
                        let image = drawing.image(from: drawing.bounds, scale: 3)
                        SignatureStore.save(image)
                        onDone(image)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

/// Lets the reader position a signature over the page: drag to move,
/// pinch to resize, then Stamp burns it into the page (see
/// ReaderController.stampSignature). The overlay covers exactly the
/// PDFView, so the frame it reports is already in PDFView view
/// coordinates.
struct SignaturePlacementView: View {
    let image: UIImage
    var onStamp: (CGRect) -> Void
    var onCancel: () -> Void

    @State private var offset: CGSize = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var liveScale: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            let baseWidth = min(geometry.size.width * 0.55, 260)
            let aspect = image.size.height > 0 ? image.size.width / image.size.height : 3
            let effectiveScale = min(max(scale * liveScale, 0.3), 3)
            let displaySize = CGSize(width: baseWidth * effectiveScale,
                                     height: (baseWidth / max(aspect, 0.2)) * effectiveScale)
            let center = CGPoint(x: geometry.size.width / 2 + offset.width + dragTranslation.width,
                                 y: geometry.size.height / 2 + offset.height + dragTranslation.height)
            let frame = CGRect(x: center.x - displaySize.width / 2,
                               y: center.y - displaySize.height / 2,
                               width: displaySize.width,
                               height: displaySize.height)

            ZStack {
                Color.clear
                Image(uiImage: image)
                    .resizable()
                    .frame(width: displaySize.width, height: displaySize.height)
                    .background(Color.white.opacity(0.25))
                    .overlay(Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    .position(center)
                    .gesture(
                        DragGesture()
                            .onChanged { value in dragTranslation = value.translation }
                            .onEnded { value in
                                offset.width += value.translation.width
                                offset.height += value.translation.height
                                dragTranslation = .zero
                            }
                    )
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in liveScale = value }
                            .onEnded { value in
                                scale = min(max(scale * value, 0.3), 3)
                                liveScale = 1
                            }
                    )

                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Button("Cancel", role: .cancel) { onCancel() }
                        Spacer()
                        Button("Stamp Signature") { onStamp(frame) }
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.bordered)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding()
                }
            }
        }
    }
}
