import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum PreviewViewport: Equatable {
    case fit
    case scale(Double)
}

struct ReplacementPreviewRendererView: View {
    let sessionID: PreviewSessionID
    let content: PreviewContent
    let viewport: PreviewViewport
    let rotationQuarterTurns: Int
    let pageOrder: [Int]
    let onChooseFit: () -> Void
    let onRotate: (Int) -> Void
    let onReorderPages: ([Int]) -> Void

    @State private var requestedPage: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            GeometryReader { proxy in
                contentView(size: resolvedPreviewSize(proxy.size))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button("Fit", action: onChooseFit)
                .buttonStyle(.bordered)
                .fontWeight(viewport == .fit ? .semibold : .regular)

            Button {
                onRotate(1)
            } label: {
                Image(systemName: "rotate.left")
            }
            .buttonStyle(.borderless)

            Button {
                onRotate(-1)
            } label: {
                Image(systemName: "rotate.right")
            }
            .buttonStyle(.borderless)

            Spacer(minLength: 0)

            Text("Pinch to zoom · Drag below to resize")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func contentView(size: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.08)))

            switch content {
            case .loading:
                PreviewLoadingView(size: size)
            case .error(let title, let message):
                PreviewErrorView(title: title, message: message, size: size)
            case .asset(.pdf(let document)):
                pdfContent(document: document, size: size)
            case .asset(.image(let image)):
                ImagePreviewSurface(
                    image: image,
                    viewport: viewport,
                    rotationQuarterTurns: rotationQuarterTurns
                )
                .id(sessionID)
                .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private static let thumbnailSidebarWidth: CGFloat = 132

    @ViewBuilder
    private func pdfContent(document: PDFDocument, size: CGSize) -> some View {
        if document.pageCount > 1 {
            let surfaceWidth = max(size.width - Self.thumbnailSidebarWidth - 8, 200)
            HStack(spacing: 8) {
                PDFThumbnailSidebar(
                    document: document,
                    initialOrder: resolvedPageOrder(pageCount: document.pageCount),
                    onReorder: onReorderPages,
                    onSelectPage: { requestedPage = $0 }
                )
                .id(ObjectIdentifier(document))
                .frame(width: Self.thumbnailSidebarWidth, height: size.height)

                PDFPreviewSurface(
                    document: document,
                    viewport: viewport,
                    rotationQuarterTurns: rotationQuarterTurns,
                    pageOrder: resolvedPageOrder(pageCount: document.pageCount),
                    scrollToPage: requestedPage
                )
                .id(sessionID)
                .frame(width: surfaceWidth, height: size.height)
            }
            .frame(width: size.width, height: size.height)
        } else {
            PDFPreviewSurface(
                document: document,
                viewport: viewport,
                rotationQuarterTurns: rotationQuarterTurns,
                pageOrder: [],
                scrollToPage: nil
            )
            .id(sessionID)
            .frame(width: size.width, height: size.height)
        }
    }

    /// The live page order to display, falling back to identity until the state knows the count.
    private func resolvedPageOrder(pageCount: Int) -> [Int] {
        guard pageOrder.count == pageCount, Set(pageOrder) == Set(0..<pageCount) else {
            return Array(0..<pageCount)
        }
        return pageOrder
    }
}

private struct PDFThumbnailSidebar: View {
    let document: PDFDocument
    let onReorder: ([Int]) -> Void
    let onSelectPage: (Int) -> Void

    @State private var pageOrder: [Int]
    @State private var thumbnails: [Int: NSImage] = [:]
    @State private var draggingPageIndex: Int?

    init(
        document: PDFDocument,
        initialOrder: [Int],
        onReorder: @escaping ([Int]) -> Void,
        onSelectPage: @escaping (Int) -> Void
    ) {
        self.document = document
        self.onReorder = onReorder
        self.onSelectPage = onSelectPage
        let identity = Array(0..<document.pageCount)
        let resolved = (initialOrder.count == document.pageCount && Set(initialOrder) == Set(identity))
            ? initialOrder
            : identity
        _pageOrder = State(initialValue: resolved)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(Array(pageOrder.enumerated()), id: \.element) { position, pageIndex in
                    thumbnailRow(position: position, pageIndex: pageIndex)
                        .onDrag {
                            draggingPageIndex = pageIndex
                            return NSItemProvider(object: String(pageIndex) as NSString)
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: ThumbnailDropDelegate(
                                targetPageIndex: pageIndex,
                                pageOrder: $pageOrder,
                                draggingPageIndex: $draggingPageIndex,
                                onReorder: onReorder
                            )
                        )
                }
            }
            .padding(8)
        }
        .scrollContentBackground(.hidden)
        .task(id: ObjectIdentifier(document)) {
            await generateThumbnails()
        }
    }

    @ViewBuilder
    private func thumbnailRow(position: Int, pageIndex: Int) -> some View {
        VStack(spacing: 4) {
            Group {
                if let image = thumbnails[pageIndex] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: 84, height: 108)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))

            Text("\(position + 1)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .opacity(draggingPageIndex == pageIndex ? 0.4 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectPage(position)
        }
    }

    /// Generates thumbnails one page at a time, yielding between pages so a multi-page
    /// document never blocks the main thread in a single long stall. Thumbnails are keyed
    /// by the document's original page index, so they survive in-memory reordering and are
    /// never regenerated while the user rearranges pages.
    @MainActor
    private func generateThumbnails() async {
        let size = NSSize(width: 168, height: 216)
        for pageIndex in 0..<document.pageCount where thumbnails[pageIndex] == nil {
            if Task.isCancelled { return }
            guard let page = document.page(at: pageIndex) else { continue }
            let image = page.thumbnail(of: size, for: .mediaBox)
            thumbnails[pageIndex] = image
            await Task.yield()
        }
    }
}

private struct ThumbnailDropDelegate: DropDelegate {
    let targetPageIndex: Int
    @Binding var pageOrder: [Int]
    @Binding var draggingPageIndex: Int?
    let onReorder: ([Int]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingPageIndex,
              dragging != targetPageIndex,
              let fromPosition = pageOrder.firstIndex(of: dragging),
              let toPosition = pageOrder.firstIndex(of: targetPageIndex) else {
            return
        }

        withAnimation(.easeInOut(duration: 0.15)) {
            pageOrder.move(
                fromOffsets: IndexSet(integer: fromPosition),
                toOffset: toPosition > fromPosition ? toPosition + 1 : toPosition
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let didReorder = draggingPageIndex != nil
        draggingPageIndex = nil
        if didReorder {
            onReorder(pageOrder)
        }
        return true
    }
}

private struct PreviewLoadingView: View {
    let size: CGSize

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text("Loading Preview...")
                .font(.system(size: 15, weight: .semibold))
        }
        .frame(width: size.width, height: size.height)
    }
}

private struct PreviewErrorView: View {
    let title: String
    let message: String
    let size: CGSize

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: size.width, height: size.height)
    }
}

private struct PDFPreviewSurface: NSViewRepresentable {
    let document: PDFDocument
    let viewport: PreviewViewport
    let rotationQuarterTurns: Int
    let pageOrder: [Int]
    let scrollToPage: Int?

    func makeNSView(context: Context) -> PDFPreviewSurfaceView {
        PDFPreviewSurfaceView()
    }

    func updateNSView(_ nsView: PDFPreviewSurfaceView, context: Context) {
        nsView.render(
            document: document,
            viewport: viewport,
            rotationQuarterTurns: rotationQuarterTurns,
            pageOrder: pageOrder
        )
        nsView.scrollToPageIfNeeded(scrollToPage)
    }
}

private final class PDFPreviewSurfaceView: NSView {
    private struct RenderKey: Equatable {
        let documentID: ObjectIdentifier
        let rotationQuarterTurns: Int
        let pageOrder: [Int]
    }

    private let pdfView = PDFView()
    private var renderKey: RenderKey?
    private var currentViewport: PreviewViewport = .fit
    private var lastScrolledPage: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func layout() {
        super.layout()
        applyViewport()
    }

    func render(document: PDFDocument, viewport: PreviewViewport, rotationQuarterTurns: Int, pageOrder: [Int]) {
        currentViewport = viewport

        let normalizedRotation = normalizedPreviewRotationQuarterTurns(rotationQuarterTurns)
        let nextKey = RenderKey(
            documentID: ObjectIdentifier(document),
            rotationQuarterTurns: normalizedRotation,
            pageOrder: pageOrder
        )

        if nextKey != renderKey {
            pdfView.document = displayPreviewDocument(
                from: document,
                pageOrder: pageOrder,
                quarterTurns: normalizedRotation
            )
            if let firstPage = pdfView.document?.page(at: 0) {
                pdfView.go(to: firstPage)
            }
            renderKey = nextKey
            lastScrolledPage = nil
        }

        applyViewport()
    }

    func scrollToPageIfNeeded(_ pageIndex: Int?) {
        guard let pageIndex, pageIndex != lastScrolledPage else { return }
        guard let document = pdfView.document, pageIndex >= 0, pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else {
            return
        }
        lastScrolledPage = pageIndex
        pdfView.go(to: page)
    }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .windowBackgroundColor
        pdfView.minScaleFactor = 0.25
        pdfView.maxScaleFactor = 8.0

        addSubview(pdfView)

        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func applyViewport() {
        guard pdfView.document != nil else { return }

        switch currentViewport {
        case .fit:
            pdfView.autoScales = true
        case .scale(let value):
            pdfView.autoScales = false
            guard let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else { return }
            let fitScale = fitWidthScale(for: page)
            let effectiveScale = fitScale * CGFloat(value)
            pdfView.scaleFactor = min(max(effectiveScale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        }
    }

    private func fitWidthScale(for page: PDFPage) -> CGFloat {
        let contentWidth: CGFloat
        if let innerScrollView = pdfView.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView {
            contentWidth = innerScrollView.contentView.bounds.width
        } else {
            contentWidth = visibleWidth(for: pdfView, fallback: pdfView.bounds.width)
        }
        let availableWidth = max(contentWidth - 32, 200)
        let pageBounds = page.bounds(for: pdfView.displayBox)
        let pageWidth = max(pageBounds.width, 1)
        return availableWidth / pageWidth
    }
}

private struct ImagePreviewSurface: NSViewRepresentable {
    let image: NSImage
    let viewport: PreviewViewport
    let rotationQuarterTurns: Int

    func makeNSView(context: Context) -> ImagePreviewSurfaceView {
        ImagePreviewSurfaceView()
    }

    func updateNSView(_ nsView: ImagePreviewSurfaceView, context: Context) {
        nsView.render(
            image: image,
            viewport: viewport,
            rotationQuarterTurns: rotationQuarterTurns
        )
    }
}

private final class ImagePreviewSurfaceView: NSView {
    private struct RenderKey: Equatable {
        let imageID: ObjectIdentifier
        let rotationQuarterTurns: Int
    }

    private let scrollView = NSScrollView()
    private let documentView = TopAlignedImageDocumentView()
    private var renderKey: RenderKey?
    private var renderedImage: NSImage?
    private var currentViewport: PreviewViewport = .fit
    private var shouldResetScrollPosition = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func layout() {
        super.layout()
        applyViewport()
    }

    func render(image: NSImage, viewport: PreviewViewport, rotationQuarterTurns: Int) {
        currentViewport = viewport

        let normalizedRotation = normalizedPreviewRotationQuarterTurns(rotationQuarterTurns)
        let nextKey = RenderKey(
            imageID: ObjectIdentifier(image),
            rotationQuarterTurns: normalizedRotation
        )

        if nextKey != renderKey {
            renderedImage = renderedPreviewImage(from: image, quarterTurns: normalizedRotation)
            renderKey = nextKey
            shouldResetScrollPosition = true
        }

        applyViewport()
    }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView

        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func applyViewport() {
        guard let image = renderedImage else { return }

        let viewportSize = CGSize(
            width: resolvedPreviewLength(
                visibleWidth(for: scrollView, fallback: scrollView.bounds.width),
                fallback: scrollView.bounds.width,
                minimum: 200
            ),
            height: resolvedPreviewLength(
                scrollView.contentView.bounds.height,
                fallback: scrollView.bounds.height,
                minimum: 200
            )
        )
        let fitWidth = max(viewportSize.width - 32, 200)
        let fitScale = fitWidth / max(image.size.width, 1)

        let rawScale: CGFloat
        switch currentViewport {
        case .fit:
            rawScale = fitScale
        case .scale(let value):
            rawScale = fitScale * CGFloat(value)
        }

        let effectiveScale = resolvedPreviewLength(rawScale, fallback: 1, minimum: 0.01, maximum: 16)
        let width = resolvedPreviewLength(image.size.width * effectiveScale, fallback: 200, minimum: 200)
        let height = resolvedPreviewLength(image.size.height * effectiveScale, fallback: 200, minimum: 200)

        documentView.update(
            image: image,
            imageSize: CGSize(width: width, height: height),
            viewportSize: viewportSize
        )

        if shouldResetScrollPosition {
            let clipView = scrollView.contentView
            clipView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(clipView)
            shouldResetScrollPosition = false
        }
    }
}

private final class TopAlignedImageDocumentView: NSView {
    private let imageView = NSImageView()

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        addSubview(imageView)
    }

    func update(image: NSImage, imageSize: CGSize, viewportSize: CGSize) {
        imageView.image = image

        let resolvedImageSize = resolvedPreviewSize(imageSize, minimum: 1)
        let resolvedViewportSize = resolvedPreviewSize(viewportSize, minimum: 1)
        let canvasWidth = max(resolvedViewportSize.width, resolvedImageSize.width)
        let canvasHeight = max(resolvedViewportSize.height, resolvedImageSize.height)
        frame = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)

        let originX = max((canvasWidth - resolvedImageSize.width) / 2, 0)
        imageView.frame = NSRect(
            x: originX,
            y: 0,
            width: resolvedImageSize.width,
            height: resolvedImageSize.height
        )
    }
}

/// Builds the document shown by the preview surface, applying any live page reorder and/or
/// rotation. When both are no-ops the source document is returned unchanged. Pages are copied
/// so the shared/cached source document is never mutated.
private func displayPreviewDocument(
    from sourceDocument: PDFDocument,
    pageOrder: [Int],
    quarterTurns: Int
) -> PDFDocument {
    let normalizedRotation = normalizedPreviewRotationQuarterTurns(quarterTurns)
    let pageCount = sourceDocument.pageCount
    let identity = Array(0..<pageCount)
    let isIdentityOrder = pageOrder.isEmpty
        || (pageOrder.count == pageCount && pageOrder == identity)

    guard normalizedRotation != 0 || !isIdentityOrder else {
        return sourceDocument
    }

    let order = (pageOrder.count == pageCount && Set(pageOrder) == Set(identity)) ? pageOrder : identity
    let result = PDFDocument()
    let rotationDelta = -normalizedRotation * 90

    for (newIndex, originalIndex) in order.enumerated() {
        guard originalIndex >= 0,
              originalIndex < pageCount,
              let page = sourceDocument.page(at: originalIndex)?.copy() as? PDFPage else {
            continue
        }
        if normalizedRotation != 0 {
            page.rotation = normalizedPreviewPageRotation(page.rotation + rotationDelta)
        }
        result.insert(page, at: newIndex)
    }

    return result
}

private func normalizedPreviewPageRotation(_ value: Int) -> Int {
    let normalized = value % 360
    return normalized >= 0 ? normalized : normalized + 360
}

private func renderedPreviewImage(from image: NSImage, quarterTurns: Int) -> NSImage {
    let normalizedTurns = normalizedPreviewRotationQuarterTurns(quarterTurns)
    guard normalizedTurns != 0,
          let tiffData = image.tiffRepresentation,
          let bitmapRep = NSBitmapImageRep(data: tiffData),
          let cgImage = bitmapRep.cgImage else {
        return image
    }

    let sourceSize = CGSize(width: cgImage.width, height: cgImage.height)
    let destinationSize = normalizedTurns.isMultiple(of: 2)
        ? sourceSize
        : CGSize(width: sourceSize.height, height: sourceSize.width)

    guard let context = CGContext(
        data: nil,
        width: Int(destinationSize.width),
        height: Int(destinationSize.height),
        bitsPerComponent: cgImage.bitsPerComponent,
        bytesPerRow: 0,
        space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: cgImage.bitmapInfo.rawValue
    ) else {
        return image
    }

    switch normalizedTurns {
    case 1:
        context.translateBy(x: destinationSize.width, y: 0)
        context.rotate(by: .pi / 2)
    case 2:
        context.translateBy(x: destinationSize.width, y: destinationSize.height)
        context.rotate(by: .pi)
    case 3:
        context.translateBy(x: 0, y: destinationSize.height)
        context.rotate(by: -.pi / 2)
    default:
        break
    }

    context.draw(cgImage, in: CGRect(origin: .zero, size: sourceSize))

    guard let rotatedCGImage = context.makeImage() else {
        return image
    }

    return NSImage(
        cgImage: rotatedCGImage,
        size: NSSize(width: destinationSize.width, height: destinationSize.height)
    )
}

@MainActor
private func visibleWidth(for view: NSView, fallback: CGFloat) -> CGFloat {
    let width = view.visibleRect.width
    return resolvedPreviewLength(width, fallback: fallback, minimum: 1)
}

private func resolvedPreviewSize(_ size: CGSize, minimum: CGFloat = 1) -> CGSize {
    CGSize(
        width: resolvedPreviewLength(size.width, fallback: minimum, minimum: minimum),
        height: resolvedPreviewLength(size.height, fallback: minimum, minimum: minimum)
    )
}

private func resolvedPreviewLength(
    _ value: CGFloat,
    fallback: CGFloat,
    minimum: CGFloat,
    maximum: CGFloat = 10000
) -> CGFloat {
    let candidate = value.isFinite ? value : fallback
    let resolvedFallback = fallback.isFinite ? fallback : minimum
    let finiteValue = candidate.isFinite ? candidate : resolvedFallback
    return min(max(finiteValue, minimum), maximum)
}
