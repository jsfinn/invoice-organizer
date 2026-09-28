import Foundation
import Testing
@testable import InvoiceOrganizer

// MARK: - Identity map pruning

@Test func pruneKeepsMapWhenScanMatchesNoKnownPath() async throws {
    let store = PhysicalArtifactIdentityStore(pathToID: [
        "/Processed/A/Amazon/Amazon-2024-01-05.pdf": "id-1",
        "/Processed/S/Sysco/Sysco-2024-02-11.pdf": "id-2",
    ])

    // What an unreadable or unmounted root looks like: the scan succeeds but
    // recognises nothing.
    store.prune(keepingPaths: ["/SomeOtherVolume/file.pdf"])

    #expect(store.existingID(forPath: "/Processed/A/Amazon/Amazon-2024-01-05.pdf") == "id-1")
    #expect(store.existingID(forPath: "/Processed/S/Sysco/Sysco-2024-02-11.pdf") == "id-2")
}

@Test func pruneKeepsMapWhenScanReturnsNothing() async throws {
    let store = PhysicalArtifactIdentityStore(pathToID: ["/Processed/a.pdf": "id-1"])

    store.prune(keepingPaths: [])

    #expect(store.existingID(forPath: "/Processed/a.pdf") == "id-1")
}

@Test func pruneDropsStalePathsWhenScanMatchesSomething() async throws {
    let store = PhysicalArtifactIdentityStore(pathToID: [
        "/Processed/a.pdf": "id-1",
        "/Processed/gone.pdf": "id-2",
    ])

    store.prune(keepingPaths: ["/Processed/a.pdf"])

    #expect(store.existingID(forPath: "/Processed/a.pdf") == "id-1")
    #expect(store.existingID(forPath: "/Processed/gone.pdf") == nil)
}

// MARK: - Legacy state extraction

private func makeTestDefaults(_ function: String = #function) -> (UserDefaults, () -> Void) {
    let suiteName = "InvoiceOrganizerTests.\(function).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
}

@Test func extractorReadsAllFiveBlobs() async throws {
    let (defaults, cleanup) = makeTestDefaults()
    defer { cleanup() }

    let workflow = StoredInvoiceWorkflow(
        vendor: "Sysco",
        invoiceDate: nil,
        invoiceNumber: "256174208",
        isInProgress: false
    )
    let text = InvoiceTextRecord(text: "total due", firstPageText: "total due", source: .pdfText)
    let structured = InvoiceStructuredDataRecord(
        companyName: "Sysco",
        invoiceNumber: "256174208",
        invoiceDate: nil,
        provider: .lmStudio,
        modelName: "qwen"
    )
    let pair = ContentHashPair("hash-a", "hash-b")

    let encoder = JSONEncoder()
    defaults.set(try encoder.encode(["artifact-1": workflow]), forKey: InvoiceWorkflowStore.defaultsKey)
    defaults.set(try encoder.encode(["/Processed/a.pdf": "artifact-1"]), forKey: PhysicalArtifactIdentityStore.defaultsKey)
    defaults.set(try encoder.encode(["hash-a": text]), forKey: InvoiceTextStore.defaultsKey)
    defaults.set(try encoder.encode(["hash-a": structured]), forKey: InvoiceStructuredDataStore.defaultsKey)
    defaults.set(try encoder.encode([pair]), forKey: DuplicateOverrideStore.defaultsKey)

    let state = LibraryStateExtractor.extract(defaults: defaults)

    #expect(state.workflowByArtifactID["artifact-1"]?.vendor == "Sysco")
    #expect(state.identityMapByPath["/Processed/a.pdf"] == "artifact-1")
    #expect(state.extractedTextByContentHash["hash-a"]?.text == "total due")
    #expect(state.structuredDataByContentHash["hash-a"]?.invoiceNumber == "256174208")
    #expect(state.separatedContentHashPairs == [pair])
    #expect(state.undecodableKeys.isEmpty)
}

@Test func extractorReportsUndecodableKeysRatherThanFailingSilently() async throws {
    let (defaults, cleanup) = makeTestDefaults()
    defer { cleanup() }

    defaults.set(Data("not json".utf8), forKey: InvoiceTextStore.defaultsKey)

    let state = LibraryStateExtractor.extract(defaults: defaults)

    #expect(state.extractedTextByContentHash.isEmpty)
    #expect(state.undecodableKeys == [InvoiceTextStore.defaultsKey])
}

@Test func extractorDoesNotReachIntoRealSuitesFromAnInjectedDomain() async throws {
    let (defaults, cleanup) = makeTestDefaults()
    defer { cleanup() }

    // The real user's library may well have data under these keys; an injected
    // domain must never see it.
    let state = LibraryStateExtractor.extract(defaults: defaults)

    #expect(state.isEmpty)
}

// MARK: - Dump serialization

@Test func dumpRoundTripsRawStateLosslessly() async throws {
    // A fractional-second timestamp is the case ISO8601 encoding would truncate.
    let extractedAt = Date(timeIntervalSinceReferenceDate: 811_253_992.649_29)
    let raw = LegacyLibraryState(
        workflowByArtifactID: [
            "artifact-1": StoredInvoiceWorkflow(
                vendor: "Sysco",
                invoiceDate: nil,
                invoiceNumber: "256174208",
                isInProgress: false
            ),
        ],
        identityMapByPath: ["/Processed/a.pdf": "artifact-1"],
        extractedTextByContentHash: [
            "hash-a": InvoiceTextRecord(text: "total due", firstPageText: "total due", source: .ocr, ocrConfidence: 0.87),
        ],
        structuredDataByContentHash: [
            "hash-a": InvoiceStructuredDataRecord(
                companyName: "Sysco",
                invoiceNumber: "256174208",
                invoiceDate: nil,
                provider: .lmStudio,
                modelName: "qwen",
                extractedAt: extractedAt
            ),
        ],
        separatedContentHashPairs: [ContentHashPair("hash-a", "hash-b")],
        undecodableKeys: []
    )

    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let dump = LibraryStateDump(raw: raw, computed: nil)
    let url = try dump.write(to: LibraryStateDump.fileURL(in: directory, capturedAt: dump.capturedAt))
    let decoded = try LibraryStateDump.read(from: url)

    #expect(decoded.schemaVersion == LibraryStateDump.currentSchemaVersion)
    #expect(decoded.raw == raw)
    #expect(decoded.computed == nil)
    #expect(decoded.raw.structuredDataByContentHash["hash-a"]?.extractedAt == extractedAt)
}

@Test func dumpFilenameIsSafeForFinder() async throws {
    let directory = URL(fileURLWithPath: "/tmp/diagnostics")
    let capturedAt = Date(timeIntervalSince1970: 1_789_000_000)

    let url = LibraryStateDump.fileURL(in: directory, capturedAt: capturedAt)

    #expect(!url.lastPathComponent.contains(":"))
    #expect(url.lastPathComponent.hasPrefix("state-"))
    #expect(url.pathExtension == "json")
}

@Test func addingComputedKeepsTheRawSectionAndCaptureTime() async throws {
    let dump = LibraryStateDump(raw: .empty, computed: nil)
    let computed = ComputedLibraryState(
        artifacts: [
            ComputedArtifactState(
                artifactID: "artifact-1",
                path: "/Processed/a.pdf",
                location: .processed,
                status: .processed,
                contentHash: "hash-a",
                vendor: "Sysco",
                invoiceDate: nil,
                invoiceNumber: "256174208",
                documentType: .invoice
            ),
        ],
        files: []
    )

    let completed = dump.addingComputed(computed)

    #expect(completed.capturedAt == dump.capturedAt)
    #expect(completed.raw == dump.raw)
    #expect(completed.computed?.artifacts.first?.invoiceNumber == "256174208")
}

// MARK: - Diagnostic bundle

@Test func bundleCarriesTheScannedFoldersAndLeavesTheArchiveOut() async throws {
    let fileManager = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    func makeFolder(_ name: String, containing filename: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(name.utf8).write(to: url.appendingPathComponent(filename))
        return url
    }

    let settings = FolderSettings(
        inboxURL: try makeFolder("Inbox", containing: "incoming.pdf"),
        processedURL: try makeFolder("Processed", containing: "Sysco-2024-01-05-INV-1.pdf"),
        processingURL: try makeFolder("Processing", containing: "wip.pdf"),
        duplicatesURL: try makeFolder("Archive", containing: "dupe.pdf")
    )

    let destination = root.appendingPathComponent("bundle.zip")
    _ = try DiagnosticBundle.write(
        dump: LibraryStateDump(raw: .empty, computed: nil),
        folderSettings: settings,
        to: destination
    )
    #expect(fileManager.fileExists(atPath: destination.path))

    let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
    try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-x", "-k", destination.path, unpacked.path]
    try ditto.run()
    ditto.waitUntilExit()

    let bundle = unpacked.appendingPathComponent("bundle", isDirectory: true)
    func exists(_ relativePath: String) -> Bool {
        fileManager.fileExists(atPath: bundle.appendingPathComponent(relativePath).path)
    }

    #expect(exists("state.json"))
    #expect(exists("manifest.json"))
    #expect(exists("Inbox/incoming.pdf"))
    #expect(exists("Processing/wip.pdf"))
    #expect(exists("Processed/Sysco-2024-01-05-INV-1.pdf"))
    #expect(!exists("Archive"))

    let manifest = try JSONDecoder().decode(
        DiagnosticBundleManifest.self,
        from: Data(contentsOf: bundle.appendingPathComponent("manifest.json"))
    )
    #expect(manifest.roots.map(\.role).sorted { $0.rawValue < $1.rawValue } == [.inbox, .processed, .processing])
    #expect(manifest.roots.allSatisfy { $0.fileCount == 1 })
    // The original path is what lets a reader remap the bundle onto local folders.
    #expect(manifest.roots.first { $0.role == .processed }?.originalPath == settings.processedURL?.standardizedFileURL.path)
}

/// Progress arrives from the thread driving compression, so the test has to collect
/// it somewhere safe to read afterwards.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ value: Double) {
        lock.withLock { values.append(value) }
    }

    var recorded: [Double] {
        lock.withLock { values }
    }
}

@Test func bundleProgressRisesAndFinishesAtOne() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try Data(repeating: 7, count: 512_000).write(to: inbox.appendingPathComponent("incoming.pdf"))

    let progress = ProgressBox()
    _ = try DiagnosticBundle.write(
        dump: LibraryStateDump(raw: .empty, computed: nil),
        folderSettings: FolderSettings(inboxURL: inbox),
        to: root.appendingPathComponent("bundle.zip"),
        onProgress: { progress.record($0) }
    )

    let recorded = progress.recorded
    // A corpus this small compresses faster than the sampling interval, so the
    // only guaranteed reading is the terminal one.
    #expect(recorded.last == 1)
    #expect(recorded.allSatisfy { (0...1).contains($0) })
    #expect(recorded == recorded.sorted())
}

@Test func bundleSkipsAConfiguredFolderThatIsMissingOnDisk() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

    // A partial bundle diagnoses more than no bundle, and the manifest records
    // which roots were actually captured.
    let settings = FolderSettings(
        inboxURL: inbox,
        processedURL: root.appendingPathComponent("NeverSynced", isDirectory: true),
        processingURL: nil,
        duplicatesURL: nil
    )

    let destination = root.appendingPathComponent("partial.zip")
    _ = try DiagnosticBundle.write(
        dump: LibraryStateDump(raw: .empty, computed: nil),
        folderSettings: settings,
        to: destination
    )

    #expect(FileManager.default.fileExists(atPath: destination.path))
}
