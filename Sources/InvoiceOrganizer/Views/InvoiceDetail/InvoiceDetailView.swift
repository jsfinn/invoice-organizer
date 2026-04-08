import SwiftUI

struct InvoiceDetailView: View {
    @ObservedObject var model: AppModel
    let rotationCoordinator: PreviewRotationCoordinator

    var body: some View {
        Group {
            if let invoice = model.selectedArtifact {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        PreviewCard(model: model, rotationCoordinator: rotationCoordinator, invoice: invoice)
                        DataEntryCard(model: model, invoice: invoice)
                        MetadataCard(model: model, invoice: invoice)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let errorMessage = model.settingsErrorMessage {
                VStack(alignment: .center, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Unable To Load Invoices")
                        .font(.title3.bold())
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ContentUnavailableView("Select a Invoice", systemImage: "tray")
            }
        }
    }
}
