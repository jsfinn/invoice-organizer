import SwiftUI

struct MetadataCard: View {
    @ObservedObject var model: AppModel
    let invoice: PhysicalArtifact

    private var document: Document? {
        model.document(for: invoice.id)
    }

    private var duplicateSimilarities: [DuplicateSimilarity] {
        model.duplicateSimilarities(for: invoice.id)
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
            if let extractedTextSourceLabel {
                LabeledContent("Text Source", value: extractedTextSourceLabel)
            }

            if let duplicateReason = invoice.duplicateReason {
                Text(duplicateReason)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if invoice.location != .processed {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dedup Scores")
                        .font(.headline)

                    Text("Threshold: \(model.duplicateSimilarityThreshold.formatted(.number.precision(.fractionLength(2))))")
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

                                    Text(similarity.score.formatted(.number.precision(.fractionLength(2))))
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
