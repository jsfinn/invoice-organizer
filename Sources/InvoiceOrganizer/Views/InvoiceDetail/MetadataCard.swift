import SwiftUI

struct MetadataCard: View {
    @ObservedObject var model: AppModel
    let invoice: PhysicalArtifact
    @AppStorage(AppStorageKey.debugMode) private var debugMode = false
    @State private var isPossibleSameInvoiceExpanded = true
    @State private var isOCRInformationExpanded = false
    @State private var isDedupSummaryExpanded = false

    private var document: Document? {
        model.document(for: invoice.id)
    }

    private var documentMetadata: DocumentMetadata {
        model.documentMetadata(for: invoice.id)
    }

    private var dedupSummary: DedupSummary {
        model.dedupSummary(for: invoice.id)
    }

    private var duplicateSimilarities: [DuplicateSimilarity] {
        model.duplicateSimilarities(for: invoice.id)
    }

    private var possibleSameInvoiceMatches: [PossibleSameInvoiceMatch] {
        model.possibleSameInvoiceMatches(for: invoice.id)
    }

    private var processedFolderPath: String? {
        model.processedFolderPreviewPath(for: invoice)
    }

    private var extractedTextRecord: InvoiceTextRecord? {
        model.extractedTextRecord(for: invoice)
    }

    private var extractedTextSourceLabel: String? {
        guard let extractedTextRecord else { return nil }

        switch extractedTextRecord.source {
        case .pdfText:
            return "Embedded PDF Text"
        case .ocr:
            if let ocrConfidence = extractedTextRecord.ocrConfidence {
                return "OCR (Confidence \(ocrConfidence.formatted(.percent.precision(.fractionLength(0)))))"
            }
            return "OCR"
        }
    }

    private var shouldShowOCRComparison: Bool {
        guard let extractedTextRecord,
              extractedTextRecord.source == .ocr,
              let originalText = extractedTextRecord.ocrOriginalText else {
            return false
        }

        return originalText != extractedTextRecord.text
    }

    private var shouldShowOCRInformation: Bool {
        debugMode && (extractedTextSourceLabel != nil || shouldShowOCRComparison)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Metadata")
                .font(.title3.bold())

            if let document {
                LabeledContent("Document Members", value: "\(document.artifacts.count)")
            }
            LabeledContent("Source Path", value: model.sourcePathDisplay(for: invoice))
            if let processedFolderPath {
                LabeledContent("Processed Folder", value: processedFolderPath)
            }
            LabeledContent("Date Added", value: invoice.addedAt.formatted(date: .abbreviated, time: .shortened))

            if invoice.location != .processed && !possibleSameInvoiceMatches.isEmpty {
                collapsibleSection("Possible Same Invoice Matches", isExpanded: $isPossibleSameInvoiceExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(possibleSameInvoiceMatches) { match in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline) {
                                    Button {
                                        openPossibleSameInvoiceMatch(match)
                                    } label: {
                                        Text(match.matchedFileURL.lastPathComponent)
                                            .lineLimit(1)
                                    }
                                    .buttonStyle(.link)

                                    Spacer()

                                    Text(match.matchedLocation.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Text(match.artifactCount == 1
                                     ? "Matched document has 1 file"
                                     : "Matched document has \(match.artifactCount) files")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text("Matched fields: \(matchedFieldLabels(for: match).joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.footnote)
                        }
                    }
                    .padding(.top, 6)
                }
            }

            if shouldShowOCRInformation, let extractedTextRecord {
                collapsibleSection("OCR Information", isExpanded: $isOCRInformationExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let extractedTextSourceLabel {
                            LabeledContent("Text Source", value: extractedTextSourceLabel)
                                .font(.footnote)
                        }

                        if debugMode && shouldShowOCRComparison {
                            Text("OCR Comparison")
                                .font(.headline)
                            selectableTextBlock(extractedTextRecord.text)

                            Text("Original Vision Order")
                                .font(.headline)
                            selectableTextBlock(extractedTextRecord.ocrOriginalText ?? "")
                        }
                    }
                    .padding(.top, 6)
                }
            }

            if let duplicateReason = invoice.duplicateReason {
                Text(duplicateReason)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if debugMode && invoice.location != .processed {
                collapsibleSection("Dedup Summary", isExpanded: $isDedupSummaryExpanded) {
                    dedupSummaryContent
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func selectableTextBlock(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func collapsibleSection<Content: View>(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                content()
            }
        }
    }

    private func matchedFieldLabels(for match: PossibleSameInvoiceMatch) -> [String] {
        var labels: [String] = []

        if normalized(documentMetadata.vendor) == normalized(match.metadata.vendor) {
            labels.append("Vendor")
        }
        if documentMetadata.invoiceDate == match.metadata.invoiceDate {
            labels.append("Invoice Date")
        }
        if documentMetadata.documentType == match.metadata.documentType,
           documentMetadata.documentType != nil {
            labels.append("Document Type")
        }
        if normalized(documentMetadata.invoiceNumber) == normalized(match.metadata.invoiceNumber),
           normalized(documentMetadata.invoiceNumber) != nil {
            labels.append("Invoice Number")
        }

        return labels
    }

    @ViewBuilder
    private var dedupSummaryContent: some View {
        let summary = dedupSummary
        VStack(alignment: .leading, spacing: 8) {
            dedupGroupingRow(summary.groupingStatus)

            if let desc = summary.identityDescription {
                LabeledContent("Identity", value: desc)
                    .font(.footnote)
            } else {
                LabeledContent("Identity", value: extractionStateLabel(summary.extractionState))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Text Threshold", value: model.duplicateSimilarityThreshold.formatted(.percent.precision(.fractionLength(0))))
                .font(.footnote)
                .foregroundStyle(.secondary)

            if summary.comparisons.isEmpty {
                Text("No comparable documents found.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Divider()
                Text("Comparisons")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(summary.comparisons) { comparison in
                    dedupComparisonRow(comparison)
                }
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func dedupGroupingRow(_ status: DedupSummary.GroupingStatus) -> some View {
        switch status {
        case .singleton:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                Text("Not grouped — unique document")
            }
            .font(.footnote)
        case .identicalCopy(let ref):
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc.fill")
                    .foregroundStyle(.orange)
                Text("Identical copy of \(ref)")
                    .lineLimit(2)
            }
            .font(.footnote)
        case .duplicateGrouped(let ref, let reason):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.merge")
                        .foregroundStyle(.orange)
                    Text("Grouped with \(ref)")
                        .lineLimit(2)
                }
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
        }
    }

    @ViewBuilder
    private func dedupComparisonRow(_ comparison: DedupComparison) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(comparison.fileName)
                    .lineLimit(1)
                Spacer()
                Text(comparison.location.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                if let score = comparison.textScore {
                    Text("Text: \(score.formatted(.percent.precision(.fractionLength(0))))")
                        .foregroundStyle(score >= model.duplicateSimilarityThreshold ? .primary : .secondary)
                }
                if let relation = comparison.identityRelation {
                    Text(identityRelationLabel(relation))
                        .foregroundStyle(identityRelationColor(relation))
                }
            }
            .font(.caption)

            Text(decisionLabel(comparison.decision))
                .font(.caption)
                .foregroundStyle(decisionColor(comparison.decision))
        }
        .font(.footnote)
        .padding(.vertical, 2)
    }

    private func extractionStateLabel(_ state: DedupSummary.ExtractionState) -> String {
        switch state {
        case .notStarted: return "Not yet extracted"
        case .textOnly: return "Text only (structured pending)"
        case .complete: return "Extraction complete — no identity resolved"
        }
    }

    private func identityRelationLabel(_ relation: DedupComparison.IdentityRelation) -> String {
        switch relation {
        case .positiveMatch: return "Identity: match"
        case .conflict(let reason): return reason
        case .noIdentity: return "Identity: partial"
        }
    }

    private func identityRelationColor(_ relation: DedupComparison.IdentityRelation) -> Color {
        switch relation {
        case .positiveMatch: return .green
        case .conflict: return .orange
        case .noIdentity: return .yellow
        }
    }

    private func decisionLabel(_ decision: DedupComparison.Decision) -> String {
        switch decision {
        case .grouped: return "→ Grouped"
        case .vetoed(let reason): return "→ Vetoed: \(reason)"
        case .belowThreshold: return "→ Below threshold"
        case .pending(let reason): return "→ Pending: \(reason)"
        }
    }

    private func decisionColor(_ decision: DedupComparison.Decision) -> Color {
        switch decision {
        case .grouped: return .green
        case .vetoed: return .orange
        case .belowThreshold: return .secondary
        case .pending: return .yellow
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    private func openPossibleSameInvoiceMatch(_ match: PossibleSameInvoiceMatch) {
        model.setSelectedQueueTab(queueTab(for: match.matchedLocation))
        model.setSelectedArtifactIDs([match.matchedArtifactID])
        model.setSelectedArtifactID(match.matchedArtifactID)
    }

    private func queueTab(for location: InvoiceLocation) -> InvoiceQueueTab {
        switch location {
        case .inbox:
            return .unprocessed
        case .processing:
            return .inProgress
        case .processed:
            return .processed
        }
    }
}
