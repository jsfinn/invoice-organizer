import Foundation
import Testing
@testable import InvoiceOrganizer

private func localDate(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    return calendar.date(
        from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
    )!
}

private func artifact(
    id: String,
    name: String,
    location: InvoiceLocation,
    status: InvoiceStatus
) -> PhysicalArtifact {
    PhysicalArtifact(
        id: id,
        name: name,
        fileURL: URL(fileURLWithPath: "/\(location.rawValue)/\(name)"),
        location: location,
        addedAt: Date(timeIntervalSince1970: 1),
        fileType: .pdf,
        status: status,
        contentHash: id
    )
}

private func metadata(
    vendor: String?,
    date: Date?,
    number: String?
) -> DocumentMetadata {
    DocumentMetadata(
        vendor: vendor,
        invoiceDate: date,
        invoiceNumber: number,
        documentType: .invoice
    )
}

@Test func processedInvoiceCollisionMatchesVendorDateAndInvoiceNumber() {
    let processed = artifact(
        id: "processed-1",
        name: "acme.pdf",
        location: .processed,
        status: .processed
    )
    let inProgress = artifact(
        id: "in-progress-1",
        name: "incoming.pdf",
        location: .processing,
        status: .inProgress
    )
    let invoiceDate = localDate(year: 2024, month: 1, day: 5)

    let match = ProcessedInvoiceCollision.firstMatch(
        metadata: metadata(vendor: "Acme Corp", date: invoiceDate, number: "INV-42"),
        artifacts: [processed, inProgress],
        metadataByArtifactID: [
            processed.id: metadata(vendor: "Acme Corp", date: invoiceDate, number: "INV-42"),
            inProgress.id: metadata(vendor: "Other", date: invoiceDate, number: "INV-99")
        ],
        excludingArtifactID: inProgress.id
    )

    #expect(match?.id == processed.id)
}

@Test func processedInvoiceCollisionIgnoresVendorAndInvoiceNumberCaseAndWhitespace() {
    let processed = artifact(
        id: "processed-1",
        name: "acme.pdf",
        location: .processed,
        status: .processed
    )
    let invoiceDate = localDate(year: 2024, month: 1, day: 5)

    let match = ProcessedInvoiceCollision.firstMatch(
        metadata: metadata(vendor: "  ACME CORP ", date: invoiceDate, number: " inv-42 "),
        artifacts: [processed],
        metadataByArtifactID: [
            processed.id: metadata(vendor: "acme corp", date: invoiceDate, number: "INV-42")
        ],
        excludingArtifactID: "in-progress-1"
    )

    #expect(match?.id == processed.id)
}

@Test func processedInvoiceCollisionTreatsSameLocalCalendarDayAsEqual() {
    let processed = artifact(
        id: "processed-1",
        name: "acme.pdf",
        location: .processed,
        status: .processed
    )

    let match = ProcessedInvoiceCollision.firstMatch(
        metadata: metadata(
            vendor: "Acme Corp",
            date: localDate(year: 2024, month: 1, day: 5, hour: 9, minute: 30),
            number: "INV-42"
        ),
        artifacts: [processed],
        metadataByArtifactID: [
            processed.id: metadata(
                vendor: "Acme Corp",
                date: localDate(year: 2024, month: 1, day: 5, hour: 18),
                number: "INV-42"
            )
        ],
        excludingArtifactID: "in-progress-1"
    )

    #expect(match?.id == processed.id)
}

@Test func processedInvoiceCollisionIgnoresInProgressAndUnprocessedPeers() {
    let inProgressPeer = artifact(
        id: "peer-in-progress",
        name: "peer.pdf",
        location: .processing,
        status: .inProgress
    )
    let inboxPeer = artifact(
        id: "peer-inbox",
        name: "inbox.pdf",
        location: .inbox,
        status: .unprocessed
    )
    let invoiceDate = localDate(year: 2024, month: 1, day: 5)
    let shared = metadata(vendor: "Acme Corp", date: invoiceDate, number: "INV-42")

    let match = ProcessedInvoiceCollision.firstMatch(
        metadata: shared,
        artifacts: [inProgressPeer, inboxPeer],
        metadataByArtifactID: [
            inProgressPeer.id: shared,
            inboxPeer.id: shared
        ],
        excludingArtifactID: "current"
    )

    #expect(match == nil)
}

@Test func processedInvoiceCollisionDoesNotMatchMissingInvoiceNumber() {
    let processed = artifact(
        id: "processed-1",
        name: "acme.pdf",
        location: .processed,
        status: .processed
    )
    let invoiceDate = localDate(year: 2024, month: 1, day: 5)

    let match = ProcessedInvoiceCollision.firstMatch(
        metadata: metadata(vendor: "Acme Corp", date: invoiceDate, number: nil),
        artifacts: [processed],
        metadataByArtifactID: [
            processed.id: metadata(vendor: "Acme Corp", date: invoiceDate, number: nil)
        ],
        excludingArtifactID: "in-progress-1"
    )

    #expect(match == nil)
}

@Test func processedInvoiceCollisionDoesNotMatchDifferentInvoiceNumber() {
    let processed = artifact(
        id: "processed-1",
        name: "acme.pdf",
        location: .processed,
        status: .processed
    )
    let invoiceDate = localDate(year: 2024, month: 1, day: 5)

    let match = ProcessedInvoiceCollision.firstMatch(
        metadata: metadata(vendor: "Acme Corp", date: invoiceDate, number: "INV-99"),
        artifacts: [processed],
        metadataByArtifactID: [
            processed.id: metadata(vendor: "Acme Corp", date: invoiceDate, number: "INV-42")
        ],
        excludingArtifactID: "in-progress-1"
    )

    #expect(match == nil)
}

@Test func processedInvoiceCollisionIgnoresTheCurrentArtifact() {
    let processed = artifact(
        id: "processed-1",
        name: "acme.pdf",
        location: .processed,
        status: .processed
    )
    let invoiceDate = localDate(year: 2024, month: 1, day: 5)
    let shared = metadata(vendor: "Acme Corp", date: invoiceDate, number: "INV-42")

    let match = ProcessedInvoiceCollision.firstMatch(
        metadata: shared,
        artifacts: [processed],
        metadataByArtifactID: [processed.id: shared],
        excludingArtifactID: processed.id
    )

    #expect(match == nil)
}
