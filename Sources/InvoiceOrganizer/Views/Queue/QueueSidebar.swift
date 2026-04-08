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

    private var showIgnoredInvoicesBinding: Binding<Bool> {
        Binding(
            get: { model.showIgnoredInvoices },
            set: { model.setShowIgnoredInvoices($0) }
        )
    }

    private var selectedInvoiceIDsBinding: Binding<Set<InvoiceItem.ID>> {
        Binding(
            get: { model.selectedInvoiceIDs },
            set: { model.setSelectedInvoiceIDs($0) }
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
                Text("\(model.visibleInvoices.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !activeTabContext.selectedInvoiceIDs.isEmpty {
                    Text("• \(activeTabContext.selectedInvoiceIDs.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.hiddenIgnoredCountInVisibleQueue > 0 {
                    Text("• \(model.hiddenIgnoredCountInVisibleQueue) ignored hidden")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("Show Ignored", isOn: showIgnoredInvoicesBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if model.visibleInvoices.isEmpty {
                ContentUnavailableView("No Invoices Found", systemImage: "tray")
            } else {
                InvoiceBrowserView(
                    invoices: model.visibleInvoices,
                    documents: model.documents,
                    queueTab: model.selectedQueueTab,
                    browserContext: browserContextBinding,
                    ocrStatesByInvoiceID: model.ocrStatesByInvoiceID,
                    readStatesByInvoiceID: model.readStatesByInvoiceID,
                    duplicateBadgeTitlesByInvoiceID: model.duplicateBadgeTitlesByInvoiceID,
                    ignoredInvoiceIDs: model.ignoredInvoiceIDs,
                    selectedInvoiceIDs: selectedInvoiceIDsBinding,
                    onMoveToInProgress: { orderedIDs in
                        model.moveInvoicesToInProgress(ids: orderedIDs)
                    },
                    onMoveToUnprocessed: {
                        model.moveInvoicesToUnprocessed(ids: model.selectedInvoiceIDs)
                    },
                    onMoveToProcessed: {
                        model.moveInvoicesToProcessed(ids: model.selectedInvoiceIDs)
                    },
                    onRescan: {
                        Task {
                            await model.rescanInvoices(ids: model.selectedInvoiceIDs)
                        }
                    },
                    onSetIgnored: { ignored in
                        model.setIgnored(ignored, for: model.selectedInvoiceIDs)
                    },
                    onVendorChange: { invoiceID, vendor in
                        model.updateVendor(vendor, for: invoiceID)
                    },
                    onInvoiceDateChange: { invoiceID, invoiceDate in
                        model.updateInvoiceDate(invoiceDate, for: invoiceID)
                    }
                )
            }
        }
        .padding()
        .frame(minWidth: 680)
        .frame(maxHeight: .infinity, alignment: .topLeading)
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
