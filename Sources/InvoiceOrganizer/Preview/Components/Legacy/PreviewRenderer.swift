import AppKit
import PDFKit
import SwiftUI

struct PreviewRendererView: NSViewRepresentable {
    let content: PreviewContent
    let zoomScale: Double
    let zoomToFit: Bool
    let rotationQuarterTurns: Int
    let onChooseFit: () -> Void
    let onChooseZoomPreset: (Double?) -> Void
    let onStepZoom: (Double) -> Void
    let onRotate: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> InvoicePreviewPaneContainerView {
        let view = InvoicePreviewPaneContainerView()
        view.configureActions(
            target: context.coordinator,
            fitAction: #selector(Coordinator.didChooseFit),
            zoomPresetAction: #selector(Coordinator.didChooseZoomPreset(_:)),
            zoomOutAction: #selector(Coordinator.didZoomOut),
            zoomInAction: #selector(Coordinator.didZoomIn),
            rotateLeftAction: #selector(Coordinator.didRotateLeft),
            rotateRightAction: #selector(Coordinator.didRotateRight)
        )
        return view
    }

    func updateNSView(_ nsView: InvoicePreviewPaneContainerView, context: Context) {
        context.coordinator.parent = self
        nsView.render(content)
        nsView.updateControls(
            zoomScale: zoomScale,
            zoomToFit: zoomToFit,
            rotationQuarterTurns: rotationQuarterTurns
        )
        nsView.applyPreviewState(
            zoomScale: zoomScale,
            zoomToFit: zoomToFit,
            rotationQuarterTurns: rotationQuarterTurns
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PreviewRendererView

        init(parent: PreviewRendererView) {
            self.parent = parent
        }

        @objc func didChooseFit() {
            parent.onChooseFit()
        }

        @objc func didChooseZoomPreset(_ sender: NSPopUpButton) {
            guard let item = sender.selectedItem else { return }
            let value = (item.representedObject as? NSNumber)?.doubleValue
            parent.onChooseZoomPreset(value)
        }

        @objc func didZoomOut() {
            parent.onStepZoom(-0.25)
        }

        @objc func didZoomIn() {
            parent.onStepZoom(0.25)
        }

        @objc func didRotateLeft() {
            parent.onRotate(1)
        }

        @objc func didRotateRight() {
            parent.onRotate(-1)
        }
    }
}

private enum PreviewZoomPreset: Double, CaseIterable, Identifiable {
    case fifty = 0.5
    case seventyFive = 0.75
    case oneHundred = 1.0
    case oneTwentyFive = 1.25
    case oneFifty = 1.5
    case twoHundred = 2.0

    var id: Double { rawValue }

    var label: String {
        "\(Int(rawValue * 100))%"
    }
}

private func normalizedPreviewPageRotation(_ value: Int) -> Int {
    let normalized = value % 360
    return normalized >= 0 ? normalized : normalized + 360
}

private func rotatedPreviewImage(from image: NSImage, quarterTurns: Int) -> NSImage {
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

    return NSImage(cgImage: rotatedCGImage, size: NSSize(width: destinationSize.width, height: destinationSize.height))
}

final class InvoicePreviewPaneContainerView: NSView {
    private enum ContentKey: Equatable {
        case loading
        case error(title: String, message: String)
        case pdf(ObjectIdentifier)
        case image(ObjectIdentifier)
    }

    private let zoomLabel = NSTextField(labelWithString: "Zoom")
    private let fitButton = NSButton(title: "Fit", target: nil, action: nil)
    private let zoomPresetButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let zoomOutButton = NSButton(title: "", target: nil, action: nil)
    private let zoomInButton = NSButton(title: "", target: nil, action: nil)
    private let rotateLeftButton = NSButton(title: "", target: nil, action: nil)
    private let rotateRightButton = NSButton(title: "", target: nil, action: nil)
    private let hintLabel = NSTextField(labelWithString: "Pinch to zoom or drag below to resize")
    private let contentContainer = NSView()
    private let progressIndicator = NSProgressIndicator()
    private let statusTitleLabel = NSTextField(labelWithString: "")
    private let statusMessageLabel = NSTextField(labelWithString: "")
    private let statusIconView = NSImageView()
    private let statusStackView = NSStackView()

    private let pdfView = PDFView()
    private let imageScrollView = NSScrollView()
    private let imageDocumentView = TopAlignedImageDocumentView()

    private var currentAsset: PreviewAsset?
    private var currentImage: NSImage?
    private var renderedImage: NSImage?
    private var currentZoomScale = 1.0
    private var currentZoomToFit = true
    private var currentRotationQuarterTurns = 0
    private var appliedRotationQuarterTurns: Int?
    private var currentContentKey: ContentKey?
    private var shouldResetImageScrollPosition = false

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
        applyZoom(zoomScale: currentZoomScale, zoomToFit: currentZoomToFit)
    }

    func configureActions(
        target: AnyObject,
        fitAction: Selector,
        zoomPresetAction: Selector,
        zoomOutAction: Selector,
        zoomInAction: Selector,
        rotateLeftAction: Selector,
        rotateRightAction: Selector
    ) {
        fitButton.target = target
        fitButton.action = fitAction
        zoomPresetButton.target = target
        zoomPresetButton.action = zoomPresetAction
        zoomOutButton.target = target
        zoomOutButton.action = zoomOutAction
        zoomInButton.target = target
        zoomInButton.action = zoomInAction
        rotateLeftButton.target = target
        rotateLeftButton.action = rotateLeftAction
        rotateRightButton.target = target
        rotateRightButton.action = rotateRightAction
    }

    func render(_ content: PreviewContent) {
        let key = contentKey(for: content)
        guard key != currentContentKey else { return }
        currentContentKey = key

        switch content {
        case .loading:
            showLoading()
        case .error(let title, let message):
            showError(title: title, message: message)
        case .asset(let asset):
            show(asset: asset)
        }
    }

    func updateControls(zoomScale: Double, zoomToFit: Bool, rotationQuarterTurns: Int) {
        currentZoomScale = zoomScale
        currentZoomToFit = zoomToFit
        currentRotationQuarterTurns = normalizedPreviewRotationQuarterTurns(rotationQuarterTurns)

        fitButton.state = zoomToFit ? .on : .off

        if zoomToFit {
            zoomPresetButton.selectItem(withTitle: "Fit")
        } else {
            let title = "\(Int((zoomScale * 100).rounded()))%"
            if zoomPresetButton.itemTitles.contains(title) {
                zoomPresetButton.selectItem(withTitle: title)
            } else {
                zoomPresetButton.selectItem(withTitle: "Fit")
            }
        }
    }

    func applyPreviewState(zoomScale: Double, zoomToFit: Bool, rotationQuarterTurns: Int) {
        currentRotationQuarterTurns = normalizedPreviewRotationQuarterTurns(rotationQuarterTurns)
        applyRotation()
        applyZoom(zoomScale: zoomScale, zoomToFit: zoomToFit)
    }

    private func contentKey(for content: PreviewContent) -> ContentKey {
        switch content {
        case .loading:
            return .loading
        case .error(let title, let message):
            return .error(title: title, message: message)
        case .asset(.pdf(let document)):
            return .pdf(ObjectIdentifier(document))
        case .asset(.image(let image)):
            return .image(ObjectIdentifier(image))
        }
    }

    private func showLoading() {
        currentAsset = nil
        currentImage = nil
        renderedImage = nil
        shouldResetImageScrollPosition = false
        appliedRotationQuarterTurns = nil
        progressIndicator.startAnimation(nil)
        progressIndicator.isHidden = false
        statusIconView.isHidden = true
        statusTitleLabel.stringValue = "Loading Preview..."
        statusMessageLabel.stringValue = ""
        statusMessageLabel.isHidden = true
        statusStackView.isHidden = false
        pdfView.isHidden = true
        imageScrollView.isHidden = true
    }

    private func showError(title: String, message: String) {
        currentAsset = nil
        currentImage = nil
        renderedImage = nil
        shouldResetImageScrollPosition = false
        appliedRotationQuarterTurns = nil
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        statusIconView.isHidden = false
        statusIconView.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        statusTitleLabel.stringValue = title
        statusMessageLabel.stringValue = message
        statusMessageLabel.isHidden = false
        statusStackView.isHidden = false
        pdfView.isHidden = true
        imageScrollView.isHidden = true
    }

    private func show(asset: PreviewAsset) {
        currentAsset = asset
        appliedRotationQuarterTurns = nil
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        statusStackView.isHidden = true

        switch asset {
        case .pdf(let document):
            shouldResetImageScrollPosition = false
            pdfView.document = document
            pdfView.isHidden = false
            imageScrollView.isHidden = true
            currentImage = nil
            renderedImage = nil
        case .image(let image):
            currentImage = image
            renderedImage = nil
            shouldResetImageScrollPosition = true
            imageScrollView.isHidden = false
            pdfView.isHidden = true
        }
    }

    private func applyZoom(zoomScale: Double, zoomToFit: Bool) {
        currentZoomScale = zoomScale
        currentZoomToFit = zoomToFit

        switch currentAsset {
        case .pdf:
            applyPDFZoom(zoomScale: zoomScale, zoomToFit: zoomToFit)
        case .image:
            applyImageZoom(zoomScale: zoomScale, zoomToFit: zoomToFit)
        case nil:
            break
        }
    }

    private func setup() {
        wantsLayer = true

        zoomLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        zoomPresetButton.removeAllItems()
        zoomPresetButton.addItem(withTitle: "Fit")
        for preset in PreviewZoomPreset.allCases {
            zoomPresetButton.addItem(withTitle: preset.label)
            zoomPresetButton.lastItem?.representedObject = NSNumber(value: preset.rawValue)
        }

        configureButton(zoomOutButton, symbol: "minus.magnifyingglass")
        configureButton(zoomInButton, symbol: "plus.magnifyingglass")
        configureButton(rotateLeftButton, symbol: "rotate.left")
        configureButton(rotateRightButton, symbol: "rotate.right")

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor

        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        contentContainer.layer?.cornerRadius = 12
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .regular

        statusTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusMessageLabel.font = .systemFont(ofSize: 13)
        statusMessageLabel.textColor = .secondaryLabelColor
        statusMessageLabel.lineBreakMode = .byWordWrapping
        statusMessageLabel.maximumNumberOfLines = 2
        statusMessageLabel.alignment = .center

        statusStackView.orientation = .vertical
        statusStackView.alignment = .centerX
        statusStackView.spacing = 10
        statusStackView.translatesAutoresizingMaskIntoConstraints = false
        statusStackView.addArrangedSubview(progressIndicator)
        statusStackView.addArrangedSubview(statusIconView)
        statusStackView.addArrangedSubview(statusTitleLabel)
        statusStackView.addArrangedSubview(statusMessageLabel)

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .windowBackgroundColor
        pdfView.minScaleFactor = 0.25
        pdfView.maxScaleFactor = 8.0
        pdfView.isHidden = true

        imageScrollView.translatesAutoresizingMaskIntoConstraints = false
        imageScrollView.drawsBackground = false
        imageScrollView.hasVerticalScroller = true
        imageScrollView.hasHorizontalScroller = true
        imageScrollView.autohidesScrollers = true
        imageScrollView.documentView = imageDocumentView
        imageScrollView.isHidden = true

        let controlsStack = NSStackView()
        controlsStack.orientation = .horizontal
        controlsStack.alignment = .centerY
        controlsStack.spacing = 8
        controlsStack.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.translatesAutoresizingMaskIntoConstraints = false

        controlsStack.addArrangedSubview(zoomLabel)
        controlsStack.addArrangedSubview(fitButton)
        controlsStack.addArrangedSubview(zoomPresetButton)
        controlsStack.addArrangedSubview(zoomOutButton)
        controlsStack.addArrangedSubview(zoomInButton)
        controlsStack.addArrangedSubview(rotateLeftButton)
        controlsStack.addArrangedSubview(rotateRightButton)
        controlsStack.addArrangedSubview(spacer)
        controlsStack.addArrangedSubview(hintLabel)

        addSubview(controlsStack)
        addSubview(contentContainer)
        contentContainer.addSubview(pdfView)
        contentContainer.addSubview(imageScrollView)
        contentContainer.addSubview(statusStackView)

        NSLayoutConstraint.activate([
            controlsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            controlsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            controlsStack.topAnchor.constraint(equalTo: topAnchor),

            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: controlsStack.bottomAnchor, constant: 12),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            pdfView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            imageScrollView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            imageScrollView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            imageScrollView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            imageScrollView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            statusStackView.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            statusStackView.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            statusStackView.leadingAnchor.constraint(greaterThanOrEqualTo: contentContainer.leadingAnchor, constant: 24),
            statusStackView.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor, constant: -24)
        ])

        showLoading()
    }

    private func applyPDFZoom(zoomScale: Double, zoomToFit: Bool) {
        guard let document = pdfView.document,
              let page = pdfView.currentPage ?? document.page(at: 0) else {
            return
        }

        let fitScale = fitWidthScale(for: page)
        let effectiveScale = zoomToFit ? fitScale : fitScale * CGFloat(zoomScale)

        pdfView.autoScales = false
        pdfView.scaleFactor = min(max(effectiveScale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
    }

    private func applyImageZoom(zoomScale: Double, zoomToFit: Bool) {
        guard let image = renderedImage ?? currentImage else { return }

        let viewportSize = CGSize(
            width: visibleWidth(for: imageScrollView, fallback: imageScrollView.contentSize.width),
            height: imageScrollView.contentSize.height
        )
        let fitWidth = max(viewportSize.width - 32, 200)
        let fitScale = fitWidth / image.size.width
        let effectiveScale = zoomToFit ? fitScale : fitScale * CGFloat(zoomScale)
        let width = max(image.size.width * effectiveScale, 200)
        let height = max(image.size.height * effectiveScale, 200)

        imageDocumentView.update(
            image: image,
            imageSize: CGSize(width: width, height: height),
            viewportSize: viewportSize
        )

        if shouldResetImageScrollPosition {
            shouldResetImageScrollPosition = false
            let clip = imageScrollView.contentView
            clip.scroll(to: .zero)
            imageScrollView.reflectScrolledClipView(clip)
        }
    }

    private func applyRotation() {
        guard appliedRotationQuarterTurns != currentRotationQuarterTurns else {
            return
        }

        switch currentAsset {
        case .pdf(let document):
            applyPDFRotation(to: document)
        case .image(let image):
            renderedImage = rotatedPreviewImage(from: image, quarterTurns: currentRotationQuarterTurns)
        case nil:
            break
        }

        appliedRotationQuarterTurns = currentRotationQuarterTurns
    }

    private func applyPDFRotation(to sourceDocument: PDFDocument) {
        guard let data = sourceDocument.dataRepresentation(),
              let rotatedDocument = PDFDocument(data: data) else {
            pdfView.document = sourceDocument
            return
        }

        let rotationDelta = -currentRotationQuarterTurns * 90
        for pageIndex in 0..<rotatedDocument.pageCount {
            guard let page = rotatedDocument.page(at: pageIndex) else { continue }
            page.rotation = normalizedPreviewPageRotation(page.rotation + rotationDelta)
        }

        let currentPageIndex = max(pdfView.document.flatMap { existing in
            pdfView.currentPage.map { existing.index(for: $0) }
        } ?? 0, 0)

        pdfView.document = rotatedDocument
        if let page = rotatedDocument.page(at: min(currentPageIndex, max(rotatedDocument.pageCount - 1, 0))) {
            pdfView.go(to: page)
        }
    }

    private func fitWidthScale(for page: PDFPage) -> CGFloat {
        let availableWidth = max(visibleWidth(for: pdfView, fallback: pdfView.bounds.width) - 32, 200)
        let pageBounds = page.bounds(for: pdfView.displayBox)
        let pageWidth = max(pageBounds.width, 1)
        return availableWidth / pageWidth
    }

    private func visibleWidth(for view: NSView, fallback: CGFloat) -> CGFloat {
        let width = view.visibleRect.width
        return width > 0 ? width : fallback
    }

    private func configureButton(_ button: NSButton, symbol: String) {
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.setButtonType(.momentaryPushIn)
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

        let canvasWidth = max(viewportSize.width, imageSize.width)
        let canvasHeight = max(viewportSize.height, imageSize.height)
        frame = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)

        let originX = max((canvasWidth - imageSize.width) / 2, 0)
        imageView.frame = NSRect(x: originX, y: 0, width: imageSize.width, height: imageSize.height)
    }
}
