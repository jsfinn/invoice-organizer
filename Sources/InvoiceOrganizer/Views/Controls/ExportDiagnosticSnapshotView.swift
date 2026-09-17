import AppKit
import SwiftUI

/// Menu command that writes a fresh diagnostic dump and offers to save a copy
/// somewhere the user can find it.
///
/// The dump always lands in the diagnostics folder first, so a cancelled save panel
/// still leaves a usable file behind.
struct ExportDiagnosticSnapshotView: View {
    @ObservedObject var model: AppModel

    @State private var failureMessage: String?

    var body: some View {
        Button("Export Diagnostic Snapshot…", action: export)
            .alert(
                "Could not export diagnostic snapshot",
                isPresented: Binding(
                    get: { failureMessage != nil },
                    set: { if !$0 { failureMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { failureMessage = nil }
            } message: {
                Text(failureMessage ?? "")
            }
    }

    private func export() {
        let url: URL
        do {
            url = try model.exportDiagnosticSnapshot()
        } catch {
            failureMessage = error.localizedDescription
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Diagnostic Snapshot"
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [.json]
        panel.message = "A copy has already been saved to the diagnostics folder."

        guard panel.runModal() == .OK, let destination = panel.url else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            failureMessage = error.localizedDescription
        }
    }
}
