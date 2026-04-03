import SwiftUI

struct SetupRequiredView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Choose Folders To Begin", systemImage: "folder.badge.gearshape")
        } description: {
            Text("Open Settings and choose your Inbox, Processing, and Processed folders before loading invoices.")
        } actions: {
            SettingsLink {
                Text("Open Settings")
            }
        }
    }
}
