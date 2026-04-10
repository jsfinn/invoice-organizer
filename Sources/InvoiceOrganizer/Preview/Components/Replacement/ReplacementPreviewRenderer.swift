import AppKit
import PDFKit
import SwiftUI

enum PreviewViewport: Equatable {
    case fit
    case scale(Double)
}

struct ReplacementPreviewRendererView: View {
    let sessionID: PreviewSessionID
    let content: PreviewContent
    let viewport: PreviewViewport
    let rotationQuarterTurns: Int
    let onChooseFit: () -> Void
    let onRotate: (Int) -> Void

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
                PDFPreviewSurface(
                    document: document,
                    viewport: viewport,
                    rotationQuarterTurns: rotationQuarterTurns
                )
                .id(sessionID)
                .frame(width: size.width, height: size.height)
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

    func makeNSView(context: Context) -> PDFPreviewSurfaceView {
        PDFPreviewSurfaceView()
    }

    func updateNSView(_ nsView: PDFPreviewSurfaceView, context: Context) {
        nsView.render(
            document: document,
            viewport: viewport,
            rotationQuarterTurns: rotationQuarterTurns
        )
    }
}

private final class PDFPreviewSurfaceView: NSView {
    private struct RenderKey: Equatable {
        let documentID: ObjectIdentifier
        let rotationQuarterTurns: Int
    }

    private let pdfView = PDFView()
    private var renderKey: RenderKey?
    private var currentViewport: PreviewViewport = .fit

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

    func render(document: PDFDocument, viewport: PreviewViewport, rotationQuarterTurns: Int) {
        currentViewport = viewport

        let normalizedRotation = normalizedPreviewRotationQuarterTurns(rotationQuarterTurns)
        let nextKey = RenderKey(
            documentID: ObjectIdentifier(document),
            rotationQuarterTurns: normalizedRotation
        )

        if nextKey != renderKey {
            pdfView.document = rotatedPreviewDocument(from: document, quarterTurns: normalizedRotation)
            if let firstPage = pdfView.document?.page(at: 0) {
                pdfView.go(to: firstPage)
            }
            renderKey = nextKey
        }

        applyViewport()
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

private func rotatedPreviewDocument(from sourceDocument: PDFDocument, quarterTurns: Int) -> PDFDocument {
    let normalizedRotation = normalizedPreviewRotationQuarterTurns(quarterTurns)
    guard normalizedRotation != 0,
          let data = sourceDocument.dataRepresentation(),
          let rotatedDocument = PDFDocument(data: data) else {
        return sourceDocument
    }

    let rotationDelta = -normalizedRotation * 90
    for pageIndex in 0..<rotatedDocument.pageCount {
        guard let page = rotatedDocument.page(at: pageIndex) else { continue }
        page.rotation = normalizedPreviewPageRotation(page.rotation + rotationDelta)
    }

    return rotatedDocument
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
