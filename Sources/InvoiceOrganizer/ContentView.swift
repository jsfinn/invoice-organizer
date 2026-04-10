import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    let rotationCoordinator: PreviewRotationCoordinator

    var body: some View {
        Group {
            if model.hasRequiredFolders {
                NavigationSplitView {
                    QueueSidebar(model: model)
                } detail: {
                    InvoiceDetailView(model: model, rotationCoordinator: rotationCoordinator)
                }
            } else {
                SetupRequiredView()
            }
        }
        .navigationTitle("Invoice Organizer")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button("Refresh Inbox") {
                    model.refreshLibrary()
                }
                .disabled(model.folderSettings.inboxURL == nil)

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.hasRequiredFolders {
                StatusBarView(
                    ocrQueueCount: model.textQueueDepth,
                    llmQueueCount: model.structuredQueueDepth
                )
            }
        }
    }
}

private struct StatusBarView: View {
    let ocrQueueCount: Int
    let llmQueueCount: Int

    var body: some View {
        HStack(spacing: 16) {
            label("OCR", count: ocrQueueCount)
            Divider().frame(height: 12)
            label("LLM", count: llmQueueCount)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func label(_ title: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(count) in queue")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}
