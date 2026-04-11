import AppKit
import SwiftUI

struct InvoiceDetailView: View {
    @ObservedObject var model: AppModel
    let rotationCoordinator: PreviewRotationCoordinator
    @StateObject private var previewState: PreviewViewState

    init(model: AppModel, rotationCoordinator: PreviewRotationCoordinator) {
        self._model = ObservedObject(wrappedValue: model)
        self.rotationCoordinator = rotationCoordinator
        _previewState = StateObject(
            wrappedValue: PreviewViewState(
                assetProvider: PreviewAssetProvider.shared,
                rotationCoordinator: rotationCoordinator
            )
        )
    }

    var body: some View {
        Group {
            if let invoice = model.selectedArtifact {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        PreviewCard(previewState: previewState, invoice: invoice)
                        DataEntryCard(model: model, previewState: previewState, invoice: invoice)
                        MetadataCard(model: model, invoice: invoice)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .task(id: PreviewSessionID(invoice: invoice)) {
                    let metadata = model.documentMetadata(for: invoice.id)
                    await previewState.loadPreview(for: invoice, metadata: metadata)
                }
                .onChange(of: invoice.id) { _, _ in
                    previewState.syncArtifactReference(
                        invoice,
                        metadata: model.documentMetadata(for: invoice.id)
                    )
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            previewState.scheduleCommitCurrentSessionIfNeeded()
        }
        .onDisappear {
            previewState.scheduleCommitCurrentSessionIfNeeded()
        }
        .task {
            previewState.metadataFlushHandler = { [weak model] artifactID, metadata in
                model?.applyBufferedMetadata(metadata, for: artifactID)
            }
            model.metadataFlushGuard = { [weak previewState] in
                previewState?.flushMetadataImmediately()
            }
        }
    }
}
