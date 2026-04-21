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
                    structuredQueueCount: model.structuredQueueDepth,
                    heicQueue: model.heicConversionQueue,
                    onOpenHEICHistory: model.markHEICConversionActivitySeen,
                    onSelectConvertedFile: model.revealConvertedFileInQueue(_:)
                )
            }
        }
    }
}

private struct StatusBarView: View {
    let ocrQueueCount: Int
    let structuredQueueCount: Int
    @ObservedObject var heicQueue: HEICConversionQueueModel
    let onOpenHEICHistory: () -> Void
    let onSelectConvertedFile: (HEICConvertedFile) -> Void
    @State private var isShowingHEICHistory = false

    var body: some View {
        HStack(spacing: 16) {
            label("OCR", count: ocrQueueCount)
            Divider().frame(height: 12)
            label("Structured Data Extraction", count: structuredQueueCount)
            Divider().frame(height: 12)
            Button {
                onOpenHEICHistory()
                isShowingHEICHistory = true
            } label: {
                label("HEIC to JPG", count: heicQueue.queueDepth)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        heicQueue.hasUnreadActivity
                            ? Color.blue.opacity(0.28)
                            : Color.clear
                    )
            )
            .popover(isPresented: $isShowingHEICHistory, arrowEdge: .top) {
                HEICConversionHistoryView(
                    convertedFiles: heicQueue.convertedFiles,
                    onSelectConvertedFile: onSelectConvertedFile
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 26)
        .padding(.trailing, 12)
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
            Text(count.formatted(.number.grouping(.never)))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
            Text("in queue")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

}

private struct HEICConversionHistoryView: View {
    let convertedFiles: [HEICConvertedFile]
    let onSelectConvertedFile: (HEICConvertedFile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HEIC to JPG conversions")
                .font(.headline)

            if convertedFiles.isEmpty {
                Text("No files have been converted yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(convertedFiles) { file in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(file.originalURL.lastPathComponent) -> \(file.convertedURL.lastPathComponent)")
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Text(file.convertedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Button("Show in file list") {
                                    onSelectConvertedFile(file)
                                }
                                .font(.system(size: 11))
                                .buttonStyle(.link)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(width: 420, height: 260, alignment: .topLeading)
    }
}
