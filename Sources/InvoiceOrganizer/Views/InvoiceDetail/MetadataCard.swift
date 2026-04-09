import SwiftUI

struct MetadataCard: View {
    @ObservedObject var model: AppModel
    let invoice: PhysicalArtifact
    @AppStorage(AppStorageKey.debugMode) private var debugMode = false
    @State private var isPossibleSameInvoiceExpanded = true
    @State private var isOCRInformationExpanded = false
    @State private var isDedupScoresExpanded = false

    private var document: Document? {
        model.document(for: invoice.id)
    }

    private var documentMetadata: DocumentMetadata {
        model.documentMetadata(for: invoice.id)
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
                collapsibleSection("Dedup Scores", isExpanded: $isDedupScoresExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Threshold: \(model.duplicateSimilarityThreshold.formatted(.percent.precision(.fractionLength(0))))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if !model.extractedTextArtifactIDs.contains(invoice.id) {
                            Text("Score unavailable until OCR/extracted text finishes.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else if duplicateSimilarities.isEmpty {
                            Text("No comparable extracted-text matches found yet.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(duplicateSimilarities) { similarity in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(similarity.matchedFileURL.lastPathComponent)
                                            .lineLimit(1)

                                        Spacer()

                                        Text(similarity.score.formatted(.percent.precision(.fractionLength(0))))
                                            .foregroundStyle(similarity.meetsThreshold ? .primary : .secondary)
                                    }

                                    Text(similarity.artifactCount == 1
                                         ? "Best match in 1-file document"
                                         : "Best match in \(similarity.artifactCount)-file document")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .font(.footnote)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
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
            .textSelection(.enabled)
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
