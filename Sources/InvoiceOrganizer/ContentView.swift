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
    }
}
