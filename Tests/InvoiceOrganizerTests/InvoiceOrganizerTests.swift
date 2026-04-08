import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import InvoiceOrganizer

private func utcDate(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
    Calendar(identifier: .gregorian).date(
        from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
    )!
}

private func localDateComponents(_ date: Date) -> DateComponents {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    return calendar.dateComponents([.year, .month, .day], from: date)
}

private func documentArtifact(from invoice: PhysicalArtifact) -> DocumentArtifactReference {
    DocumentArtifactReference(
        id: invoice.id,
        fileURL: invoice.fileURL,
        location: invoice.location,
        addedAt: invoice.addedAt,
        fileType: invoice.fileType,
        contentHash: invoice.contentHash
    )
}

private func documentArtifact(from file: ScannedInvoiceFile) -> DocumentArtifactReference {
    DocumentArtifactReference(
        id: file.id,
        fileURL: file.fileURL,
        location: file.location,
        addedAt: file.addedAt,
        fileType: file.fileType,
        contentHash: file.contentHash
    )
}

private func makeDocument(
    visibleArtifacts: [PhysicalArtifact],
    hiddenArtifacts: [DocumentArtifactReference] = [],
    metadata: DocumentMetadata = .empty
) -> Document {
    Document(
        artifacts: visibleArtifacts.map(documentArtifact(from:)) + hiddenArtifacts,
        metadata: metadata
    )
}

private func writePNG(width: Int, height: Int, to url: URL) throws {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

private func writePDF(width: CGFloat, height: CGFloat, to url: URL) throws {
    let data = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)

    guard let consumer = CGDataConsumer(data: data),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }

    context.beginPDFPage(nil)
    context.setFillColor(CGColor(gray: 0.9, alpha: 1))
    context.fill(mediaBox)
    context.endPDFPage()
    context.closePDF()

    try (data as Data).write(to: url)
}

private func imagePixelSize(at url: URL) throws -> CGSize {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
          let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
        throw CocoaError(.fileReadCorruptFile)
    }

    return CGSize(width: width, height: height)
}

@MainActor
private final class TestPreviewAssetProvider: PreviewAssetProviding {
    struct Response {
        let asset: PreviewAsset
        let delay: Duration

        static func success(asset: PreviewAsset, delay: Duration) -> Response {
            Response(asset: asset, delay: delay)
        }
    }

    private let responses: [URL: Response]

    init(responses: [URL: Response]) {
        self.responses = responses
    }

    func asset(
        for handle: ArtifactHandle,
        forceReload: Bool
    ) async throws -> PreviewAsset {
        guard let response = responses[handle.fileURL] else {
            throw CocoaError(.fileNoSuchFile)
        }

        try await Task.sleep(for: response.delay)
        return response.asset
    }

    func invalidateAsset(for handle: ArtifactHandle) {}
}

@MainActor
private final class RecordingPreviewPersistHandler {
    private(set) var requests: [PreviewCommitRequest] = []
    private let delay: Duration

    init(delay: Duration = .zero) {
        self.delay = delay
    }

    func persist(_ request: PreviewCommitRequest) async -> PreviewRotationSaveResult? {
        requests.append(request)
        try? await Task.sleep(for: delay)
        return PreviewRotationSaveResult(contentHash: request.contentHash)
    }
}

@Test func archivePathUsesVendorInitial() async throws {
    let root = URL(fileURLWithPath: "/Processed")

    let destination = ArchivePathBuilder.destinationFolder(root: root, vendor: "Amazon")

    #expect(destination.path == "/Processed/A/Amazon")
}

@Test func archivePathFallsBackToMisc() async throws {
    let root = URL(fileURLWithPath: "/Processed")

    let destination = ArchivePathBuilder.destinationFolder(root: root, vendor: "   ")

    #expect(destination.path == "/Processed/M/Misc")
}

@Test func processedFilenameRoundTripsMetadata() async throws {
    let invoiceDate = utcDate(year: 2024, month: 1, day: 5)
    let processedAt = utcDate(year: 2024, month: 3, day: 30, hour: 6, minute: 24, second: 5)
    let fileURL = URL(fileURLWithPath: "/tmp/invoice.pdf")

    let filename = ArchivePathBuilder.processedFilename(
        vendor: "Amazon",
        invoiceDate: invoiceDate,
        processedAt: processedAt,
        originalFileURL: fileURL
    )

    #expect(filename == "Amazon-2024-01-05-20240330-062405.pdf")

    let parsed = ArchivePathBuilder.processedMetadata(from: URL(fileURLWithPath: "/tmp/\(filename)"))
    #expect(parsed?.vendor == "Amazon")
    #expect(parsed?.invoiceDate == invoiceDate)
    #expect(parsed?.processedAt == processedAt)
}

@Test func scannerRecognizesSupportedExtensions() async throws {
    #expect(InboxFileScanner.isSupportedFile(url: URL(fileURLWithPath: "/tmp/invoice.pdf")))
    #expect(InboxFileScanner.isSupportedFile(url: URL(fileURLWithPath: "/tmp/invoice.HEIC")))
    #expect(InboxFileScanner.isSupportedFile(url: URL(fileURLWithPath: "/tmp/invoice.png")))
    #expect(InboxFileScanner.isSupportedFile(url: URL(fileURLWithPath: "/tmp/invoice.gif")))
    #expect(InboxFileScanner.isSupportedFile(url: URL(fileURLWithPath: "/tmp/invoice.tiff")))
    #expect(!InboxFileScanner.isSupportedFile(url: URL(fileURLWithPath: "/tmp/readme.txt")))
}

@Test func plainRowClickCollapsesMultiSelection() async throws {
    #expect(shouldCollapseSelectionAfterMouseInteraction(row: 2, modifierFlags: [], didBeginDrag: false) == true)
    #expect(shouldCollapseSelectionAfterMouseInteraction(row: 2, modifierFlags: [.command], didBeginDrag: false) == false)
    #expect(shouldCollapseSelectionAfterMouseInteraction(row: 2, modifierFlags: [.shift], didBeginDrag: false) == false)
    #expect(shouldCollapseSelectionAfterMouseInteraction(row: 2, modifierFlags: [], didBeginDrag: true) == false)
    #expect(shouldCollapseSelectionAfterMouseInteraction(row: -1, modifierFlags: [], didBeginDrag: false) == false)
}

@Test func scannerSkipsNestedProcessedFolderFromInboxResults() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    let nestedFolder = tempRoot.appendingPathComponent("Nested", isDirectory: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let inboxInvoiceURL = tempRoot.appendingPathComponent("incoming.pdf")
    let processedInvoiceURL = processedRoot.appendingPathComponent("Amazon-2024-01-05-20240330-062405.pdf")
    let nestedInvoiceURL = nestedFolder.appendingPathComponent("nested.pdf")

    try Data("inbox".utf8).write(to: inboxInvoiceURL)
    try Data("processed".utf8).write(to: processedInvoiceURL)
    try Data("nested".utf8).write(to: nestedInvoiceURL)

    let scannedInboxFiles = try InboxFileScanner.scanFiles(
        in: tempRoot,
        location: .inbox,
        recursive: false,
        excluding: [processedRoot]
    )

    #expect(scannedInboxFiles.map(\.fileURL.lastPathComponent) == ["incoming.pdf"])
}

@Test func workspaceMoverMovesInvoiceIntoProcessingFolder() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let inboxInvoiceURL = tempRoot.appendingPathComponent("incoming.pdf")
    try Data("inbox".utf8).write(to: inboxInvoiceURL)

    let invoice = PhysicalArtifact(
        name: "incoming.pdf",
        fileURL: inboxInvoiceURL,
        location: .inbox,
        addedAt: .now,
        fileType: .pdf,
        status: .unprocessed
    )

    let movedURL = try InvoiceWorkspaceMover.moveToProcessing(invoice, processingRoot: processingRoot)
    #expect(movedURL.deletingLastPathComponent() == processingRoot)
    #expect(movedURL.lastPathComponent == "incoming.pdf")
    #expect(FileManager.default.fileExists(atPath: movedURL.path))
    #expect(!FileManager.default.fileExists(atPath: inboxInvoiceURL.path))
}

@Test func workspaceMoverRenamesProcessingInvoiceFromMetadata() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let processingInvoiceURL = processingRoot.appendingPathComponent("incoming.pdf")
    try Data("inbox".utf8).write(to: processingInvoiceURL)

    let invoice = PhysicalArtifact(
        name: "incoming.pdf",
        fileURL: processingInvoiceURL,
        location: .processing,
        addedAt: .now,
        fileType: .pdf,
        status: .inProgress
    )

    let renamedURL = try InvoiceWorkspaceMover.renameInProcessing(
        invoice,
        vendor: "Amazon",
        invoiceDate: utcDate(year: 2024, month: 1, day: 5),
        invoiceNumber: "INV-42"
    )

    #expect(renamedURL.lastPathComponent == "Amazon-2024-01-05-INV-42.pdf")
    #expect(FileManager.default.fileExists(atPath: renamedURL.path))
    #expect(!FileManager.default.fileExists(atPath: processingInvoiceURL.path))
}

@Test func workspaceMoverMovesInvoiceBackIntoInboxFolder() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let processingInvoiceURL = processingRoot.appendingPathComponent("Amazon-2024-01-05-INV-42.pdf")
    try Data("inbox".utf8).write(to: processingInvoiceURL)

    let invoice = PhysicalArtifact(
        name: processingInvoiceURL.lastPathComponent,
        fileURL: processingInvoiceURL,
        location: .processing,
        vendor: "Amazon",
        invoiceDate: utcDate(year: 2024, month: 1, day: 5),
        invoiceNumber: "INV-42",
        addedAt: .now,
        fileType: .pdf,
        status: .inProgress
    )

    let movedURL = try InvoiceWorkspaceMover.moveToInbox(invoice, inboxRoot: inboxRoot)

    #expect(movedURL.deletingLastPathComponent() == inboxRoot)
    #expect(movedURL.lastPathComponent == "Amazon-2024-01-05-INV-42.pdf")
    #expect(FileManager.default.fileExists(atPath: movedURL.path))
    #expect(!FileManager.default.fileExists(atPath: processingInvoiceURL.path))
}

@Test func previewRotationSaveUpdatesImageWithoutLibraryReload() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let invoiceURL = inboxRoot.appendingPathComponent("incoming.png")
    try writePNG(width: 2, height: 1, to: invoiceURL)

    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(inboxURL: inboxRoot, processedURL: processedRoot, processingURL: processingRoot),
            workflowByID: [:],
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()
    let initialInvoice = try #require(await MainActor.run { model.invoices.first })
    let invoiceID = initialInvoice.id
    let previousContentHash = initialInvoice.contentHash

    let result = await model.persistPreviewRotation(for: invoiceID, quarterTurns: 1)
    let rotatedInvoice = try #require(await MainActor.run { model.invoices.first })

    #expect(result?.contentHash != nil)
    #expect(rotatedInvoice.contentHash == result?.contentHash)
    #expect(rotatedInvoice.contentHash != previousContentHash)
    #expect(try imagePixelSize(at: rotatedInvoice.fileURL) == CGSize(width: 1, height: 2))
}

@Test func previewRotationDraftPersistsAfterMoveUsingRelocatedInvoice() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    let duplicatesRoot = tempRoot.appendingPathComponent("Duplicates", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: duplicatesRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let invoiceURL = inboxRoot.appendingPathComponent("incoming.png")
    try writePNG(width: 2, height: 1, to: invoiceURL)

    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(inboxURL: inboxRoot, processedURL: processedRoot, processingURL: processingRoot, duplicatesURL: duplicatesRoot),
            workflowByID: [:],
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()
    let initialInvoice = try #require(await MainActor.run { model.invoices.first })
    let request = PreviewCommitRequest(invoice: initialInvoice, quarterTurns: 1)

    await MainActor.run {
        model.moveInvoicesToInProgress(ids: [initialInvoice.id])
    }

    await model.reloadLibraryForTesting()
    let result = await model.persistPreviewRotation(for: request)
    let movedInvoice = try #require(await MainActor.run {
        model.invoices.first(where: { $0.location == .processing })
    })

    #expect(result?.contentHash != nil)
    #expect(movedInvoice.contentHash == result?.contentHash)
    #expect(try imagePixelSize(at: movedInvoice.fileURL) == CGSize(width: 1, height: 2))
}

@Test func invoiceFileRotatorRotatesPNGOnDisk() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let imageURL = tempRoot.appendingPathComponent("rotate-me.png")
    try writePNG(width: 2, height: 1, to: imageURL)

    try InvoiceFileRotator.rotateFile(at: imageURL, fileType: .image, quarterTurns: 1)

    #expect(try imagePixelSize(at: imageURL) == CGSize(width: 1, height: 2))
}

@Test func previewRotationSaveRotatesPDFOnDisk() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let invoiceURL = inboxRoot.appendingPathComponent("incoming.pdf")
    try writePDF(width: 200, height: 100, to: invoiceURL)

    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(inboxURL: inboxRoot, processedURL: processedRoot, processingURL: processingRoot),
            workflowByID: [:],
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()
    let initialInvoice = try #require(await MainActor.run { model.invoices.first })

    let result = await model.persistPreviewRotation(for: initialInvoice.id, quarterTurns: 1)
    let rotatedInvoice = try #require(await MainActor.run { model.invoices.first })
    let document = try #require(PDFDocument(url: rotatedInvoice.fileURL))
    let firstPage = try #require(document.page(at: 0))

    #expect(result?.contentHash != nil)
    #expect(rotatedInvoice.contentHash == result?.contentHash)
    #expect(firstPage.rotation == 270)
}

@Test func invoiceFileRotatorKeepsFolderContentsStable() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let imageURL = tempRoot.appendingPathComponent("rotate-me.png")
    try writePNG(width: 2, height: 1, to: imageURL)
    let before = try FileManager.default.contentsOfDirectory(atPath: tempRoot.path).sorted()

    try InvoiceFileRotator.rotateFile(at: imageURL, fileType: .image, quarterTurns: 1)

    let after = try FileManager.default.contentsOfDirectory(atPath: tempRoot.path).sorted()
    #expect(after == before)
}

@MainActor
@Test func previewAssetProviderReloadsAssetWhenContentHashChanges() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let imageURL = tempRoot.appendingPathComponent("reload-me.png")
    try writePNG(width: 2, height: 1, to: imageURL)

    let provider = PreviewAssetProvider()
    let firstHash = try FileHasher.sha256(for: imageURL)
    let firstAsset = try await provider.asset(
        for: imageURL,
        contentHash: firstHash,
        fileType: .image,
        forceReload: false
    )

    try InvoiceFileRotator.rotateFile(at: imageURL, fileType: .image, quarterTurns: 1)
    let secondHash = try FileHasher.sha256(for: imageURL)
    let secondAsset = try await provider.asset(
        for: imageURL,
        contentHash: secondHash,
        fileType: .image,
        forceReload: false
    )

    guard case .image(let firstImage) = firstAsset,
          case .image(let secondImage) = secondAsset else {
        Issue.record("Expected image assets from provider")
        return
    }

    #expect(firstHash != secondHash)
    #expect(firstImage !== secondImage)
}

@MainActor
@Test func previewAssetProviderReturnsFreshPDFDocumentForCachedPDF() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let pdfURL = tempRoot.appendingPathComponent("cached.pdf")
    try writePDF(width: 200, height: 100, to: pdfURL)

    let provider = PreviewAssetProvider()
    let contentHash = try FileHasher.sha256(for: pdfURL)
    let firstAsset = try await provider.asset(
        for: pdfURL,
        contentHash: contentHash,
        fileType: .pdf,
        forceReload: false
    )
    let secondAsset = try await provider.asset(
        for: pdfURL,
        contentHash: contentHash,
        fileType: .pdf,
        forceReload: false
    )

    guard case .pdf(let firstDocument) = firstAsset,
          case .pdf(let secondDocument) = secondAsset else {
        Issue.record("Expected PDF assets from provider")
        return
    }

    #expect(firstDocument !== secondDocument)
    #expect(firstDocument.pageCount == secondDocument.pageCount)
}

@MainActor
@Test func previewViewStateIgnoresStaleLoadAfterSelectionChange() async throws {
    let firstURL = URL(fileURLWithPath: "/tmp/preview-first.png")
    let secondURL = URL(fileURLWithPath: "/tmp/preview-second.png")
    let firstImage = NSImage(size: NSSize(width: 10, height: 10))
    let secondImage = NSImage(size: NSSize(width: 20, height: 10))
    let provider = TestPreviewAssetProvider(
        responses: [
            firstURL: .success(asset: .image(firstImage), delay: .milliseconds(120)),
            secondURL: .success(asset: .image(secondImage), delay: .milliseconds(10))
        ]
    )
    let coordinator = PreviewRotationCoordinator()
    let state = PreviewViewState(assetProvider: provider, rotationCoordinator: coordinator)

    let firstInvoice = PhysicalArtifact(
        name: "first.png",
        fileURL: firstURL,
        location: .inbox,
        addedAt: .now,
        fileType: .image,
        status: .unprocessed,
        contentHash: "first"
    )
    let secondInvoice = PhysicalArtifact(
        name: "second.png",
        fileURL: secondURL,
        location: .inbox,
        addedAt: .now,
        fileType: .image,
        status: .unprocessed,
        contentHash: "second"
    )

    let firstLoad = Task { @MainActor in
        await state.loadPreview(for: firstInvoice)
    }
    try await Task.sleep(for: .milliseconds(20))
    await state.loadPreview(for: secondInvoice)
    await firstLoad.value

    guard case .asset(.image(let image)) = state.content else {
        Issue.record("Expected the latest preview asset to remain visible")
        return
    }

    #expect(image === secondImage)
}

@MainActor
@Test func previewViewStateCommitsDirtyRotationBeforeLoadingNextSelection() async throws {
    let firstURL = URL(fileURLWithPath: "/tmp/rotation-first.png")
    let secondURL = URL(fileURLWithPath: "/tmp/rotation-second.png")
    let provider = TestPreviewAssetProvider(
        responses: [
            firstURL: .success(asset: .image(NSImage(size: NSSize(width: 10, height: 10))), delay: .zero),
            secondURL: .success(asset: .image(NSImage(size: NSSize(width: 20, height: 10))), delay: .zero)
        ]
    )
    let recorder = RecordingPreviewPersistHandler()
    let coordinator = PreviewRotationCoordinator()
    coordinator.persistHandler = recorder.persist
    let state = PreviewViewState(assetProvider: provider, rotationCoordinator: coordinator)

    let firstInvoice = PhysicalArtifact(
        name: "first.png",
        fileURL: firstURL,
        location: .inbox,
        addedAt: .now,
        fileType: .image,
        status: .unprocessed,
        contentHash: "first"
    )
    let secondInvoice = PhysicalArtifact(
        name: "second.png",
        fileURL: secondURL,
        location: .inbox,
        addedAt: .now,
        fileType: .image,
        status: .unprocessed,
        contentHash: "second"
    )

    await state.loadPreview(for: firstInvoice)
    state.rotate(by: 1, for: firstInvoice)
    state.rotate(by: 1, for: firstInvoice)

    await state.loadPreview(for: secondInvoice)
    await coordinator.commitAllPendingRequests()

    #expect(recorder.requests.count == 1)
    #expect(recorder.requests.first?.invoiceID == firstInvoice.id)
    #expect(recorder.requests.first?.quarterTurns == 2)
    #expect(state.rotationQuarterTurns == 0)
}

@MainActor
@Test func previewViewStateLoadsNextSelectionWhilePreviousRotationSavesInBackground() async throws {
    let firstURL = URL(fileURLWithPath: "/tmp/background-rotation-first.png")
    let secondURL = URL(fileURLWithPath: "/tmp/background-rotation-second.png")
    let firstImage = NSImage(size: NSSize(width: 10, height: 10))
    let secondImage = NSImage(size: NSSize(width: 20, height: 10))
    let provider = TestPreviewAssetProvider(
        responses: [
            firstURL: .success(asset: .image(firstImage), delay: .zero),
            secondURL: .success(asset: .image(secondImage), delay: .milliseconds(10))
        ]
    )
    let recorder = RecordingPreviewPersistHandler(delay: .milliseconds(150))
    let coordinator = PreviewRotationCoordinator()
    coordinator.persistHandler = recorder.persist
    let state = PreviewViewState(assetProvider: provider, rotationCoordinator: coordinator)

    let firstInvoice = PhysicalArtifact(
        name: "first.png",
        fileURL: firstURL,
        location: .inbox,
        addedAt: .now,
        fileType: .image,
        status: .unprocessed,
        contentHash: "first"
    )
    let secondInvoice = PhysicalArtifact(
        name: "second.png",
        fileURL: secondURL,
        location: .inbox,
        addedAt: .now,
        fileType: .image,
        status: .unprocessed,
        contentHash: "second"
    )

    await state.loadPreview(for: firstInvoice)
    state.rotate(by: 1, for: firstInvoice)

    let secondLoad = Task { @MainActor in
        await state.loadPreview(for: secondInvoice)
    }

    try await Task.sleep(for: .milliseconds(40))

    guard case .asset(.image(let image)) = state.content else {
        Issue.record("Expected the next selection to render while the previous save is still running")
        return
    }

    #expect(image === secondImage)
    #expect(recorder.requests.count == 1)

    await secondLoad.value
}

@MainActor
@Test func previewViewStateKeepsDoubleRotationAcrossDuplicateNavigation() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let firstURL = inboxRoot.appendingPathComponent("canonical.pdf")
    let duplicateURL = inboxRoot.appendingPathComponent("duplicate.pdf")
    try writePDF(width: 200, height: 100, to: firstURL)
    try FileManager.default.copyItem(at: firstURL, to: duplicateURL)

    let model = AppModel(
        folderSettings: FolderSettings(inboxURL: inboxRoot, processedURL: processedRoot, processingURL: processingRoot),
        workflowByID: [:],
        autoRefresh: false
    )
    await model.reloadLibraryForTesting()

    let invoices = model.invoices.sorted { $0.name < $1.name }
    let firstInvoice = try #require(invoices.first(where: { $0.name == "canonical.pdf" }))
    let duplicateInvoice = try #require(invoices.first(where: { $0.name == "duplicate.pdf" }))

    let coordinator = PreviewRotationCoordinator()
    coordinator.persistHandler = model.persistPreviewRotation(for:)

    let state = PreviewViewState(
        assetProvider: PreviewAssetProvider(),
        rotationCoordinator: coordinator
    )

    await state.loadPreview(for: firstInvoice)
    state.rotate(by: 1, for: firstInvoice)
    state.rotate(by: 1, for: firstInvoice)

    await state.loadPreview(for: duplicateInvoice)
    await coordinator.commitAllPendingRequests()

    let updatedFirstInvoice = try #require(model.invoices.first(where: { $0.id == firstInvoice.id }))
    let rotatedDocument = try #require(PDFDocument(url: updatedFirstInvoice.fileURL))
    let rotatedPage = try #require(rotatedDocument.page(at: 0))

    #expect(rotatedPage.rotation == 180)

    await state.loadPreview(for: updatedFirstInvoice)

    guard case .asset(.pdf(let document)) = state.content,
          let firstPage = document.page(at: 0) else {
        Issue.record("Expected the rotated PDF preview to reload")
        return
    }

    #expect(state.rotationQuarterTurns == 0)
    #expect(firstPage.rotation == 180)
}

@MainActor
@Test func previewRotationCoordinatorFlushesPendingDraftsOnQuit() async throws {
    let recorder = RecordingPreviewPersistHandler()
    let coordinator = PreviewRotationCoordinator()
    coordinator.persistHandler = recorder.persist

    let invoice = PhysicalArtifact(
        name: "draft.png",
        fileURL: URL(fileURLWithPath: "/tmp/draft.png"),
        location: .inbox,
        addedAt: .now,
        fileType: .image,
        status: .unprocessed,
        contentHash: "draft-hash"
    )

    let context = ActivePreviewContext(
        invoice: invoice,
        persistedQuarterTurns: 0,
        rotationSaveStatus: .idle
    )
    var dirtyContext = context
    _ = dirtyContext.rotate(by: 1)
    coordinator.enqueueCommitIfNeeded(from: dirtyContext)
    await coordinator.commitAllPendingRequests()

    #expect(recorder.requests.count == 1)
    #expect(recorder.requests.first?.invoiceID == invoice.id)
    #expect(!coordinator.hasPendingWork)
}

@Test func processingFilesAppearAsInProgress() async throws {
    let file = ScannedInvoiceFile(
        id: "/Processing/incoming.pdf",
        name: "incoming.pdf",
        fileURL: URL(fileURLWithPath: "/Processing/incoming.pdf"),
        location: .processing,
        vendor: nil,
        invoiceDate: nil,
        processedAt: nil,
        addedAt: .now,
        fileType: .pdf,
        contentHash: nil
    )

    let invoice = InboxFileScanner.makeActiveArtifact(from: file, workflow: nil, duplicateInfo: nil)
    #expect(invoice.location == .processing)
    #expect(invoice.status == .inProgress)
}

@Test func inboxFilesIgnoreStaleInProgressWorkflowFlag() async throws {
    let file = ScannedInvoiceFile(
        id: "/Inbox/incoming.pdf",
        name: "incoming.pdf",
        fileURL: URL(fileURLWithPath: "/Inbox/incoming.pdf"),
        location: .inbox,
        vendor: nil,
        invoiceDate: nil,
        processedAt: nil,
        addedAt: .now,
        fileType: .pdf,
        contentHash: nil
    )

    let staleWorkflow = StoredInvoiceWorkflow(vendor: nil, invoiceDate: nil, invoiceNumber: nil, isInProgress: true)
    let invoice = InboxFileScanner.makeActiveArtifact(from: file, workflow: staleWorkflow, duplicateInfo: nil)

    #expect(invoice.location == .inbox)
    #expect(invoice.status == .unprocessed)
}

@Test func dragExportRenamesHEICToJPEG() async throws {
    #expect(DragExportService.jpegExportBasename(for: "invoice.heic") == "invoice")
    #expect(DragExportService.jpegExportBasename(for: "invoice") == "invoice")
    #expect(DragExportService.jpegExportFilename(for: "invoice.heic") == "invoice.jpg")
    #expect(DragExportService.jpegExportFilename(for: "invoice.HEIC") == "invoice.jpg")
    #expect(DragExportService.jpegExportFilename(for: "invoice") == "invoice.jpg")
}

@Test func archiveMovesInvoiceWithCanonicalFilename() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let inboxURL = tempRoot.appendingPathComponent("invoice.pdf")
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    try "one".data(using: .utf8)?.write(to: inboxURL)
    let invoiceDate = utcDate(year: 2024, month: 1, day: 5)
    let processedAt = utcDate(year: 2024, month: 3, day: 30, hour: 6, minute: 24, second: 5)

    let invoice = PhysicalArtifact(
        name: "invoice.pdf",
        fileURL: inboxURL,
        location: .inbox,
        vendor: "Amazon",
        invoiceDate: invoiceDate,
        addedAt: .now,
        fileType: .pdf,
        status: .inProgress
    )

    let archivedURL = try InvoiceArchiver.archive(
        invoice,
        processedRoot: processedRoot,
        vendor: "Amazon",
        invoiceDate: invoiceDate,
        processedAt: processedAt
    )
    #expect(archivedURL.lastPathComponent == "Amazon-2024-01-05-20240330-062405.pdf")
    #expect(FileManager.default.fileExists(atPath: archivedURL.path))
}

@Test func extractedTextDuplicateDetectorSoftBlocksInboxPeerWhenProcessedMemberExists() async throws {
    let processedFile = ScannedInvoiceFile(
        id: "/Processed/A/Amazon/invoice.pdf",
        name: "Amazon-2024-01-05-20240330-062405.pdf",
        fileURL: URL(fileURLWithPath: "/Processed/A/Amazon/invoice.pdf"),
        location: .processed,
        vendor: "Amazon",
        invoiceDate: utcDate(year: 2024, month: 1, day: 5),
        processedAt: utcDate(year: 2024, month: 3, day: 30, hour: 6, minute: 24, second: 5),
        addedAt: utcDate(year: 2024, month: 3, day: 30, hour: 6, minute: 24, second: 5),
        fileType: .pdf,
        contentHash: "processed-hash"
    )

    let inboxFile = ScannedInvoiceFile(
        id: "/Inbox/invoice.pdf",
        name: "invoice.pdf",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice.pdf"),
        location: .inbox,
        vendor: nil,
        invoiceDate: nil,
        processedAt: nil,
        addedAt: Date(timeIntervalSince1970: 1_711_951_999),
        fileType: .pdf,
        contentHash: "inbox-hash"
    )

    let groups = DuplicateDetector.extractedTextDuplicateGroups(
        for: [processedFile, inboxFile],
        textRecordsByContentHash: [
            "processed-hash": InvoiceTextRecord(text: "Amazon\nInvoice INV-42", source: .pdfText),
            "inbox-hash": InvoiceTextRecord(text: "  Amazon  \nInvoice INV-42  ", source: .ocr)
        ]
    )
    let group = try #require(groups.first)
    #expect(groups.count == 1)
    #expect(Set(group.artifactIDs) == Set([processedFile.id, inboxFile.id]))

    let document = Document(
        artifacts: [documentArtifact(from: processedFile), documentArtifact(from: inboxFile)],
        metadata: .empty
    )
    #expect(document.isSoftBlocked(artifactID: inboxFile.id))
    #expect(!document.isSoftBlocked(artifactID: processedFile.id))
    #expect(document.duplicateInfo(forArtifactID: inboxFile.id)?.duplicateOfPath == processedFile.fileURL.path)
}

@Test func extractedTextDuplicateDetectorKeepsAllInboxPeersActionable() async throws {
    let firstInbox = ScannedInvoiceFile(
        id: "/Inbox/invoice-1.pdf",
        name: "invoice.pdf",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice-1.pdf"),
        location: .inbox,
        vendor: nil,
        invoiceDate: nil,
        processedAt: nil,
        addedAt: Date(timeIntervalSince1970: 10),
        fileType: .pdf,
        contentHash: "hash-123"
    )

    let secondInbox = ScannedInvoiceFile(
        id: "/Inbox/invoice-2.pdf",
        name: "invoice.pdf",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice-2.pdf"),
        location: .inbox,
        vendor: nil,
        invoiceDate: nil,
        processedAt: nil,
        addedAt: Date(timeIntervalSince1970: 20),
        fileType: .pdf,
        contentHash: "hash-456"
    )

    let groups = DuplicateDetector.extractedTextDuplicateGroups(
        for: [firstInbox, secondInbox],
        textRecordsByContentHash: [
            "hash-123": InvoiceTextRecord(text: "Vendor: Acme\nInvoice: INV-42", source: .pdfText),
            "hash-456": InvoiceTextRecord(text: "Vendor: Acme\nInvoice: INV-42", source: .ocr)
        ]
    )
    let group = try #require(groups.first)
    #expect(groups.count == 1)
    #expect(Set(group.artifactIDs) == Set([firstInbox.id, secondInbox.id]))

    let document = Document(
        artifacts: [documentArtifact(from: firstInbox), documentArtifact(from: secondInbox)],
        metadata: .empty
    )
    #expect(!document.isSoftBlocked(artifactID: firstInbox.id))
    #expect(!document.isSoftBlocked(artifactID: secondInbox.id))
}

@Test func extractedTextDuplicateDetectorMatchesNearEquivalentOCRText() async throws {
    let firstInbox = ScannedInvoiceFile(
        id: "/Inbox/invoice-a.jpg",
        name: "invoice-a.jpg",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice-a.jpg"),
        location: .inbox,
        vendor: nil,
        invoiceDate: nil,
        processedAt: nil,
        addedAt: Date(timeIntervalSince1970: 10),
        fileType: .jpeg,
        contentHash: "hash-a"
    )

    let secondInbox = ScannedInvoiceFile(
        id: "/Inbox/invoice-b.heic",
        name: "invoice-b.heic",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice-b.heic"),
        location: .inbox,
        vendor: nil,
        invoiceDate: nil,
        processedAt: nil,
        addedAt: Date(timeIntervalSince1970: 20),
        fileType: .heic,
        contentHash: "hash-b"
    )

    let groups = DuplicateDetector.extractedTextDuplicateGroups(
        for: [firstInbox, secondInbox],
        textRecordsByContentHash: [
            "hash-a": InvoiceTextRecord(
                text: "Amazon invoice INV-42 date 2024-01-05 total 123.45",
                source: .ocr
            ),
            "hash-b": InvoiceTextRecord(
                text: "amazon invoice inv 42 date 2024 01 05 total 123 45",
                source: .ocr
            )
        ]
    )
    #expect(groups.count == 1)
    #expect(groups.first.map { Set($0.artifactIDs) } == Set([firstInbox.id, secondInbox.id]))
}

@Test func extractedTextDuplicateDetectorMatchesAgainstExistingDocumentMembers() async throws {
    let firstInbox = ScannedInvoiceFile(
        id: "/Inbox/invoice-a.pdf",
        name: "invoice-a.pdf",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice-a.pdf"),
        location: .inbox,
        vendor: nil,
        invoiceDate: nil,
        processedAt: nil,
        addedAt: Date(timeIntervalSince1970: 10),
        fileType: .pdf,
        contentHash: "hash-a"
    )
    let secondInbox = ScannedInvoiceFile(
        id: "/Inbox/invoice-b.pdf",
        name: "invoice-b.pdf",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice-b.pdf"),
        location: .inbox,
        vendor: nil,
        invoiceDate: nil,
        processedAt: nil,
        addedAt: Date(timeIntervalSince1970: 20),
        fileType: .pdf,
        contentHash: "hash-b"
    )
    let thirdInbox = ScannedInvoiceFile(
        id: "/Inbox/invoice-c.pdf",
        name: "invoice-c.pdf",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice-c.pdf"),
        location: .inbox,
        vendor: nil,
        invoiceDate: nil,
        processedAt: nil,
        addedAt: Date(timeIntervalSince1970: 30),
        fileType: .pdf,
        contentHash: "hash-c"
    )

    let groups = DuplicateDetector.extractedTextDuplicateGroups(
        for: [firstInbox, secondInbox, thirdInbox],
        textRecordsByContentHash: [
            "hash-a": InvoiceTextRecord(
                text: (1...20).map { "token\($0)" }.joined(separator: " "),
                source: .pdfText
            ),
            "hash-b": InvoiceTextRecord(
                text: (1...19).map { "token\($0)" }.joined(separator: " ") + " token21",
                source: .pdfText
            ),
            "hash-c": InvoiceTextRecord(
                text: (1...18).map { "token\($0)" }.joined(separator: " ") + " token21 token22",
                source: .pdfText
            )
        ]
    )

    #expect(groups.count == 1)
    #expect(groups.first.map { Set($0.artifactIDs) } == Set([firstInbox.id, secondInbox.id, thirdInbox.id]))
}

@Test func extractedTextDuplicateGroupPrefersJPEGPeerAsReference() async throws {
    let heicInbox = ScannedInvoiceFile(
        id: "/Inbox/invoice.heic",
        name: "invoice.heic",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice.heic"),
        location: .inbox,
        vendor: nil,
        invoiceDate: nil,
        processedAt: nil,
        addedAt: Date(timeIntervalSince1970: 10),
        fileType: .heic,
        contentHash: "hash-heic"
    )

    let jpegInbox = ScannedInvoiceFile(
        id: "/Inbox/invoice.jpg",
        name: "invoice.jpg",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice.jpg"),
        location: .inbox,
        vendor: nil,
        invoiceDate: nil,
        processedAt: nil,
        addedAt: Date(timeIntervalSince1970: 20),
        fileType: .jpeg,
        contentHash: "hash-jpeg"
    )

    let groups = DuplicateDetector.extractedTextDuplicateGroups(
        for: [heicInbox, jpegInbox],
        textRecordsByContentHash: [
            "hash-heic": InvoiceTextRecord(text: "Amazon invoice INV-42 date 2024-01-05 total 123.45", source: .ocr),
            "hash-jpeg": InvoiceTextRecord(text: "amazon invoice inv 42 date 2024 01 05 total 123 45", source: .ocr)
        ]
    )
    let group = try #require(groups.first)
    #expect(groups.count == 1)
    #expect(Set(group.artifactIDs) == Set([heicInbox.id, jpegInbox.id]))

    let document = Document(
        artifacts: [documentArtifact(from: heicInbox), documentArtifact(from: jpegInbox)],
        metadata: .empty
    )
    #expect(document.referenceArtifact(for: heicInbox.id)?.fileURL.path == jpegInbox.fileURL.path)
}

@Test func browserRowsCollapseAndExpandDuplicateGroups() async throws {
    let first = PhysicalArtifact(
        name: "invoice.pdf",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice.pdf"),
        location: .inbox,
        addedAt: Date(timeIntervalSince1970: 10),
        fileType: .pdf,
        status: .unprocessed
    )
    let duplicateA = PhysicalArtifact(
        name: "invoice-copy-1.pdf",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice-copy-1.pdf"),
        location: .inbox,
        addedAt: Date(timeIntervalSince1970: 9),
        fileType: .pdf,
        status: .blockedDuplicate,
        duplicateOfPath: first.fileURL.path,
        duplicateReason: "Duplicate extracted text matches invoice.pdf"
    )
    let duplicateB = PhysicalArtifact(
        name: "invoice-copy-2.pdf",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice-copy-2.pdf"),
        location: .inbox,
        addedAt: Date(timeIntervalSince1970: 8),
        fileType: .pdf,
        status: .blockedDuplicate,
        duplicateOfPath: first.fileURL.path,
        duplicateReason: "Duplicate extracted text matches invoice.pdf"
    )

    let group = makeDocument(visibleArtifacts: [first, duplicateA, duplicateB])
    let collapsedRows = buildInvoiceBrowserRows(
        from: [first, duplicateA, duplicateB],
        documents: [group],
        expandedGroupIDs: []
    )
    #expect(collapsedRows.count == 1)
    #expect(collapsedRows.first?.kind == .groupHeader(duplicateCount: 2))
    #expect(collapsedRows.first?.disclosureState == .collapsed)

    let expandedRows = buildInvoiceBrowserRows(
        from: [first, duplicateA, duplicateB],
        documents: [group],
        expandedGroupIDs: [first.id]
    )
    #expect(expandedRows.count == 3)
    #expect(expandedRows[0].kind == .groupHeader(duplicateCount: 2))
    #expect(expandedRows[0].disclosureState == .expanded)
    #expect(expandedRows[1].kind == .groupChild(parentID: first.id))
    #expect(expandedRows[2].kind == .groupChild(parentID: first.id))
}

@Test func disclosureNavigationExpandsAndCollapsesGroupHeaders() async throws {
    let canonical = PhysicalArtifact(
        name: "invoice.pdf",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice.pdf"),
        location: .inbox,
        addedAt: Date(timeIntervalSince1970: 10),
        fileType: .pdf,
        status: .unprocessed
    )

    let collapsedHeader = InvoiceBrowserRow(
        invoice: canonical,
        kind: .groupHeader(duplicateCount: 2),
        artifactIDs: Set([canonical.id]),
        indentationLevel: 0,
        disclosureState: .collapsed
    )
    let expandedHeader = InvoiceBrowserRow(
        invoice: canonical,
        kind: .groupHeader(duplicateCount: 2),
        artifactIDs: Set([canonical.id]),
        indentationLevel: 0,
        disclosureState: .expanded
    )

    #expect(disclosureNavigationAction(for: collapsedHeader, keyCode: 124) == .expand(canonical.id))
    #expect(disclosureNavigationAction(for: expandedHeader, keyCode: 123) == .collapse(canonical.id))
}

@Test func disclosureNavigationMovesChildSelectionToParent() async throws {
    let canonical = PhysicalArtifact(
        name: "invoice.pdf",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice.pdf"),
        location: .inbox,
        addedAt: Date(timeIntervalSince1970: 10),
        fileType: .pdf,
        status: .unprocessed
    )
    let duplicate = PhysicalArtifact(
        name: "invoice-copy.pdf",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice-copy.pdf"),
        location: .inbox,
        addedAt: Date(timeIntervalSince1970: 8),
        fileType: .pdf,
        status: .blockedDuplicate,
        duplicateOfPath: canonical.fileURL.path,
        duplicateReason: "Duplicate extracted text matches invoice.pdf"
    )

    let childRow = InvoiceBrowserRow(
        invoice: duplicate,
        kind: .groupChild(parentID: canonical.id),
        artifactIDs: Set([duplicate.id]),
        indentationLevel: 1,
        disclosureState: .hidden
    )

    #expect(disclosureNavigationAction(for: childRow, keyCode: 123) == .selectParent(canonical.id))
    #expect(disclosureNavigationAction(for: childRow, keyCode: 124) == nil)
}

@Test func browserRowsLeaveSingleOrphanDuplicateUngroupedWhenCanonicalHidden() async throws {
    let orphanDuplicate = PhysicalArtifact(
        name: "invoice-copy.pdf",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice-copy.pdf"),
        location: .inbox,
        addedAt: Date(timeIntervalSince1970: 8),
        fileType: .pdf,
        status: .blockedDuplicate,
        duplicateOfPath: "/Processed/A/Amazon/invoice.pdf",
        duplicateReason: "Duplicate extracted text matches invoice.pdf"
    )

    let rows = buildInvoiceBrowserRows(
        from: [orphanDuplicate],
        documents: [
            Document(
                artifacts: [
                    documentArtifact(from: orphanDuplicate),
                    DocumentArtifactReference(
                        id: "/Processed/A/Amazon/invoice.pdf",
                        fileURL: URL(fileURLWithPath: "/Processed/A/Amazon/invoice.pdf"),
                        location: .processed,
                        addedAt: Date(timeIntervalSince1970: 1),
                        fileType: .pdf,
                        contentHash: nil
                    )
                ],
                metadata: .empty
            )
        ],
        expandedGroupIDs: []
    )
    #expect(rows.count == 1)
    #expect(rows[0].kind == .invoice)
    #expect(rows[0].invoice.id == orphanDuplicate.id)
}

@Test func browserRowsGroupVisibleDuplicatesWhenCanonicalIsHidden() async throws {
    let duplicateA = PhysicalArtifact(
        name: "invoice-copy-a.pdf",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice-copy-a.pdf"),
        location: .inbox,
        addedAt: Date(timeIntervalSince1970: 9),
        fileType: .pdf,
        status: .blockedDuplicate,
        duplicateOfPath: "/Processed/A/Amazon/invoice.pdf",
        duplicateReason: "Duplicate extracted text matches invoice.pdf"
    )
    let duplicateB = PhysicalArtifact(
        name: "invoice-copy-b.pdf",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice-copy-b.pdf"),
        location: .inbox,
        addedAt: Date(timeIntervalSince1970: 8),
        fileType: .pdf,
        status: .blockedDuplicate,
        duplicateOfPath: "/Processed/A/Amazon/invoice.pdf",
        duplicateReason: "Duplicate extracted text matches invoice.pdf"
    )

    let hiddenProcessedPeer = DocumentArtifactReference(
        id: "/Processed/A/Amazon/invoice.pdf",
        fileURL: URL(fileURLWithPath: "/Processed/A/Amazon/invoice.pdf"),
        location: .processed,
        addedAt: Date(timeIntervalSince1970: 1),
        fileType: .pdf,
        contentHash: nil
    )
    let group = makeDocument(visibleArtifacts: [duplicateA, duplicateB], hiddenArtifacts: [hiddenProcessedPeer])
    let collapsedRows = buildInvoiceBrowserRows(
        from: [duplicateA, duplicateB],
        documents: [group],
        expandedGroupIDs: []
    )
    #expect(collapsedRows.count == 1)
    #expect(collapsedRows[0].invoice.id == duplicateA.id)
    #expect(collapsedRows[0].kind == .groupHeader(duplicateCount: 1))
    #expect(collapsedRows[0].artifactIDs == Set([duplicateA.id, duplicateB.id]))

    let expandedRows = buildInvoiceBrowserRows(
        from: [duplicateA, duplicateB],
        documents: [group],
        expandedGroupIDs: [duplicateA.id]
    )
    #expect(expandedRows.count == 2)
    #expect(expandedRows[0].kind == .groupHeader(duplicateCount: 1))
    #expect(expandedRows[1].kind == .groupChild(parentID: duplicateA.id))
    #expect(expandedRows[1].invoice.id == duplicateB.id)
}

@Test func duplicateGroupHeaderBadgeTitleShowsProcessedStateInUnprocessedQueue() async throws {
    let duplicateA = PhysicalArtifact(
        name: "invoice-copy-a.pdf",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice-copy-a.pdf"),
        location: .inbox,
        addedAt: Date(timeIntervalSince1970: 9),
        fileType: .pdf,
        status: .blockedDuplicate
    )
    let duplicateB = PhysicalArtifact(
        name: "invoice-copy-b.pdf",
        fileURL: URL(fileURLWithPath: "/Inbox/invoice-copy-b.pdf"),
        location: .inbox,
        addedAt: Date(timeIntervalSince1970: 8),
        fileType: .pdf,
        status: .blockedDuplicate
    )
    let row = InvoiceBrowserRow(
        invoice: duplicateA,
        kind: .groupHeader(duplicateCount: 1),
        artifactIDs: Set([duplicateA.id, duplicateB.id]),
        indentationLevel: 0,
        disclosureState: .collapsed
    )
    let duplicateDocument = makeDocument(
        visibleArtifacts: [duplicateA, duplicateB],
        hiddenArtifacts: [
            DocumentArtifactReference(
                id: "/Processed/A/Amazon/invoice.pdf",
                fileURL: URL(fileURLWithPath: "/Processed/A/Amazon/invoice.pdf"),
                location: .processed,
                addedAt: Date(timeIntervalSince1970: 1),
                fileType: .pdf,
                contentHash: nil
            )
        ]
    )

    let title = duplicateGroupHeaderBadgeTitle(
        for: row,
        duplicateCount: 1,
        documents: [duplicateDocument],
        queueTab: .unprocessed
    )

    #expect(title == "1 Duplicate - processed")
}

@Test func appModelPopulatesDuplicateDocumentMetadataWhenStructuredDataAgrees() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    let duplicatesRoot = tempRoot.appendingPathComponent("Duplicates", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: duplicatesRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let firstInvoiceURL = inboxRoot.appendingPathComponent("incoming-1.pdf")
    let secondInvoiceURL = inboxRoot.appendingPathComponent("incoming-2.pdf")
    try Data("first-file-body".utf8).write(to: firstInvoiceURL)
    try Data("second-file-body".utf8).write(to: secondInvoiceURL)

    let sharedText = InvoiceTextRecord(text: "Vendor: Acme Corp\nInvoice: INV-42", source: .pdfText)
    let textStore = InMemoryInvoiceTextStore()
    let structuredStore = InMemoryInvoiceStructuredDataStore()
    let firstHash = try FileHasher.sha256(for: firstInvoiceURL)
    let secondHash = try FileHasher.sha256(for: secondInvoiceURL)
    await textStore.save(sharedText, forContentHash: firstHash)
    await textStore.save(sharedText, forContentHash: secondHash)
    await structuredStore.save(
        InvoiceStructuredDataRecord(
            companyName: "Acme Corp",
            invoiceNumber: "INV-42",
            invoiceDate: utcDate(year: 2024, month: 1, day: 5),
            documentType: .invoice,
            provider: .lmStudio,
            modelName: "qwen-local"
        ),
        forContentHash: firstHash
    )
    await structuredStore.save(
        InvoiceStructuredDataRecord(
            companyName: "Acme Corp",
            invoiceNumber: "INV-42",
            invoiceDate: utcDate(year: 2024, month: 1, day: 5),
            documentType: .invoice,
            provider: .lmStudio,
            modelName: "qwen-local"
        ),
        forContentHash: secondHash
    )

    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(
                inboxURL: inboxRoot,
                processedURL: processedRoot,
                processingURL: processingRoot,
                duplicatesURL: duplicatesRoot
            ),
            workflowByID: [:],
            textStore: textStore,
            textExtractor: MockDocumentTextExtractor(),
            structuredDataStore: structuredStore,
            structuredExtractionClient: MockStructuredExtractionClient(),
            llmSettings: LLMSettings(provider: .lmStudio, baseURL: "", modelName: "", apiKey: "", customInstructions: ""),
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()

    let duplicateDocuments = await MainActor.run { model.documents.filter(\.isDuplicate) }
    let visibleArtifacts = await MainActor.run { model.invoices.filter { $0.location == .inbox } }
    let visibleMetadata = await MainActor.run { visibleArtifacts.map { model.documentMetadata(for: $0.id) } }

    #expect(duplicateDocuments.count == 1)
    #expect(duplicateDocuments.first?.metadata.vendor == "Acme Corp")
    #expect(duplicateDocuments.first?.metadata.invoiceNumber == "INV-42")
    #expect(duplicateDocuments.first?.metadata.invoiceDate == utcDate(year: 2024, month: 1, day: 5))
    #expect(visibleMetadata.allSatisfy { $0.vendor == "Acme Corp" })
    #expect(visibleMetadata.allSatisfy { $0.invoiceNumber == "INV-42" })
}

@Test func appModelReportsDedupSimilarityScoresForInvoice() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    let duplicatesRoot = tempRoot.appendingPathComponent("Duplicates", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: duplicatesRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let firstInvoiceURL = inboxRoot.appendingPathComponent("incoming-1.pdf")
    let secondInvoiceURL = inboxRoot.appendingPathComponent("incoming-2.pdf")
    let thirdInvoiceURL = inboxRoot.appendingPathComponent("incoming-3.pdf")
    try Data("first".utf8).write(to: firstInvoiceURL)
    try Data("second".utf8).write(to: secondInvoiceURL)
    try Data("third".utf8).write(to: thirdInvoiceURL)

    let textStore = InMemoryInvoiceTextStore()
    await textStore.save(InvoiceTextRecord(text: "alpha beta gamma delta", source: .pdfText), forContentHash: try FileHasher.sha256(for: firstInvoiceURL))
    await textStore.save(InvoiceTextRecord(text: "alpha beta gamma epsilon", source: .pdfText), forContentHash: try FileHasher.sha256(for: secondInvoiceURL))
    await textStore.save(InvoiceTextRecord(text: "alpha beta zeta eta", source: .pdfText), forContentHash: try FileHasher.sha256(for: thirdInvoiceURL))

    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(
                inboxURL: inboxRoot,
                processedURL: processedRoot,
                processingURL: processingRoot,
                duplicatesURL: duplicatesRoot
            ),
            workflowByID: [:],
            textStore: textStore,
            textExtractor: MockDocumentTextExtractor(),
            llmSettings: LLMSettings(provider: .lmStudio, baseURL: "", modelName: "", apiKey: "", customInstructions: ""),
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()

    let invoiceID = try #require(await MainActor.run {
        model.invoices.first(where: { $0.name == "incoming-1.pdf" })?.id
    })
    let similarities = await MainActor.run {
        model.duplicateSimilarities(for: invoiceID)
    }

    #expect(similarities.count == 2)
    #expect(similarities[0].matchedFileURL.lastPathComponent == "incoming-2.pdf")
    #expect(abs(similarities[0].score - 0.6) < 0.0001)
    #expect(similarities[0].meetsThreshold == false)
    #expect(similarities[0].artifactCount == 1)
    #expect(similarities[1].matchedFileURL.lastPathComponent == "incoming-3.pdf")
    #expect(abs(similarities[1].score - (2.0 / 6.0)) < 0.0001)
}

@Test func appModelBuildsDistinctSingletonDocumentsForMatchingContentHashes() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    let duplicatesRoot = tempRoot.appendingPathComponent("Duplicates", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: duplicatesRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let firstInvoiceURL = inboxRoot.appendingPathComponent("incoming-1.pdf")
    let secondInvoiceURL = inboxRoot.appendingPathComponent("incoming-2.pdf")
    let sharedBytes = Data("same-file-body".utf8)
    try sharedBytes.write(to: firstInvoiceURL)
    try sharedBytes.write(to: secondInvoiceURL)

    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(
                inboxURL: inboxRoot,
                processedURL: processedRoot,
                processingURL: processingRoot,
                duplicatesURL: duplicatesRoot
            ),
            workflowByID: [:],
            textStore: InMemoryInvoiceTextStore(),
            textExtractor: MockDocumentTextExtractor(),
            llmSettings: LLMSettings(provider: .lmStudio, baseURL: "", modelName: "", apiKey: "", customInstructions: ""),
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()

    let documents = await MainActor.run { model.documents }
    #expect(documents.count == 2)
    #expect(Set(documents.map(\.id)).count == 2)
}

@Test func appModelManualDocumentEditUpdatesAllChildren() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    let duplicatesRoot = tempRoot.appendingPathComponent("Duplicates", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: duplicatesRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let firstInvoiceURL = processedRoot.appendingPathComponent("doc-1.pdf")
    let secondInvoiceURL = processedRoot.appendingPathComponent("doc-2.pdf")
    try Data("first-file-body".utf8).write(to: firstInvoiceURL)
    try Data("second-file-body".utf8).write(to: secondInvoiceURL)

    let sharedText = InvoiceTextRecord(text: "Vendor: Acme Corp\nInvoice: INV-42", source: .pdfText)
    let textStore = InMemoryInvoiceTextStore()
    await textStore.save(sharedText, forContentHash: try FileHasher.sha256(for: firstInvoiceURL))
    await textStore.save(sharedText, forContentHash: try FileHasher.sha256(for: secondInvoiceURL))

    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(
                inboxURL: inboxRoot,
                processedURL: processedRoot,
                processingURL: processingRoot,
                duplicatesURL: duplicatesRoot
            ),
            workflowByID: [:],
            textStore: textStore,
            textExtractor: MockDocumentTextExtractor(),
            llmSettings: LLMSettings(provider: .lmStudio, baseURL: "", modelName: "", apiKey: "", customInstructions: ""),
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()

    let processedIDs = try #require(await MainActor.run {
        let ids = model.invoices.filter { $0.location == .processed }.map(\.id).sorted()
        return ids.count == 2 ? ids : nil
    })

    await MainActor.run {
        model.updateInvoiceNumber("DOC-42", for: processedIDs[0])
    }

    let processedInvoices = await MainActor.run { model.invoices.filter { $0.location == .processed } }
    let processedMetadata = await MainActor.run { processedInvoices.map { model.documentMetadata(for: $0.id) } }
    let document = try #require(await MainActor.run {
        model.document(for: processedIDs[0])
    })

    #expect(processedMetadata.allSatisfy { $0.invoiceNumber == "DOC-42" })
    #expect(document.metadata.invoiceNumber == "DOC-42")
}

@Test func appModelPartialDocumentRescanKeepsMetadata() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    let duplicatesRoot = tempRoot.appendingPathComponent("Duplicates", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: duplicatesRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let firstInvoiceURL = processedRoot.appendingPathComponent("doc-1.pdf")
    let secondInvoiceURL = processedRoot.appendingPathComponent("doc-2.pdf")
    try Data("first-file-body".utf8).write(to: firstInvoiceURL)
    try Data("second-file-body".utf8).write(to: secondInvoiceURL)

    let sharedText = InvoiceTextRecord(text: "Vendor: Acme Corp\nInvoice: INV-42", source: .pdfText)
    let textStore = InMemoryInvoiceTextStore()
    await textStore.save(sharedText, forContentHash: try FileHasher.sha256(for: firstInvoiceURL))
    await textStore.save(sharedText, forContentHash: try FileHasher.sha256(for: secondInvoiceURL))

    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(
                inboxURL: inboxRoot,
                processedURL: processedRoot,
                processingURL: processingRoot,
                duplicatesURL: duplicatesRoot
            ),
            workflowByID: [:],
            textStore: textStore,
            textExtractor: MockDocumentTextExtractor(defaultResult: sharedText),
            llmSettings: LLMSettings(provider: .lmStudio, baseURL: "", modelName: "", apiKey: "", customInstructions: ""),
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()

    let processedIDs = try #require(await MainActor.run {
        let ids = model.invoices.filter { $0.location == .processed }.map(\.id).sorted()
        return ids.count == 2 ? ids : nil
    })

    await MainActor.run {
        model.updateInvoiceNumber("DOC-42", for: processedIDs[0])
    }
    await model.rescanInvoices(ids: [processedIDs[0]])
    await model.waitForBackgroundTextExtractionForTesting()

    let processedInvoices = await MainActor.run { model.invoices.filter { $0.location == .processed } }
    let processedMetadata = await MainActor.run { processedInvoices.map { model.documentMetadata(for: $0.id) } }
    let document = try #require(await MainActor.run {
        model.document(for: processedIDs[0])
    })

    #expect(processedMetadata.allSatisfy { $0.invoiceNumber == "DOC-42" })
    #expect(document.metadata.invoiceNumber == "DOC-42")
}

@Test func appModelFullDocumentRescanClearsAndRebuildsMetadata() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    let duplicatesRoot = tempRoot.appendingPathComponent("Duplicates", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: duplicatesRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let firstInvoiceURL = processedRoot.appendingPathComponent("doc-1.pdf")
    let secondInvoiceURL = processedRoot.appendingPathComponent("doc-2.pdf")
    try Data("first-file-body".utf8).write(to: firstInvoiceURL)
    try Data("second-file-body".utf8).write(to: secondInvoiceURL)

    let sharedText = InvoiceTextRecord(text: "Vendor: Acme Corp\nInvoice: INV-42", source: .pdfText)
    let textStore = InMemoryInvoiceTextStore()
    await textStore.save(sharedText, forContentHash: try FileHasher.sha256(for: firstInvoiceURL))
    await textStore.save(sharedText, forContentHash: try FileHasher.sha256(for: secondInvoiceURL))

    let structuredClient = MockStructuredExtractionClient(
        defaultResult: InvoiceStructuredDataRecord(
            companyName: "Fresh Corp",
            invoiceNumber: "INV-99",
            invoiceDate: utcDate(year: 2024, month: 2, day: 7),
            documentType: .invoice,
            provider: .lmStudio,
            modelName: "qwen-local"
        )
    )

    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(
                inboxURL: inboxRoot,
                processedURL: processedRoot,
                processingURL: processingRoot,
                duplicatesURL: duplicatesRoot
            ),
            workflowByID: [:],
            textStore: textStore,
            textExtractor: MockDocumentTextExtractor(defaultResult: sharedText),
            structuredDataStore: InMemoryInvoiceStructuredDataStore(),
            structuredExtractionClient: structuredClient,
            llmSettings: LLMSettings(provider: .lmStudio, baseURL: "http://localhost:1234/v1", modelName: "qwen-local", apiKey: "", customInstructions: ""),
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()

    let processedIDs = try #require(await MainActor.run {
        let ids = model.invoices.filter { $0.location == .processed }.map(\.id).sorted()
        return ids.count == 2 ? ids : nil
    })

    await MainActor.run {
        model.updateInvoiceNumber("OLD-42", for: processedIDs[0])
    }

    await model.rescanInvoices(ids: Set(processedIDs))
    let clearedInvoices = await MainActor.run { model.invoices.filter { processedIDs.contains($0.id) } }
    let clearedMetadata = await MainActor.run { clearedInvoices.map { model.documentMetadata(for: $0.id) } }
    #expect(clearedMetadata.allSatisfy { $0.invoiceNumber == nil && $0.vendor == nil && $0.invoiceDate == nil })

    await model.waitForBackgroundTextExtractionForTesting()

    let rebuiltInvoices = await MainActor.run { model.invoices.filter { $0.location == .processed } }
    let rebuiltMetadata = await MainActor.run { rebuiltInvoices.map { model.documentMetadata(for: $0.id) } }
    let document = try #require(await MainActor.run {
        rebuiltInvoices.first.flatMap { model.document(for: $0.id) }
    })

    #expect(rebuiltMetadata.allSatisfy { $0.vendor == "Fresh Corp" })
    #expect(rebuiltMetadata.allSatisfy { $0.invoiceNumber == "INV-99" })
    #expect(rebuiltMetadata.allSatisfy { $0.invoiceDate == utcDate(year: 2024, month: 2, day: 7) })
    #expect(document.metadata.vendor == "Fresh Corp")
    #expect(document.metadata.invoiceNumber == "INV-99")
}

@Test func invoiceBrowserResolvedSortDescriptorsKeepsVisibleSortForQueue() async throws {
    let descriptors = resolvedInvoiceBrowserSortDescriptors(
        [InvoiceBrowserSortDescriptor(columnID: .vendor, ascending: true)],
        for: .inProgress
    )

    #expect(invoiceBrowserSortDescriptorsMatch(
        descriptors,
        [InvoiceBrowserSortDescriptor(columnID: .vendor, ascending: true)]
    ))
}

@Test func invoiceBrowserResolvedSortDescriptorsFallsBackWhenSortIsHiddenInQueue() async throws {
    let descriptors = resolvedInvoiceBrowserSortDescriptors(
        [InvoiceBrowserSortDescriptor(columnID: .vendor, ascending: true)],
        for: .unprocessed
    )

    #expect(invoiceBrowserSortDescriptorsMatch(
        descriptors,
        [InvoiceBrowserSortDescriptor(columnID: .addedAt, ascending: false)]
    ))
}

@MainActor
@Test func appModelRetainsPerTabSearchAndSelectionContext() async throws {
    let model = AppModel(autoRefresh: false)
    let inboxInvoice = PhysicalArtifact(
        name: "alpha.pdf",
        fileURL: URL(fileURLWithPath: "/Inbox/alpha.pdf"),
        location: .inbox,
        addedAt: Date(timeIntervalSince1970: 10),
        fileType: .pdf,
        status: .unprocessed
    )
    let processingInvoice = PhysicalArtifact(
        name: "beta.pdf",
        fileURL: URL(fileURLWithPath: "/Processing/beta.pdf"),
        location: .processing,
        addedAt: Date(timeIntervalSince1970: 20),
        fileType: .pdf,
        status: .inProgress
    )

    model.invoices = [inboxInvoice, processingInvoice]
    model.selectedQueueTab = .unprocessed
    model.selectedArtifactIDs = [inboxInvoice.id]
    model.searchText = "alpha"

    model.selectedQueueTab = .inProgress
    model.selectedArtifactIDs = [processingInvoice.id]
    model.searchText = "beta"

    model.selectedQueueTab = .unprocessed
    #expect(model.searchText == "alpha")
    #expect(model.selectedArtifactIDs == [inboxInvoice.id])
    #expect(model.selectedArtifactID == inboxInvoice.id)

    model.selectedQueueTab = .inProgress
    #expect(model.searchText == "beta")
    #expect(model.selectedArtifactIDs == [processingInvoice.id])
    #expect(model.selectedArtifactID == processingInvoice.id)
}

@MainActor
@Test func appModelRetainsPerTabBrowserContext() async throws {
    let model = AppModel(autoRefresh: false)

    model.selectedQueueTab = .unprocessed
    model.setActiveBrowserContext(
        InvoiceBrowserContext(
            queueTab: .unprocessed,
            sortDescriptors: [InvoiceBrowserSortDescriptor(columnID: .name, ascending: true)],
            expandedGroupIDs: ["/Inbox/alpha.pdf"]
        )
    )

    model.selectedQueueTab = .processed
    model.setActiveBrowserContext(
        InvoiceBrowserContext(
            queueTab: .processed,
            sortDescriptors: [InvoiceBrowserSortDescriptor(columnID: .vendor, ascending: true)],
            expandedGroupIDs: ["/Processed/A/Amazon/invoice.pdf"]
        )
    )

    model.selectedQueueTab = .unprocessed
    #expect(model.activeBrowserContext.sortDescriptors == [
        InvoiceBrowserSortDescriptor(columnID: .name, ascending: true)
    ])
    #expect(model.activeBrowserContext.expandedGroupIDs == ["/Inbox/alpha.pdf"])

    model.selectedQueueTab = .processed
    #expect(model.activeBrowserContext.sortDescriptors == [
        InvoiceBrowserSortDescriptor(columnID: .vendor, ascending: true)
    ])
    #expect(model.activeBrowserContext.expandedGroupIDs == ["/Processed/A/Amazon/invoice.pdf"])
}

@Test func invoiceTextStoreCachesRecordsByContentHash() async throws {
    let suiteName = "InvoiceTextStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = InvoiceTextStore(suiteName: suiteName)
    let record = InvoiceTextRecord(text: "Acme Corp\nTotal 42.00", source: .ocr, ocrConfidence: 0.82)

    await store.save(record, forContentHash: "hash-123")

    #expect(await store.hasCachedText(forContentHash: "hash-123"))
    #expect(await store.cachedText(forContentHash: "hash-123") == record)
    #expect(await store.cachedContentHashes() == ["hash-123"])
}

@Test func documentTextExtractorPrefersEmbeddedPDFText() async throws {
    let callLog = CallLog()
    let extractor = DocumentTextExtractor(
        extractEmbeddedPDFText: { _ in
            callLog.append("pdfText")
            return "Vendor Invoice\nInvoice 42"
        },
        recognizePDFText: { _ in
            callLog.append("pdfOCR")
            return OCRTextResult(text: "Should not run", confidence: 0.25)
        },
        recognizeImageText: { _ in
            callLog.append("imageOCR")
            return OCRTextResult(text: "Should not run", confidence: 0.25)
        }
    )

    let record = try await extractor.extractText(from: URL(fileURLWithPath: "/tmp/invoice.pdf"), fileType: .pdf)

    #expect(record?.source == .pdfText)
    #expect(record?.text == "Vendor Invoice\nInvoice 42")
    #expect(record?.ocrConfidence == nil)
    #expect(callLog.snapshot() == ["pdfText"])
}

@Test func documentTextExtractorFallsBackToOCRWhenEmbeddedPDFTextIsEmpty() async throws {
    let callLog = CallLog()
    let extractor = DocumentTextExtractor(
        extractEmbeddedPDFText: { _ in
            callLog.append("pdfText")
            return "   "
        },
        recognizePDFText: { _ in
            callLog.append("pdfOCR")
            return OCRTextResult(text: "Scanned Invoice\nTotal 42.00", confidence: 0.74)
        },
        recognizeImageText: { _ in
            callLog.append("imageOCR")
            return nil
        }
    )

    let record = try await extractor.extractText(from: URL(fileURLWithPath: "/tmp/invoice.pdf"), fileType: .pdf)

    #expect(record?.source == .ocr)
    #expect(record?.text == "Scanned Invoice\nTotal 42.00")
    #expect(record?.ocrConfidence == 0.74)
    #expect(callLog.snapshot() == ["pdfText", "pdfOCR"])
}

@Test func invoiceTextExtractionQueueProcessesQueuedInvoices() async throws {
    let invoiceURL = URL(fileURLWithPath: "/tmp/incoming.pdf")
    let invoice = PhysicalArtifact(
        name: "incoming.pdf",
        fileURL: invoiceURL,
        location: .inbox,
        addedAt: .now,
        fileType: .pdf,
        status: .unprocessed,
        contentHash: "hash-123"
    )

    let store = InMemoryInvoiceTextStore()
    let extractor = MockDocumentTextExtractor(
        resultsByPath: [
            invoiceURL.path: InvoiceTextRecord(text: "Parsed text", source: .pdfText)
        ]
    )
    let queue = InvoiceTextExtractionQueue(store: store, extractor: extractor)

    await queue.enqueue(invoices: [invoice], knownCachedHashes: [])
    await queue.waitForIdle()

    #expect(await store.cachedText(forContentHash: "hash-123")?.text == "Parsed text")
    #expect(await extractor.callCount(for: invoiceURL.path) == 1)
}

@Test func appModelQueuesUnprocessedInvoicesForBackgroundExtraction() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let invoiceURL = inboxRoot.appendingPathComponent("incoming.pdf")
    try Data("invoice-body".utf8).write(to: invoiceURL)
    let contentHash = try FileHasher.sha256(for: invoiceURL)
    let store = InMemoryInvoiceTextStore()
    let extractor = MockDocumentTextExtractor(
        defaultResult: InvoiceTextRecord(text: "Parsed text", source: .pdfText)
    )
    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(inboxURL: inboxRoot, processedURL: processedRoot, processingURL: processingRoot),
            workflowByID: [:],
            textStore: store,
            textExtractor: extractor,
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()
    await model.waitForBackgroundTextExtractionForTesting()

    let invoices = await MainActor.run { model.invoices }
    #expect(invoices.count == 1)
    #expect(invoices[0].contentHash == contentHash)
    #expect(invoices[0].canPreExtractText)
    #expect(await store.cachedText(forContentHash: contentHash)?.text == "Parsed text")
    #expect(await extractor.totalCallCount() == 1)
    #expect(await model.hasExtractedText(for: invoices[0]))
}

@Test func appModelDeduplicatesInFlightBackgroundExtractionAcrossRefreshes() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let invoiceURL = inboxRoot.appendingPathComponent("incoming.pdf")
    try Data("invoice-body".utf8).write(to: invoiceURL)
    let store = InMemoryInvoiceTextStore()
    let extractor = MockDocumentTextExtractor(
        defaultResult: InvoiceTextRecord(text: "Parsed text", source: .pdfText),
        delay: .milliseconds(200)
    )
    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(inboxURL: inboxRoot, processedURL: processedRoot, processingURL: processingRoot),
            workflowByID: [:],
            textStore: store,
            textExtractor: extractor,
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()
    await model.reloadLibraryForTesting()
    await model.waitForBackgroundTextExtractionForTesting()

    #expect(await extractor.totalCallCount() == 1)
}

@Test func appModelHidesIgnoredInvoicesByDefault() async throws {
    let model = await MainActor.run {
        AppModel(autoRefresh: false)
    }
    let ignoredURL = URL(fileURLWithPath: "/Inbox/\(UUID().uuidString).pdf")
    let ignoredInvoice = PhysicalArtifact(
        name: "ignored.pdf",
        fileURL: ignoredURL,
        location: .inbox,
        addedAt: .now,
        fileType: .pdf,
        status: .unprocessed
    )

    await MainActor.run {
        model.invoices = [ignoredInvoice]
        model.setIgnored(true, for: [ignoredInvoice.id])
    }

    let hiddenVisibleInvoices = await MainActor.run { model.visibleArtifacts }
    #expect(hiddenVisibleInvoices.isEmpty)

    let shownVisibleInvoices = await MainActor.run {
        model.showIgnoredInvoices = true
        return model.visibleArtifacts
    }
    #expect(shownVisibleInvoices.map(\.id) == [ignoredInvoice.id])
    #expect(await MainActor.run { model.isIgnored(ignoredInvoice.id) })
}

@Test func appModelUsesDuplicateProcessedBadgeForProcessedPeerGroup() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let inboxInvoiceURL = inboxRoot.appendingPathComponent("incoming.pdf")
    let processedInvoiceURL = processedRoot
        .appendingPathComponent("A", isDirectory: true)
        .appendingPathComponent("Amazon", isDirectory: true)
        .appendingPathComponent("Amazon-2024-01-05-20240330-062405.pdf")
    try FileManager.default.createDirectory(at: processedInvoiceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("first-file-body".utf8).write(to: inboxInvoiceURL)
    try Data("second-file-body".utf8).write(to: processedInvoiceURL)

    let textStore = InMemoryInvoiceTextStore()
    let inboxHash = try FileHasher.sha256(for: inboxInvoiceURL)
    let processedHash = try FileHasher.sha256(for: processedInvoiceURL)
    let sharedRecord = InvoiceTextRecord(text: "Vendor: Acme Corp\nInvoice: INV-42", source: .pdfText)
    await textStore.save(sharedRecord, forContentHash: inboxHash)
    await textStore.save(sharedRecord, forContentHash: processedHash)
    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(inboxURL: inboxRoot, processedURL: processedRoot, processingURL: processingRoot),
            workflowByID: [:],
            textStore: textStore,
            textExtractor: MockDocumentTextExtractor(),
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()

    let badgeTitle = await MainActor.run {
        let inboxInvoice = model.invoices.first(where: { $0.location == .inbox })
        return inboxInvoice.flatMap { model.duplicateBadgeTitlesByArtifactID[$0.id] }
    }
    #expect(badgeTitle == "Duplicate Processed")
}

@Test func appModelMovesUnprocessedDuplicatePeersToDuplicatesFolderWhenProcessingStarts() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    let duplicatesRoot = tempRoot.appendingPathComponent("Duplicates", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: duplicatesRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let firstInvoiceURL = inboxRoot.appendingPathComponent("incoming-1.pdf")
    let secondInvoiceURL = inboxRoot.appendingPathComponent("incoming-2.pdf")
    try Data("first-file-body".utf8).write(to: firstInvoiceURL)
    try Data("second-file-body".utf8).write(to: secondInvoiceURL)

    let sharedRecord = InvoiceTextRecord(text: "Vendor: Acme Corp\nInvoice: INV-42", source: .pdfText)
    let textStore = InMemoryInvoiceTextStore()
    await textStore.save(sharedRecord, forContentHash: try FileHasher.sha256(for: firstInvoiceURL))
    await textStore.save(sharedRecord, forContentHash: try FileHasher.sha256(for: secondInvoiceURL))

    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(
                inboxURL: inboxRoot,
                processedURL: processedRoot,
                processingURL: processingRoot,
                duplicatesURL: duplicatesRoot
            ),
            workflowByID: [:],
            textStore: textStore,
            textExtractor: MockDocumentTextExtractor(),
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()

    let selectedArtifact = try #require(await MainActor.run {
        model.invoices
            .filter { $0.location == .inbox }
            .sorted { $0.name < $1.name }
            .first
    })
    #expect(await MainActor.run { model.documents.filter { $0.isDuplicate }.count } == 1)

    await MainActor.run {
        model.moveInvoicesToInProgress(ids: [selectedArtifact.id])
    }
    await model.reloadLibraryForTesting()

    let remainingInvoices = await MainActor.run { model.invoices }
    let movedInvoice = try #require(remainingInvoices.first(where: { $0.location == .processing }))
    let duplicateFolderFiles = try FileManager.default.contentsOfDirectory(
        at: duplicatesRoot,
        includingPropertiesForKeys: nil
    )

    #expect(remainingInvoices.count == 1)
    #expect(movedInvoice.name == selectedArtifact.name)
    #expect(duplicateFolderFiles.map(\.lastPathComponent).sorted() == ["incoming-2.pdf"])
    #expect(!remainingInvoices.contains(where: { $0.name == "incoming-2.pdf" }))
    #expect(await MainActor.run { model.documents.filter { $0.isDuplicate }.isEmpty })
}

@Test func appModelMovesOnlyFirstSelectedDuplicateIntoProcessing() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    let duplicatesRoot = tempRoot.appendingPathComponent("Duplicates", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: duplicatesRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let firstInvoiceURL = inboxRoot.appendingPathComponent("incoming-1.pdf")
    let secondInvoiceURL = inboxRoot.appendingPathComponent("incoming-2.pdf")
    try Data("first-file-body".utf8).write(to: firstInvoiceURL)
    try Data("second-file-body".utf8).write(to: secondInvoiceURL)

    let sharedRecord = InvoiceTextRecord(text: "Vendor: Acme Corp\nInvoice: INV-42", source: .pdfText)
    let textStore = InMemoryInvoiceTextStore()
    await textStore.save(sharedRecord, forContentHash: try FileHasher.sha256(for: firstInvoiceURL))
    await textStore.save(sharedRecord, forContentHash: try FileHasher.sha256(for: secondInvoiceURL))

    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(
                inboxURL: inboxRoot,
                processedURL: processedRoot,
                processingURL: processingRoot,
                duplicatesURL: duplicatesRoot
            ),
            workflowByID: [:],
            textStore: textStore,
            textExtractor: MockDocumentTextExtractor(),
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()

    let orderedInvoices = try #require(await MainActor.run {
        let invoices = model.invoices
            .filter { $0.location == .inbox }
            .sorted { $0.name < $1.name }
        return invoices.count == 2 ? invoices : nil
    })

    await MainActor.run {
        model.moveInvoicesToInProgress(ids: orderedInvoices.map(\.id))
    }
    await model.reloadLibraryForTesting()

    let remainingInvoices = await MainActor.run { model.invoices }
    let processingNames = remainingInvoices
        .filter { $0.location == .processing }
        .map(\.name)
        .sorted()
    let duplicateFolderFiles = try FileManager.default.contentsOfDirectory(
        at: duplicatesRoot,
        includingPropertiesForKeys: nil
    )

    #expect(processingNames == ["incoming-1.pdf"])
    #expect(duplicateFolderFiles.map(\.lastPathComponent).sorted() == ["incoming-2.pdf"])
    #expect(remainingInvoices.count == 1)
}

@Test func appModelLeavesAllInboxPeersActionableAfterExtractionBackedReload() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let firstInvoiceURL = inboxRoot.appendingPathComponent("incoming-1.pdf")
    let secondInvoiceURL = inboxRoot.appendingPathComponent("incoming-2.pdf")
    try Data("first-file-body".utf8).write(to: firstInvoiceURL)
    try Data("second-file-body".utf8).write(to: secondInvoiceURL)

    let extractor = MockDocumentTextExtractor(
        defaultResult: InvoiceTextRecord(text: "Vendor: Acme Corp\nInvoice: INV-42", source: .pdfText),
        delay: .milliseconds(150)
    )
    let textStore = InMemoryInvoiceTextStore()
    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(inboxURL: inboxRoot, processedURL: processedRoot, processingURL: processingRoot),
            workflowByID: [:],
            textStore: textStore,
            textExtractor: extractor,
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()

    let invoicesBeforeExtraction = await MainActor.run { model.invoices }
    #expect(invoicesBeforeExtraction.count == 2)
    #expect(invoicesBeforeExtraction.allSatisfy { $0.status == .unprocessed })
    #expect(invoicesBeforeExtraction.allSatisfy { $0.duplicateReason == nil })

    await model.waitForBackgroundTextExtractionForTesting()
    #expect(await textStore.cachedContentHashes().count == 2)
    await model.reloadLibraryForTesting()

    let invoicesAfterExtraction = await MainActor.run { model.invoices }
    #expect(invoicesAfterExtraction.filter { $0.status == .blockedDuplicate }.isEmpty)
    #expect(invoicesAfterExtraction.filter { $0.status == .unprocessed }.count == 2)
    #expect(invoicesAfterExtraction.allSatisfy { $0.duplicateReason == nil })
    #expect(await MainActor.run { model.documents.filter { $0.isDuplicate }.count == 1 })
    #expect(await extractor.totalCallCount() == 2)
}

@Test func lmStudioStructuredExtractionClientParsesStructuredJSON() async throws {
    let responseBody = """
    {
      "choices": [
        {
          "message": {
            "content": "{\\"companyName\\":\\"Acme Corp\\",\\"invoiceNumber\\":\\"INV-42\\",\\"invoiceDate\\":\\"2024-01-05\\",\\"documentType\\":\\"invoice\\"}"
          }
        }
      ]
    }
    """

    let client = LMStudioStructuredExtractionClient(
        transport: StaticStructuredExtractionTransport { _ in
            (
                Data(responseBody.utf8),
                HTTPURLResponse(
                    url: URL(string: "http://localhost:1234/v1/chat/completions")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
    )
    let settings = LLMSettings(
        provider: .lmStudio,
        baseURL: "http://localhost:1234/v1",
        modelName: "qwen-local",
        apiKey: "",
        customInstructions: ""
    )

    let record = try await client.extractStructuredData(from: "raw text", settings: settings)

    #expect(record?.companyName == "Acme Corp")
    #expect(record?.invoiceNumber == "INV-42")
    #expect(record?.invoiceDate.map(localDateComponents(_:)) == DateComponents(year: 2024, month: 1, day: 5))
    #expect(record?.documentType == .invoice)
    #expect(record?.provider == .lmStudio)
}

@Test func structuredExtractionClientIncludesCustomInstructionsInPrompt() async throws {
    let responseBody = """
    {
      "choices": [
        {
          "message": {
            "content": "{\\"companyName\\":\\"Restaurant Depo\\",\\"invoiceNumber\\":\\"\\",\\"invoiceDate\\":\\"2024-01-05\\",\\"documentType\\":\\"receipt\\"}"
          }
        }
      ]
    }
    """
    let capturedBody = LockedBox<Data?>(nil)
    let client = LMStudioStructuredExtractionClient(
        transport: StaticStructuredExtractionTransport { request in
            await capturedBody.set(request.httpBody)
            return (
                Data(responseBody.utf8),
                HTTPURLResponse(
                    url: URL(string: "http://localhost:1234/v1/chat/completions")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
    )
    let settings = LLMSettings(
        provider: .lmStudio,
        baseURL: "http://localhost:1234/v1",
        modelName: "qwen-local",
        apiKey: "",
        customInstructions: "My company name is ABC company and our address is 123 Main St, so do not use ABC company as the vendor name. Sometimes we'll have a receipt for \"Burger Joint\"; when you see that, use Restaurant Depo as the vendor name."
    )

    _ = try await client.extractStructuredData(from: "Receipt text", settings: settings)

    let requestBody = try #require(await capturedBody.value())
    let payload = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
    let messages = try #require(payload["messages"] as? [[String: Any]])
    #expect(messages.count == 3)
    let systemMessage = messages[0]
    let userMessage = messages[1]
    let instructionMessage = messages[2]
    #expect(systemMessage["role"] as? String == "system")
    #expect(userMessage["role"] as? String == "user")
    #expect(instructionMessage["role"] as? String == "user")
    let systemContent = try #require(systemMessage["content"] as? String)
    let instructionContent = try #require(instructionMessage["content"] as? String)
    let content = try #require(userMessage["content"] as? String)
    #expect(systemContent.contains("companyName should be normalized to a plain vendor name with no special characters"))
    #expect(systemContent.contains("Use the provided current date as temporal context"))
    #expect(instructionContent.contains("Additional user-specific extraction guidance:"))
    #expect(instructionContent.contains("do not use ABC company as the vendor name"))
    #expect(instructionContent.contains("\"Burger Joint\""))
    #expect(instructionContent.contains("use Restaurant Depo as the vendor name"))
    #expect(content.contains("Extract the following fields from this invoice, receipt, or document text:"))
    #expect(content.contains("Today's date is \(isoPromptDateString())"))
    #expect(content.contains("Invoice text:"))
}

@Test func structuredExtractionClientNormalizesAllCapsVendorNames() async throws {
    let responseBody = """
    {
      "choices": [
        {
          "message": {
            "content": "{\\"companyName\\":\\"ATLANTIC BEVERAGE DISTRIBUTORS\\",\\"invoiceNumber\\":\\"INV-42\\",\\"invoiceDate\\":\\"2024-01-05\\",\\"documentType\\":\\"invoice\\"}"
          }
        }
      ]
    }
    """

    let client = LMStudioStructuredExtractionClient(
        transport: StaticStructuredExtractionTransport { _ in
            (
                Data(responseBody.utf8),
                HTTPURLResponse(
                    url: URL(string: "http://localhost:1234/v1/chat/completions")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
    )
    let settings = LLMSettings(
        provider: .lmStudio,
        baseURL: "http://localhost:1234/v1",
        modelName: "qwen-local",
        apiKey: "",
        customInstructions: ""
    )

    let record = try await client.extractStructuredData(from: "raw text", settings: settings)

    #expect(record?.companyName == "Atlantic Beverage Distributors")
}

@Test func structuredExtractionClientCanonicalizesMixedCaseVendorSuffixes() async throws {
    let responseBody = """
    {
      "choices": [
        {
          "message": {
            "content": "{\\"companyName\\":\\"Atlantic Beverage Distributors INC\\",\\"invoiceNumber\\":\\"INV-42\\",\\"invoiceDate\\":\\"2024-01-05\\",\\"documentType\\":\\"invoice\\"}"
          }
        }
      ]
    }
    """

    let client = LMStudioStructuredExtractionClient(
        transport: StaticStructuredExtractionTransport { _ in
            (
                Data(responseBody.utf8),
                HTTPURLResponse(
                    url: URL(string: "http://localhost:1234/v1/chat/completions")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
    )
    let settings = LLMSettings(
        provider: .lmStudio,
        baseURL: "http://localhost:1234/v1",
        modelName: "qwen-local",
        apiKey: "",
        customInstructions: ""
    )

    let record = try await client.extractStructuredData(from: "raw text", settings: settings)

    #expect(record?.companyName == "Atlantic Beverage Distributors Inc")
}

@Test func openAIStructuredExtractionClientMapsUnauthorizedPreflightToAuthFailure() async throws {
    let client = OpenAIStructuredExtractionClient(
        transport: StaticStructuredExtractionTransport { request in
            (
                Data("{}".utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
    )
    let settings = LLMSettings(
        provider: .openAI,
        baseURL: "https://api.openai.com/v1",
        modelName: "gpt-4o-mini",
        apiKey: "bad-key",
        customInstructions: ""
    )

    let status = await client.preflightCheck(settings: settings)

    #expect(status.state == .authenticationFailed)
}

@Test func invoiceStructuredDataStoreCachesRecordsByContentHash() async throws {
    let suiteName = "InvoiceStructuredDataStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = InvoiceStructuredDataStore(suiteName: suiteName)
    let record = InvoiceStructuredDataRecord(
        companyName: "Acme Corp",
        invoiceNumber: "INV-42",
        invoiceDate: utcDate(year: 2024, month: 1, day: 5),
        documentType: .invoice,
        provider: .lmStudio,
        modelName: "qwen-local"
    )

    await store.save(record, forContentHash: "hash-456")

    #expect(await store.hasCachedData(forContentHash: "hash-456"))
    #expect(await store.cachedData(forContentHash: "hash-456") == record)
    #expect(await store.cachedContentHashes() == ["hash-456"])
}

@Test func invoiceStructuredExtractionQueueSkipsAlreadyCachedHashes() async throws {
    let textStore = InMemoryInvoiceTextStore()
    let structuredStore = InMemoryInvoiceStructuredDataStore()
    await textStore.save(InvoiceTextRecord(text: "Vendor text", source: .pdfText), forContentHash: "hash-123")
    await structuredStore.save(
        InvoiceStructuredDataRecord(
            companyName: "Acme Corp",
            invoiceNumber: "INV-42",
            invoiceDate: utcDate(year: 2024, month: 1, day: 5),
            documentType: .invoice,
            provider: .lmStudio,
            modelName: "qwen-local"
        ),
        forContentHash: "hash-123"
    )

    let client = MockStructuredExtractionClient(defaultResult: InvoiceStructuredDataRecord(
        companyName: "Should Not Run",
        invoiceNumber: nil,
        invoiceDate: nil,
        documentType: nil,
        provider: .lmStudio,
        modelName: "qwen-local"
    ))
    let queue = InvoiceStructuredExtractionQueue(
        textStore: textStore,
        structuredDataStore: structuredStore,
        client: client
    )
    let invoice = PhysicalArtifact(
        name: "incoming.pdf",
        fileURL: URL(fileURLWithPath: "/tmp/incoming.pdf"),
        location: .inbox,
        addedAt: .now,
        fileType: .pdf,
        status: .unprocessed,
        contentHash: "hash-123"
    )

    await queue.enqueue(
        invoices: [invoice],
        knownStructuredHashes: ["hash-123"],
        settings: LLMSettings(provider: .lmStudio, baseURL: "http://localhost:1234/v1", modelName: "qwen-local", apiKey: "", customInstructions: "")
    )
    await queue.waitForIdle()

    #expect(await client.totalCallCount() == 0)
}

@Test func appModelAutofillsWorkflowFromStructuredExtraction() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let invoiceURL = inboxRoot.appendingPathComponent("incoming.pdf")
    try Data("invoice-body".utf8).write(to: invoiceURL)
    let contentHash = try FileHasher.sha256(for: invoiceURL)

    let textStore = InMemoryInvoiceTextStore()
    await textStore.save(
        InvoiceTextRecord(text: "Vendor: Acme Corp Invoice: INV-42 Date: 2024-01-05", source: .pdfText),
        forContentHash: contentHash
    )
    let structuredStore = InMemoryInvoiceStructuredDataStore()
    let structuredClient = MockStructuredExtractionClient(
        defaultResult: InvoiceStructuredDataRecord(
            companyName: "Acme Corp",
            invoiceNumber: "INV-42",
            invoiceDate: utcDate(year: 2024, month: 1, day: 5),
            documentType: .invoice,
            provider: .lmStudio,
            modelName: "qwen-local"
        )
    )
    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(inboxURL: inboxRoot, processedURL: processedRoot, processingURL: processingRoot),
            workflowByID: [:],
            textStore: textStore,
            textExtractor: MockDocumentTextExtractor(),
            structuredDataStore: structuredStore,
            structuredExtractionClient: structuredClient,
            llmSettings: LLMSettings(provider: .lmStudio, baseURL: "http://localhost:1234/v1", modelName: "qwen-local", apiKey: "", customInstructions: ""),
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()
    await model.waitForBackgroundTextExtractionForTesting()

    let invoice = await MainActor.run { model.invoices.first }
    let invoiceMetadata = await MainActor.run { invoice.map { model.documentMetadata(for: $0.id) } }
    #expect(invoiceMetadata?.vendor == "Acme Corp")
    #expect(invoiceMetadata?.invoiceNumber == "INV-42")
    #expect(invoiceMetadata?.invoiceDate == utcDate(year: 2024, month: 1, day: 5))
    #expect(invoiceMetadata?.documentType == .invoice)
    #expect(await structuredStore.hasCachedData(forContentHash: contentHash))
    #expect(await structuredClient.totalCallCount() == 1)
}

@Test func appModelRenamesMovedInvoiceWhenStructuredDataIsHighConfidence() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    let duplicatesRoot = tempRoot.appendingPathComponent("Duplicates", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: duplicatesRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let invoiceURL = inboxRoot.appendingPathComponent("incoming.pdf")
    try Data("invoice-body".utf8).write(to: invoiceURL)
    let contentHash = try FileHasher.sha256(for: invoiceURL)

    let textStore = InMemoryInvoiceTextStore()
    await textStore.save(
        InvoiceTextRecord(text: "Vendor: Acme Corp Invoice: INV-42 Date: 2024-01-05", source: .pdfText),
        forContentHash: contentHash
    )
    let structuredStore = InMemoryInvoiceStructuredDataStore()
    let structuredClient = MockStructuredExtractionClient(
        defaultResult: InvoiceStructuredDataRecord(
            companyName: "Acme Corp",
            invoiceNumber: "INV-42",
            invoiceDate: utcDate(year: 2024, month: 1, day: 5),
            documentType: .invoice,
            provider: .lmStudio,
            modelName: "qwen-local"
        )
    )
    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(inboxURL: inboxRoot, processedURL: processedRoot, processingURL: processingRoot, duplicatesURL: duplicatesRoot),
            workflowByID: [:],
            textStore: textStore,
            textExtractor: MockDocumentTextExtractor(),
            structuredDataStore: structuredStore,
            structuredExtractionClient: structuredClient,
            llmSettings: LLMSettings(provider: .lmStudio, baseURL: "http://localhost:1234/v1", modelName: "qwen-local", apiKey: "", customInstructions: ""),
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()
    await model.waitForBackgroundTextExtractionForTesting()

    let invoiceID = try #require(await MainActor.run { model.invoices.first?.id })
    await MainActor.run {
        model.moveInvoicesToInProgress(ids: [invoiceID])
    }
    await model.reloadLibraryForTesting()

    let movedInvoice = try #require(await MainActor.run {
        model.invoices.first(where: { $0.location == .processing })
    })
    let movedMetadata = await MainActor.run { model.documentMetadata(for: movedInvoice.id) }
    #expect(movedInvoice.name == "Acme Corp-2024-01-05-INV-42.pdf")
    #expect(movedMetadata.vendor == "Acme Corp")
    #expect(movedMetadata.invoiceNumber == "INV-42")
    #expect(movedMetadata.invoiceDate == utcDate(year: 2024, month: 1, day: 5))
    #expect(movedMetadata.documentType == .invoice)
}

@Test func appModelRenamesReceiptWithoutInvoiceNumber() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    let duplicatesRoot = tempRoot.appendingPathComponent("Duplicates", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: duplicatesRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let invoiceURL = inboxRoot.appendingPathComponent("receipt.pdf")
    try Data("receipt-body".utf8).write(to: invoiceURL)
    let contentHash = try FileHasher.sha256(for: invoiceURL)

    let textStore = InMemoryInvoiceTextStore()
    await textStore.save(
        InvoiceTextRecord(text: "Merchant: Coffee Shop Date: 2024-01-05 Total: 8.50", source: .pdfText),
        forContentHash: contentHash
    )
    let structuredStore = InMemoryInvoiceStructuredDataStore()
    let structuredClient = MockStructuredExtractionClient(
        defaultResult: InvoiceStructuredDataRecord(
            companyName: "Coffee Shop",
            invoiceNumber: nil,
            invoiceDate: utcDate(year: 2024, month: 1, day: 5),
            documentType: .receipt,
            provider: .lmStudio,
            modelName: "qwen-local"
        )
    )
    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(inboxURL: inboxRoot, processedURL: processedRoot, processingURL: processingRoot, duplicatesURL: duplicatesRoot),
            workflowByID: [:],
            textStore: textStore,
            textExtractor: MockDocumentTextExtractor(),
            structuredDataStore: structuredStore,
            structuredExtractionClient: structuredClient,
            llmSettings: LLMSettings(provider: .lmStudio, baseURL: "http://localhost:1234/v1", modelName: "qwen-local", apiKey: "", customInstructions: ""),
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()
    await model.waitForBackgroundTextExtractionForTesting()

    let invoiceID = try #require(await MainActor.run { model.invoices.first?.id })
    await MainActor.run {
        model.moveInvoicesToInProgress(ids: [invoiceID])
    }
    await model.reloadLibraryForTesting()

    let movedInvoice = try #require(await MainActor.run {
        model.invoices.first(where: { $0.location == .processing })
    })
    let movedMetadata = await MainActor.run { model.documentMetadata(for: movedInvoice.id) }
    #expect(movedInvoice.name == "Coffee Shop-2024-01-05.pdf")
    #expect(movedMetadata.vendor == "Coffee Shop")
    #expect(movedMetadata.invoiceNumber == nil)
    #expect(movedMetadata.invoiceDate == utcDate(year: 2024, month: 1, day: 5))
    #expect(movedMetadata.documentType == .receipt)
}

@Test func appModelStructuredExtractionDeduplicatesAcrossRefreshes() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let invoiceURL = inboxRoot.appendingPathComponent("incoming.pdf")
    try Data("invoice-body".utf8).write(to: invoiceURL)
    let contentHash = try FileHasher.sha256(for: invoiceURL)

    let textStore = InMemoryInvoiceTextStore()
    await textStore.save(
        InvoiceTextRecord(text: "Vendor: Acme Corp Invoice: INV-42 Date: 2024-01-05", source: .pdfText),
        forContentHash: contentHash
    )
    let structuredStore = InMemoryInvoiceStructuredDataStore()
    let structuredClient = MockStructuredExtractionClient(
        defaultResult: InvoiceStructuredDataRecord(
            companyName: "Acme Corp",
            invoiceNumber: "INV-42",
            invoiceDate: utcDate(year: 2024, month: 1, day: 5),
            provider: .lmStudio,
            modelName: "qwen-local"
        ),
        delay: .milliseconds(200)
    )
    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(inboxURL: inboxRoot, processedURL: processedRoot, processingURL: processingRoot),
            workflowByID: [:],
            textStore: textStore,
            textExtractor: MockDocumentTextExtractor(),
            structuredDataStore: structuredStore,
            structuredExtractionClient: structuredClient,
            llmSettings: LLMSettings(provider: .lmStudio, baseURL: "http://localhost:1234/v1", modelName: "qwen-local", apiKey: "", customInstructions: ""),
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()
    await model.reloadLibraryForTesting()
    await model.waitForBackgroundTextExtractionForTesting()

    #expect(await structuredClient.totalCallCount() == 1)
}

@Test func appModelRescanInvalidatesCachesAndRequeuesExtraction() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let invoiceURL = processingRoot.appendingPathComponent("incoming.pdf")
    try Data("invoice-body".utf8).write(to: invoiceURL)
    let contentHash = try FileHasher.sha256(for: invoiceURL)

    let textStore = InMemoryInvoiceTextStore()
    await textStore.save(InvoiceTextRecord(text: "Stale text", source: .pdfText), forContentHash: contentHash)

    let structuredStore = InMemoryInvoiceStructuredDataStore()
    await structuredStore.save(
        InvoiceStructuredDataRecord(
            companyName: "Old Corp",
            invoiceNumber: "OLD-1",
            invoiceDate: utcDate(year: 2024, month: 1, day: 5),
            provider: .lmStudio,
            modelName: "old-model"
        ),
        forContentHash: contentHash
    )

    let extractor = MockDocumentTextExtractor(
        defaultResult: InvoiceTextRecord(text: "Fresh text", source: .pdfText)
    )
    let structuredClient = MockStructuredExtractionClient(
        defaultResult: InvoiceStructuredDataRecord(
            companyName: "Fresh Corp",
            invoiceNumber: "INV-99",
            invoiceDate: utcDate(year: 2024, month: 2, day: 7),
            provider: .lmStudio,
            modelName: "fresh-model"
        )
    )

    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(inboxURL: inboxRoot, processedURL: processedRoot, processingURL: processingRoot),
            workflowByID: [
                PhysicalArtifact.stableID(for: invoiceURL): StoredInvoiceWorkflow(
                    vendor: "Old Corp",
                    invoiceDate: utcDate(year: 2024, month: 1, day: 5),
                    invoiceNumber: "OLD-1",
                    isInProgress: false
                )
            ],
            textStore: textStore,
            textExtractor: extractor,
            structuredDataStore: structuredStore,
            structuredExtractionClient: structuredClient,
            llmSettings: LLMSettings(provider: .lmStudio, baseURL: "http://localhost:1234/v1", modelName: "fresh-model", apiKey: "", customInstructions: ""),
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()
    let invoiceID = try #require(await MainActor.run { model.invoices.first?.id })

    await MainActor.run {
        model.selectedArtifactIDs = [invoiceID]
    }
    await model.rescanInvoices(ids: [invoiceID])
    await model.waitForBackgroundTextExtractionForTesting()

    let rescannedInvoice = try #require(await MainActor.run {
        model.invoices.first(where: { $0.contentHash == contentHash })
    })

    #expect(await textStore.cachedText(forContentHash: contentHash)?.text == "Fresh text")
    #expect(await structuredStore.cachedData(forContentHash: contentHash)?.companyName == "Fresh Corp")
    #expect(await extractor.totalCallCount() == 1)
    #expect(await structuredClient.totalCallCount() == 1)
    let rescannedMetadata = await MainActor.run { model.documentMetadata(for: rescannedInvoice.id) }
    #expect(rescannedMetadata.vendor == "Fresh Corp")
    #expect(rescannedMetadata.invoiceNumber == "INV-99")
    #expect(rescannedMetadata.invoiceDate == utcDate(year: 2024, month: 2, day: 7))
}

@Test func appModelRescanClearsFieldsMissingFromStructuredExtraction() async throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxRoot = tempRoot.appendingPathComponent("Inbox", isDirectory: true)
    let processingRoot = tempRoot.appendingPathComponent("Processing", isDirectory: true)
    let processedRoot = tempRoot.appendingPathComponent("Processed", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let invoiceURL = processingRoot.appendingPathComponent("incoming.pdf")
    try Data("invoice-body".utf8).write(to: invoiceURL)
    let contentHash = try FileHasher.sha256(for: invoiceURL)

    let textStore = InMemoryInvoiceTextStore()
    await textStore.save(InvoiceTextRecord(text: "Stale text", source: .pdfText), forContentHash: contentHash)

    let structuredStore = InMemoryInvoiceStructuredDataStore()
    await structuredStore.save(
        InvoiceStructuredDataRecord(
            companyName: "Old Corp",
            invoiceNumber: "OLD-1",
            invoiceDate: utcDate(year: 2024, month: 1, day: 5),
            provider: .lmStudio,
            modelName: "old-model"
        ),
        forContentHash: contentHash
    )

    let extractor = MockDocumentTextExtractor(
        defaultResult: InvoiceTextRecord(text: "Fresh text", source: .pdfText)
    )
    let structuredClient = MockStructuredExtractionClient(
        defaultResult: InvoiceStructuredDataRecord(
            companyName: nil,
            invoiceNumber: "INV-99",
            invoiceDate: nil,
            provider: .lmStudio,
            modelName: "fresh-model"
        )
    )

    let model = await MainActor.run {
        AppModel(
            folderSettings: FolderSettings(inboxURL: inboxRoot, processedURL: processedRoot, processingURL: processingRoot),
            workflowByID: [
                PhysicalArtifact.stableID(for: invoiceURL): StoredInvoiceWorkflow(
                    vendor: "Old Corp",
                    invoiceDate: utcDate(year: 2024, month: 1, day: 5),
                    invoiceNumber: "OLD-1",
                    isInProgress: false
                )
            ],
            textStore: textStore,
            textExtractor: extractor,
            structuredDataStore: structuredStore,
            structuredExtractionClient: structuredClient,
            llmSettings: LLMSettings(provider: .lmStudio, baseURL: "http://localhost:1234/v1", modelName: "fresh-model", apiKey: "", customInstructions: ""),
            autoRefresh: false
        )
    }

    await model.reloadLibraryForTesting()
    let invoiceID = try #require(await MainActor.run { model.invoices.first?.id })

    await MainActor.run {
        model.selectedArtifactIDs = [invoiceID]
    }
    await model.rescanInvoices(ids: [invoiceID])
    await model.waitForBackgroundTextExtractionForTesting()

    let rescannedInvoice = try #require(await MainActor.run {
        model.invoices.first(where: { $0.contentHash == contentHash })
    })
    let rescannedMetadata = await MainActor.run { model.documentMetadata(for: rescannedInvoice.id) }

    #expect(rescannedMetadata.vendor == nil)
    #expect(rescannedMetadata.invoiceDate == nil)
    #expect(rescannedMetadata.invoiceNumber == "INV-99")
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    func append(_ value: String) {
        lock.lock()
        calls.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private actor InMemoryInvoiceTextStore: InvoiceTextStoring {
    private var records: [String: InvoiceTextRecord] = [:]

    func cachedText(forContentHash contentHash: String) async -> InvoiceTextRecord? {
        records[contentHash]
    }

    func hasCachedText(forContentHash contentHash: String) async -> Bool {
        records[contentHash] != nil
    }

    func save(_ record: InvoiceTextRecord, forContentHash contentHash: String) async {
        records[contentHash] = record
    }

    func removeCachedText(forContentHash contentHash: String) async {
        records.removeValue(forKey: contentHash)
    }

    func cachedContentHashes() async -> Set<String> {
        Set(records.keys)
    }

    func cachedRecords() async -> [String: InvoiceTextRecord] {
        records
    }
}

private actor InMemoryInvoiceStructuredDataStore: InvoiceStructuredDataStoring {
    private var records: [String: InvoiceStructuredDataRecord] = [:]

    func cachedData(forContentHash contentHash: String) async -> InvoiceStructuredDataRecord? {
        records[contentHash]
    }

    func hasCachedData(forContentHash contentHash: String) async -> Bool {
        records[contentHash] != nil
    }

    func save(_ record: InvoiceStructuredDataRecord, forContentHash contentHash: String) async {
        records[contentHash] = record
    }

    func removeCachedData(forContentHash contentHash: String) async {
        records.removeValue(forKey: contentHash)
    }

    func cachedContentHashes() async -> Set<String> {
        Set(records.keys)
    }

    func cachedRecords() async -> [String: InvoiceStructuredDataRecord] {
        records
    }
}

private struct StaticStructuredExtractionTransport: StructuredExtractionTransporting {
    let responder: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await responder(request)
    }
}

private actor LockedBox<Value> {
    private var storedValue: Value

    init(_ value: Value) {
        self.storedValue = value
    }

    func set(_ value: Value) {
        storedValue = value
    }

    func value() -> Value {
        storedValue
    }
}

private func isoPromptDateString(now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: now)
}

private actor MockDocumentTextExtractor: DocumentTextExtracting {
    private let resultsByPath: [String: InvoiceTextRecord]
    private let defaultResult: InvoiceTextRecord?
    private let delay: Duration?
    private var callCounts: [String: Int] = [:]

    init(resultsByPath: [String: InvoiceTextRecord] = [:], defaultResult: InvoiceTextRecord? = nil, delay: Duration? = nil) {
        self.resultsByPath = resultsByPath
        self.defaultResult = defaultResult
        self.delay = delay
    }

    func extractText(from fileURL: URL, fileType: InvoiceFileType) async throws -> InvoiceTextRecord? {
        callCounts[fileURL.path, default: 0] += 1

        if let delay {
            try? await Task.sleep(for: delay)
        }

        return resultsByPath[fileURL.path] ?? defaultResult
    }

    func callCount(for path: String) -> Int {
        callCounts[path, default: 0]
    }

    func totalCallCount() -> Int {
        callCounts.values.reduce(0, +)
    }

}

private actor MockStructuredExtractionClient: InvoiceStructuredExtractionClient {
    private let defaultResult: InvoiceStructuredDataRecord?
    private let preflightStatus: LLMPreflightStatus
    private let delay: Duration?
    private var callCount = 0

    init(
        defaultResult: InvoiceStructuredDataRecord? = nil,
        preflightStatus: LLMPreflightStatus = LLMPreflightStatus(state: .ready, message: "Ready"),
        delay: Duration? = nil
    ) {
        self.defaultResult = defaultResult
        self.preflightStatus = preflightStatus
        self.delay = delay
    }

    func preflightCheck(settings: LLMSettings) async -> LLMPreflightStatus {
        preflightStatus
    }

    func extractStructuredData(from text: String, settings: LLMSettings) async throws -> InvoiceStructuredDataRecord? {
        callCount += 1

        if let delay {
            try? await Task.sleep(for: delay)
        }

        return defaultResult
    }

    func totalCallCount() -> Int {
        callCount
    }
}
