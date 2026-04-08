import SwiftUI

struct MetadataCard: View {
    @ObservedObject var model: AppModel
    let invoice: PhysicalArtifact

    private var document: Document? {
        model.document(for: invoice.id)
    }

    private var duplicateSimilarities: [InvoiceDuplicateSimilarity] {
        model.duplicateSimilarities(for: invoice.id)
    }

    private var processedFolderPath: String? {
        model.processedFolderPreviewPath(for: invoice)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Metadata")
                .font(.title3.bold())

            if let document {
                LabeledContent("Document Members", value: "\(document.members.count)")
            }
            LabeledContent("Source Path", value: model.sourcePathDisplay(for: invoice))
            if let processedFolderPath {
                LabeledContent("Processed Folder", value: processedFolderPath)
            }
            LabeledContent("Date Added", value: invoice.addedAt.formatted(date: .abbreviated, time: .shortened))

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

                                Text(similarity.memberCount == 1
                                     ? "Best match in 1-file document"
                                     : "Best match in \(similarity.memberCount)-file document")
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
