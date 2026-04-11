import AppKit
import SwiftUI

struct InvoicePreviewView: View {
    let invoice: PhysicalArtifact
    @ObservedObject var previewState: PreviewViewState

    @AppStorage("preview.height") private var previewHeight = 620.0
    @State private var zoomScale = 1.0
    @State private var zoomToFit = true
    @State private var resizeBaseHeight: Double?
    @State private var gestureBaseZoomScale: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReplacementPreviewRendererView(
                sessionID: previewState.sessionID ?? PreviewSessionID(invoice: invoice),
                content: previewState.content,
                viewport: viewport,
                rotationQuarterTurns: previewState.rotationQuarterTurns,
                onChooseFit: applyFitZoom,
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
    }

    private var viewport: PreviewViewport {
        zoomToFit ? .fit : .scale(zoomScale)
    }

    private func applyFitZoom() {
        zoomToFit = true
        zoomScale = 1.0
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
