import AppKit
import SwiftUI
struct PreviewRotationSaveResult: Sendable {
    let contentHash: String?
}

struct InvoicePreviewView: View {
    let invoice: InvoiceItem
    let rotationCoordinator: PreviewRotationCoordinator

    @AppStorage("preview.height") private var previewHeight = 620.0
    @AppStorage("preview.zoomScale") private var zoomScale = 1.0
    @AppStorage("preview.zoomToFit") private var zoomToFit = true
    @StateObject private var previewState: PreviewViewState
    @State private var resizeBaseHeight: Double?
    @State private var gestureBaseZoomScale: Double?

    init(
        invoice: InvoiceItem,
        rotationCoordinator: PreviewRotationCoordinator,
        assetProvider: any PreviewAssetProviding = PreviewAssetProvider.shared
    ) {
        self.invoice = invoice
        self.rotationCoordinator = rotationCoordinator
        _previewState = StateObject(
            wrappedValue: PreviewViewState(
                assetProvider: assetProvider,
                rotationCoordinator: rotationCoordinator
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PreviewRendererView(
                content: previewState.content,
                zoomScale: zoomScale,
                zoomToFit: zoomToFit,
                rotationQuarterTurns: previewState.temporaryRotationQuarterTurns,
                onChooseFit: applyFitZoom,
                onChooseZoomPreset: applyZoomPreset,
                onStepZoom: adjustZoom,
                onRotate: { delta in
                    previewState.rotate(by: delta, for: invoice)
                }
            )
            .frame(maxWidth: .infinity)
            .frame(height: previewHeight)
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if gestureBaseZoomScale == nil {
                            gestureBaseZoomScale = zoomToFit ? 1.0 : zoomScale
                            zoomToFit = false
                        }

                        let base = gestureBaseZoomScale ?? zoomScale
                        zoomScale = clampZoom(base * value.magnification)
                    }
                    .onEnded { _ in
                        gestureBaseZoomScale = nil
                    }
            )

            ResizeHandle()
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if resizeBaseHeight == nil {
                                resizeBaseHeight = previewHeight
                            }

                            let base = resizeBaseHeight ?? previewHeight
                            previewHeight = clampPreviewHeight(base + value.translation.height)
                        }
                        .onEnded { _ in
                            resizeBaseHeight = nil
                        }
                )
        }
        .task(id: PreviewLoadKey(invoice: invoice)) {
            await previewState.loadPreview(for: invoice)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            previewState.commitCurrentSessionIfNeeded()
        }
        .onDisappear {
            previewState.commitCurrentSessionIfNeeded()
        }
    }

    private func applyFitZoom() {
        zoomToFit = true
        zoomScale = 1.0
    }

    private func applyZoomPreset(_ preset: Double?) {
        guard let preset else {
            applyFitZoom()
            return
        }

        zoomToFit = false
        zoomScale = preset
    }

    private func adjustZoom(_ delta: Double) {
        let base = zoomToFit ? 1.0 : zoomScale
        zoomToFit = false
        zoomScale = clampZoom(base + delta)
    }

    private func clampPreviewHeight(_ value: Double) -> Double {
        min(max(value, 420), 1100)
    }

    private func clampZoom(_ value: Double) -> Double {
        min(max(value, 0.25), 4.0)
    }
}

private struct PreviewLoadKey: Hashable {
    let invoiceID: InvoiceItem.ID
    let fileURL: URL
    let contentHash: String?

    init(invoice: InvoiceItem) {
        invoiceID = invoice.id
        fileURL = invoice.fileURL
        contentHash = invoice.contentHash
    }
}

@MainActor
final class PreviewViewState: ObservableObject {
    @Published private(set) var content: PreviewContent = .loading
    @Published private(set) var temporaryRotationQuarterTurns = 0

    private let assetProvider: any PreviewAssetProviding
    private let rotationCoordinator: PreviewRotationCoordinator
    private var currentInvoiceID: InvoiceItem.ID?
    private var currentFileURL: URL?
    private var currentContentHash: String?

    init(
        assetProvider: any PreviewAssetProviding,
        rotationCoordinator: PreviewRotationCoordinator
    ) {
        self.assetProvider = assetProvider
        self.rotationCoordinator = rotationCoordinator
    }

    func loadPreview(for invoice: InvoiceItem) async {
        let isNewSelection = currentInvoiceID != invoice.id
        let isSameFile = currentFileURL == invoice.fileURL
        let isSameRevision = isSameFile && currentContentHash == invoice.contentHash

        if isNewSelection {
            rotationCoordinator.commitDraftIfNeeded(for: currentInvoiceID)
        }

        currentInvoiceID = invoice.id
        currentFileURL = invoice.fileURL
        currentContentHash = invoice.contentHash
        temporaryRotationQuarterTurns = rotationCoordinator.quarterTurns(for: invoice.id)

        if isSameRevision, case .asset = content {
            return
        }

        if !isSameFile || !hasLoadedAsset {
            content = .loading
        }

        do {
            let asset = try await assetProvider.asset(
                for: invoice.fileURL,
                contentHash: invoice.contentHash,
                fileType: invoice.fileType,
                forceReload: false
            )
            guard !Task.isCancelled,
                  currentInvoiceID == invoice.id,
                  currentFileURL == invoice.fileURL,
                  currentContentHash == invoice.contentHash else {
                return
            }
            content = .asset(asset)
        } catch is CancellationError {
            return
        } catch {
            guard currentInvoiceID == invoice.id,
                  currentFileURL == invoice.fileURL else {
                return
            }
            guard !isSameFile || !hasLoadedAsset else {
                return
            }
            let title = invoice.fileType == .pdf ? "Unable To Open PDF" : "Unable To Open Image"
            content = .error(title: title, message: error.localizedDescription)
        }
    }

    func rotate(by quarterTurnsDelta: Int, for invoice: InvoiceItem) {
        let updatedRotation = normalizedPreviewRotationQuarterTurns(
            temporaryRotationQuarterTurns + quarterTurnsDelta
        )
        guard updatedRotation != temporaryRotationQuarterTurns else {
            return
        }

        temporaryRotationQuarterTurns = updatedRotation
        rotationCoordinator.updateDraft(for: invoice, quarterTurns: updatedRotation)
    }

    func commitCurrentSessionIfNeeded() {
        rotationCoordinator.commitDraftIfNeeded(for: currentInvoiceID)
    }

    private var hasLoadedAsset: Bool {
        if case .asset = content {
            return true
        }
        return false
    }

}

private struct ResizeHandle: View {
    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 44, height: 6)
            Text("Drag to resize")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}
