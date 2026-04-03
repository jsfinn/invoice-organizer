import SwiftUI

struct QueueStatusCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Queue Status")
                .font(.headline)
            Text("Inbox, Processing, and Processed folders update automatically when files are added or removed.")
                .foregroundStyle(.secondary)
            Text(model.isWatchingFolders ? "Watching folders live" : "Folder watching unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
