import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Menu command that packages the library state together with the files it
/// describes, so a library can be reproduced somewhere else.
///
/// The save panel runs before the export rather than after it. The bundle carries
/// the whole processed archive, and writing that somewhere temporary only to copy
/// it again would move those bytes twice.
struct ExportDiagnosticBundleView: View {
    @ObservedObject var model: AppModel

    @State private var isExporting = false
    @State private var failureMessage: String?

    var body: some View {
        Button(isExporting ? "Exporting Diagnostic Bundle…" : "Export Diagnostic Bundle…") {
            Task { await export() }
        }
        .disabled(isExporting)
        .alert(
            "Could not export diagnostic bundle",
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

    private func export() async {
        let panel = NSSavePanel()
        panel.title = "Export Diagnostic Bundle"
        panel.nameFieldStringValue = DiagnosticBundle.suggestedFileName(capturedAt: Date())
        panel.allowedContentTypes = [.zip]
        panel.message = "Includes the library state and every file in "
            + DiagnosticBundle.includedRoles.map(\.rawValue).joined(separator: ", ")
            + ". The Archive folder is left out because nothing in it is ever scanned."

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        defer { isExporting = false }

        do {
            // Progress and the reveal both live in the status bar, so the menu is
            // done as soon as the work is.
            try await model.exportDiagnosticBundle(to: destination)
        } catch {
            failureMessage = error.localizedDescription
        }
    }
}
