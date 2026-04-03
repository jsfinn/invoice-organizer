import SwiftUI

struct MetadataCard: View {
    @ObservedObject var model: AppModel
    let invoice: InvoiceItem

    private var processedFolderPath: String? {
        switch invoice.location {
        case .inbox:
            return nil
        case .processing:
            let trimmedVendor = invoice.vendor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedVendor.isEmpty else { return "" }
            return ArchivePathBuilder.destinationFolder(
                root: model.folderSettings.processedURL ?? URL(fileURLWithPath: "/Processed"),
                vendor: invoice.vendor
            ).path
        case .processed:
            return ArchivePathBuilder.destinationFolder(
                root: model.folderSettings.processedURL ?? URL(fileURLWithPath: "/Processed"),
                vendor: invoice.vendor
            ).path
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Metadata")
                .font(.title3.bold())

            LabeledContent("Source Path", value: invoice.fileURL.path)
            if let processedFolderPath {
                LabeledContent("Processed Folder", value: processedFolderPath)
            }
            LabeledContent("Date Added", value: invoice.addedAt.formatted(date: .abbreviated, time: .shortened))

            if let duplicateReason = invoice.duplicateReason {
                Text(duplicateReason)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
