import AppKit
import SwiftUI

struct QueueSidebar: View {
    @ObservedObject var model: AppModel
    @State private var isUnprocessedDropTargeted = false
    @State private var isInProgressDropTargeted = false
    @State private var isProcessedDropTargeted = false

    private var activeTabContext: QueueTabContext {
        model.queueScreenContext.activeTabContext
    }

    private var selectedQueueTabBinding: Binding<InvoiceQueueTab> {
        Binding(
            get: { model.selectedQueueTab },
            set: { model.setSelectedQueueTab($0) }
        )
    }

    private var searchTextBinding: Binding<String> {
        Binding(
            get: { model.searchText },
            set: { model.setSearchText($0) }
        )
    }

    private var selectedArtifactIDsBinding: Binding<Set<PhysicalArtifact.ID>> {
        Binding(
            get: { model.selectedArtifactIDs },
            set: { model.setSelectedArtifactIDs($0) }
        )
    }

    private var browserContextBinding: Binding<InvoiceBrowserContext> {
        Binding(
            get: { model.activeBrowserContext },
            set: { model.setActiveBrowserContext($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            QueueStatusCard(model: model)

            HStack(spacing: 0) {
                ForEach(InvoiceQueueTab.allCases) { tab in
                    queueTabButton(for: tab)
                }
            }
            .padding(2)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 8) {
                TextField("Search name or vendor", text: searchTextBinding)
                    .textFieldStyle(.plain)

                if !activeTabContext.searchText.isEmpty {
                    Button {
                        model.setSearchText("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )

            HStack {
                Text("\(model.visibleArtifacts.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !activeTabContext.selectedArtifactIDs.isEmpty {
                    Text("• \(activeTabContext.selectedArtifactIDs.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if model.visibleArtifacts.isEmpty {
                ContentUnavailableView("No Invoices Found", systemImage: "tray")
            } else {
                InvoiceBrowserView(
                    invoices: model.visibleArtifacts,
                    documents: model.documents,
                    queueTab: model.selectedQueueTab,
                    browserContext: browserContextBinding,
                    ocrStatesByArtifactID: model.ocrStatesByArtifactID,
                    readStatesByArtifactID: model.readStatesByArtifactID,
                    documentMetadataByArtifactID: model.documentMetadataByArtifactID,
                    duplicateBadgeTitlesByArtifactID: model.duplicateBadgeTitlesByArtifactID,
                    possibleSameInvoiceBadgeTitlesByArtifactID: model.possibleSameInvoiceBadgeTitlesByArtifactID,
                    selectedArtifactIDs: selectedArtifactIDsBinding,
                    onMoveToInProgress: { orderedIDs in
                        model.moveInvoicesToInProgress(ids: orderedIDs)
                    },
                    onMoveToUnprocessed: {
                        model.moveInvoicesToUnprocessed(ids: model.selectedArtifactIDs)
                    },
                    onMoveToProcessed: {
                        model.moveInvoicesToProcessed(ids: model.selectedArtifactIDs)
                    },
                    onRescan: {
                        Task {
                            await model.rescanInvoices(ids: model.selectedArtifactIDs)
                        }
                    },
                    onArchive: { orderedIDs in
                        Task {
                            await model.archiveInvoices(ids: orderedIDs)
                        }
                    },
                    onJoinIntoPDF: { orderedIDs in
                        promptForJoinedPDFName(orderedIDs: orderedIDs)
                    },
                    onDuplicateForSeparateProcessing: { orderedIDs in
                        promptForSeparateCopyName(orderedIDs: orderedIDs)
                    },
                    onMarkNotDuplicate: { orderedIDs in
                        model.markArtifactsAsNotDuplicates(ids: orderedIDs)
                    },
                    onOpenInPreview: { orderedIDs in
                        model.openInPreview(ids: orderedIDs)
                    },
                    onShowInFinder: { orderedIDs in
                        model.showInFinder(ids: orderedIDs)
                    },
                    dragExportURL: { invoice in
                        try model.dragExportURL(for: invoice)
                    },
                    fileIcon: { invoice in
                        model.fileIcon(for: invoice)
                    }
                )
            }
        }
        .padding()
        .frame(minWidth: 680)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func promptForJoinedPDFName(orderedIDs: [PhysicalArtifact.ID]) {
        guard model.canJoinArtifactsIntoPDF(ids: orderedIDs) else { return }

        let defaultName = suggestedJoinedFileName(for: orderedIDs)

        let alert = NSAlert()
        alert.messageText = "Join \(orderedIDs.count) Files into PDF"
        alert.informativeText = "Pages will follow the current list order. The original files will be moved to your Archive folder."
        alert.addButton(withTitle: "Join")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        textField.stringValue = defaultName
        textField.placeholderString = "Joined Document"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let fileName = textField.stringValue
        Task {
            await model.joinArtifactsIntoPDF(ids: orderedIDs, fileName: fileName)
        }
    }

    private func promptForSeparateCopyName(orderedIDs: [PhysicalArtifact.ID]) {
        guard model.canDuplicateForSeparateProcessing(ids: orderedIDs),
              let id = orderedIDs.first else { return }

        let defaultName = suggestedSeparateCopyName(for: id)

        let alert = NSAlert()
        alert.messageText = "Split into a Separate Copy"
        alert.informativeText = "Creates an independent copy of this file so a second receipt can be processed and named separately. The original is left in place."
        alert.addButton(withTitle: "Create Copy")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = defaultName
        textField.placeholderString = "Copy"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let fileName = textField.stringValue
        Task {
            await model.duplicateForSeparateProcessing(id: id, fileName: fileName)
        }
    }

    private func suggestedSeparateCopyName(for id: PhysicalArtifact.ID) -> String {
        guard let artifact = model.invoices.first(where: { $0.id == id }) else {
            return "Copy"
        }

        let baseName = artifact.fileURL.deletingPathExtension().lastPathComponent
        return baseName.isEmpty ? "Copy" : "\(baseName) (2)"
    }

    private func suggestedJoinedFileName(for orderedIDs: [PhysicalArtifact.ID]) -> String {
        guard let firstID = orderedIDs.first,
              let artifact = model.invoices.first(where: { $0.id == firstID }) else {
            return "Joined Document"
        }

        let baseName = artifact.fileURL.deletingPathExtension().lastPathComponent
        return baseName.isEmpty ? "Joined Document" : baseName
    }

    @ViewBuilder
    private func queueTabButton(for tab: InvoiceQueueTab) -> some View {
        if tab == .unprocessed {
            baseQueueTabButton(for: tab)
                .onDrop(
                    of: [InvoiceInternalDrag.invoiceIDsType],
                    isTargeted: $isUnprocessedDropTargeted,
                    perform: handleUnprocessedDrop(providers:)
                )
        } else if tab == .inProgress {
            baseQueueTabButton(for: tab)
                .onDrop(
                    of: [InvoiceInternalDrag.invoiceIDsType],
                    isTargeted: $isInProgressDropTargeted,
                    perform: handleInProgressDrop(providers:)
                )
        } else if tab == .processed {
            baseQueueTabButton(for: tab)
                .onDrop(
                    of: [InvoiceInternalDrag.invoiceIDsType],
                    isTargeted: $isProcessedDropTargeted,
                    perform: handleProcessedDrop(providers:)
                )
        } else {
            baseQueueTabButton(for: tab)
        }
    }

    private func baseQueueTabButton(for tab: InvoiceQueueTab) -> some View {
        Text(tabLabel(for: tab))
            .font(.subheadline)
            .foregroundStyle(model.selectedQueueTab == tab || isDropTargeted(for: tab) ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor(for: tab))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture {
                selectedQueueTabBinding.wrappedValue = tab
            }
    }

    private func tabLabel(for tab: InvoiceQueueTab) -> String {
        switch tab {
        case .unprocessed:
            return "Unprocessed (\(model.unprocessedCount))"
        case .inProgress:
            return "In Progress (\(model.inProgressCount))"
        case .processed:
            return "Processed (\(model.processedCount))"
        }
    }

    private func isDropTargeted(for tab: InvoiceQueueTab) -> Bool {
        switch tab {
        case .unprocessed:
            return isUnprocessedDropTargeted
        case .inProgress:
            return isInProgressDropTargeted
        case .processed:
            return isProcessedDropTargeted
        }
    }

    private func backgroundColor(for tab: InvoiceQueueTab) -> Color {
        if isDropTargeted(for: tab) {
            return .accentColor.opacity(0.2)
        }

        if model.selectedQueueTab == tab {
            return Color(nsColor: .controlBackgroundColor)
        }

        return .clear
    }

    private func handleUnprocessedDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(InvoiceInternalDrag.invoiceIDsType.identifier)
        }) else {
            return false
        }

        let activeInvoiceIDs = InvoiceInternalDrag.consumeActiveInvoiceIDs()
        if !activeInvoiceIDs.isEmpty {
            model.moveInvoicesToUnprocessed(ids: Set(activeInvoiceIDs))
            return true
        }

        provider.loadDataRepresentation(forTypeIdentifier: InvoiceInternalDrag.invoiceIDsType.identifier) { data, _ in
            guard let data, let draggedIDs = InvoiceInternalDrag.decode(data), !draggedIDs.isEmpty else {
                return
            }

            Task { @MainActor in
                model.moveInvoicesToUnprocessed(ids: Set(draggedIDs))
            }
        }

        return true
    }

    private func handleInProgressDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(InvoiceInternalDrag.invoiceIDsType.identifier)
        }) else {
            return false
        }

        let activeInvoiceIDs = InvoiceInternalDrag.consumeActiveInvoiceIDs()
        if !activeInvoiceIDs.isEmpty {
            model.moveInvoicesToInProgress(ids: activeInvoiceIDs)
            return true
        }

        provider.loadDataRepresentation(forTypeIdentifier: InvoiceInternalDrag.invoiceIDsType.identifier) { data, _ in
            guard let data, let draggedIDs = InvoiceInternalDrag.decode(data), !draggedIDs.isEmpty else {
                return
            }

            Task { @MainActor in
                model.moveInvoicesToInProgress(ids: draggedIDs)
            }
        }

        return true
    }

    private func handleProcessedDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(InvoiceInternalDrag.invoiceIDsType.identifier)
        }) else {
            return false
        }

        let activeInvoiceIDs = InvoiceInternalDrag.consumeActiveInvoiceIDs()
        if !activeInvoiceIDs.isEmpty {
            model.moveInvoicesToProcessed(ids: Set(activeInvoiceIDs))
            return true
        }

        provider.loadDataRepresentation(forTypeIdentifier: InvoiceInternalDrag.invoiceIDsType.identifier) { data, _ in
            guard let data, let draggedIDs = InvoiceInternalDrag.decode(data), !draggedIDs.isEmpty else {
                return
            }

            Task { @MainActor in
                model.moveInvoicesToProcessed(ids: Set(draggedIDs))
            }
        }

        return true
    }
}
