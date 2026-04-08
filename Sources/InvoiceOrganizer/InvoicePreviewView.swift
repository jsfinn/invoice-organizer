import AppKit
import SwiftUI

struct InvoicePreviewView: View {
    let invoice: PhysicalArtifact
    let rotationCoordinator: PreviewRotationCoordinator

    @AppStorage("preview.height") private var previewHeight = 620.0
    @AppStorage("preview.zoomScale") private var zoomScale = 1.0
    @AppStorage("preview.zoomToFit") private var zoomToFit = true
    @StateObject private var previewState: PreviewViewState
    @State private var resizeBaseHeight: Double?
    @State private var gestureBaseZoomScale: Double?

    init(
        invoice: PhysicalArtifact,
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
            ReplacementPreviewRendererView(
                sessionID: previewState.sessionID ?? PreviewSessionID(invoice: invoice),
                content: previewState.content,
                viewport: viewport,
                rotationQuarterTurns: previewState.rotationQuarterTurns,
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
        .task(id: PreviewSessionID(invoice: invoice)) {
            await previewState.loadPreview(for: invoice)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            previewState.scheduleCommitCurrentSessionIfNeeded()
        }
        .onDisappear {
            previewState.scheduleCommitCurrentSessionIfNeeded()
        }
    }

    private var viewport: PreviewViewport {
        zoomToFit ? .fit : .scale(zoomScale)
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
