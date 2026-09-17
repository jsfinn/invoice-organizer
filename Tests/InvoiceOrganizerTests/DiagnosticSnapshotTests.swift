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
