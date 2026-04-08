import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InvoiceBrowserView: NSViewRepresentable {
    let invoices: [PhysicalArtifact]
    let documents: [Document]
    let queueTab: InvoiceQueueTab
    @Binding var browserContext: InvoiceBrowserContext
    let ocrStatesByArtifactID: [PhysicalArtifact.ID: InvoiceOCRState]
    let readStatesByArtifactID: [PhysicalArtifact.ID: InvoiceReadState]
    let duplicateBadgeTitlesByArtifactID: [PhysicalArtifact.ID: String]
    let ignoredArtifactIDs: Set<PhysicalArtifact.ID>
    @Binding var selectedArtifactIDs: Set<PhysicalArtifact.ID>
    let onMoveToInProgress: ([PhysicalArtifact.ID]) -> Void
    let onMoveToUnprocessed: () -> Void
    let onMoveToProcessed: () -> Void
    let onRescan: () -> Void
    let onSetIgnored: (Bool) -> Void
    let onVendorChange: (PhysicalArtifact.ID, String) -> Void
    let onInvoiceDateChange: (PhysicalArtifact.ID, Date) -> Void
    let dragExportURL: (PhysicalArtifact) throws -> URL
    let fileIcon: (PhysicalArtifact) -> NSImage

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.windowBackgroundColor

        let tableView = FinderLikeTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.headerView = NSTableHeaderView()
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = 28
        tableView.intercellSpacing = NSSize(width: 8, height: 4)
        tableView.focusRingType = .none
        tableView.selectionHighlightStyle = .regular
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.contextMenuProvider = { [weak coordinator = context.coordinator] row in
            coordinator?.contextMenu(forRow: row)
        }
        tableView.disclosureNavigationHandler = { [weak coordinator = context.coordinator] keyCode in
            coordinator?.handleDisclosureNavigation(keyCode: keyCode) ?? false
        }

        Self.configureColumns(for: tableView, queueTab: queueTab)

        context.coordinator.tableView = tableView
        scrollView.documentView = tableView

        context.coordinator.update(
            invoices: invoices,
            documents: documents,
            ocrStatesByArtifactID: ocrStatesByArtifactID,
            readStatesByArtifactID: readStatesByArtifactID,
            selectedIDs: selectedArtifactIDs
        )
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let tableView = context.coordinator.tableView {
            Self.configureColumns(for: tableView, queueTab: queueTab)
        }
        context.coordinator.update(
            invoices: invoices,
            documents: documents,
            ocrStatesByArtifactID: ocrStatesByArtifactID,
            readStatesByArtifactID: readStatesByArtifactID,
            selectedIDs: selectedArtifactIDs
        )
    }

    private static func makeColumns() -> [NSTableColumn] {
        InvoiceBrowserColumnID.allCases.map(makeColumn)
    }

    private static func makeColumn(id: InvoiceBrowserColumnID) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id.rawValue))
        column.title = id.title
        column.width = id.width
        column.minWidth = id.minWidth
        column.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: id.ascending)
        return column
    }

    private static func configureColumns(for tableView: NSTableView, queueTab: InvoiceQueueTab) {
        let desiredColumnIDs = visibleColumnIDs(for: queueTab)
        let existingColumnIDs = tableView.tableColumns.compactMap { InvoiceBrowserColumnID(rawValue: $0.identifier.rawValue) }

        guard existingColumnIDs != desiredColumnIDs else { return }

        tableView.tableColumns.forEach(tableView.removeTableColumn)
        desiredColumnIDs
            .map(makeColumn)
            .forEach(tableView.addTableColumn)
    }

    private static func visibleColumnIDs(for queueTab: InvoiceQueueTab) -> [InvoiceBrowserColumnID] {
        invoiceBrowserVisibleColumnIDs(for: queueTab)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: InvoiceBrowserView
        weak var tableView: FinderLikeTableView?
        private var displayedRows: [InvoiceBrowserRow] = []
        private var ocrStatesByArtifactID: [PhysicalArtifact.ID: InvoiceOCRState] = [:]
        private var readStatesByArtifactID: [PhysicalArtifact.ID: InvoiceReadState] = [:]
        private var isSyncingSelection = false

        init(parent: InvoiceBrowserView) {
            self.parent = parent
        }

        func update(
            invoices: [PhysicalArtifact],
            documents: [Document],
            ocrStatesByArtifactID: [PhysicalArtifact.ID: InvoiceOCRState],
            readStatesByArtifactID: [PhysicalArtifact.ID: InvoiceReadState],
            selectedIDs: Set<PhysicalArtifact.ID>
        ) {
            let didStateChange = self.ocrStatesByArtifactID != ocrStatesByArtifactID || self.readStatesByArtifactID != readStatesByArtifactID
            self.ocrStatesByArtifactID = ocrStatesByArtifactID
            self.readStatesByArtifactID = readStatesByArtifactID
            syncTableSortDescriptorsFromContext()
            let sortedInvoices = sort(invoices: invoices)
            let nextRows = buildInvoiceBrowserRows(
                from: sortedInvoices,
                documents: documents,
                expandedGroupIDs: parent.browserContext.expandedGroupIDs
            )
            if displayedRows != nextRows {
                displayedRows = nextRows
                tableView?.reloadData()
            } else if didStateChange {
                tableView?.reloadData()
            }
            syncSelection(to: selectedIDs)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            displayedRows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < displayedRows.count, let tableColumn else { return nil }

            let rowModel = displayedRows[row]
            let invoice = rowModel.invoice
            guard let columnID = InvoiceBrowserColumnID(rawValue: tableColumn.identifier.rawValue) else { return nil }

            switch columnID {
            case .name:
                let view = tableView.makeView(withIdentifier: NameCellView.reuseIdentifier, owner: nil) as? NameCellView ?? NameCellView()
                view.configure(
                    with: invoice,
                    icon: parent.fileIcon(invoice),
                    disclosureState: rowModel.disclosureState,
                    indentationLevel: rowModel.indentationLevel,
                    badges: badges(for: rowModel)
                ) { [weak self] in
                    self?.toggleExpansion(for: rowModel)
                }
                return view
            case .addedAt:
                let view = tableView.makeView(withIdentifier: TextCellView.reuseIdentifier, owner: nil) as? TextCellView ?? TextCellView()
                view.configure(text: invoice.addedAt.formatted(date: .abbreviated, time: .shortened), secondary: true)
                return view
            case .ocr:
                let view = tableView.makeView(withIdentifier: TextCellView.reuseIdentifier, owner: nil) as? TextCellView ?? TextCellView()
                view.configure(state: ocrStatesByArtifactID[invoice.id])
                return view
            case .read:
                let view = tableView.makeView(withIdentifier: TextCellView.reuseIdentifier, owner: nil) as? TextCellView ?? TextCellView()
                view.configure(state: readStatesByArtifactID[invoice.id])
                return view
            case .fileType:
                let view = tableView.makeView(withIdentifier: TextCellView.reuseIdentifier, owner: nil) as? TextCellView ?? TextCellView()
                view.configure(text: invoice.fileType.rawValue, secondary: true)
                return view
            case .vendor:
                if parent.queueTab == .inProgress && rowModel.isDirectInvoiceRow {
                    let view = tableView.makeView(withIdentifier: EditableTextCellView.reuseIdentifier, owner: nil) as? EditableTextCellView ?? EditableTextCellView()
                    view.configure(
                        invoiceID: invoice.id,
                        text: invoice.vendor ?? "",
                        placeholder: "Vendor",
                        onCommit: parent.onVendorChange
                    )
                    return view
                } else {
                    let view = tableView.makeView(withIdentifier: TextCellView.reuseIdentifier, owner: nil) as? TextCellView ?? TextCellView()
                    view.configure(text: invoice.vendor ?? "\u{2014}", secondary: invoice.vendor != nil, tertiary: invoice.vendor == nil)
                    return view
                }
            case .invoiceDate:
                if parent.queueTab == .inProgress && rowModel.isDirectInvoiceRow {
                    let view = tableView.makeView(withIdentifier: EditableDateCellView.reuseIdentifier, owner: nil) as? EditableDateCellView ?? EditableDateCellView()
                    view.configure(
                        invoiceID: invoice.id,
                        date: invoice.invoiceDate ?? invoice.addedAt,
                        onCommit: parent.onInvoiceDateChange
                    )
                    return view
                } else {
                    let view = tableView.makeView(withIdentifier: TextCellView.reuseIdentifier, owner: nil) as? TextCellView ?? TextCellView()
                    view.configure(
                        text: invoice.invoiceDate?.formatted(date: .abbreviated, time: .omitted) ?? "\u{2014}",
                        secondary: invoice.invoiceDate != nil,
                        tertiary: invoice.invoiceDate == nil
                    )
                    return view
                }
            }
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            FinderLikeRowView(row: row)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView, !isSyncingSelection else { return }

            let ids = Set<PhysicalArtifact.ID>(tableView.selectedRowIndexes.compactMap { row in
                guard row >= 0, row < displayedRows.count else { return nil }
                return displayedRows[row].invoice.id
            })

            guard parent.selectedArtifactIDs != ids else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.selectedArtifactIDs = ids
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            let resolvedSortDescriptors = resolvedInvoiceBrowserSortDescriptors(
                invoiceBrowserSortDescriptors(from: tableView.sortDescriptors),
                for: parent.queueTab
            )
            parent.browserContext.sortDescriptors = resolvedSortDescriptors

            let resolvedNSSortDescriptors = nsSortDescriptors(from: resolvedSortDescriptors)
            if !nSSortDescriptorsMatch(tableView.sortDescriptors, resolvedNSSortDescriptors) {
                tableView.sortDescriptors = resolvedNSSortDescriptors
            }

            displayedRows = buildInvoiceBrowserRows(
                from: sort(invoices: parent.invoices),
                documents: parent.documents,
                expandedGroupIDs: parent.browserContext.expandedGroupIDs
            )
            tableView.reloadData()
            syncSelection(to: parent.selectedArtifactIDs)
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard row >= 0, row < displayedRows.count else { return nil }

            let invoice = displayedRows[row].invoice
            guard invoice.canDragBetweenQueues || invoice.canDragToQuickBooks else { return nil }

            do {
                let draggedIDs = idsForDragStarting(at: row)
                InvoiceInternalDrag.beginDrag(draggedIDs)
                let dragURL = try parent.dragExportURL(invoice)
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setString(dragURL.absoluteString, forType: .fileURL)

                if let data = InvoiceInternalDrag.encode(draggedIDs) {
                    pasteboardItem.setData(data, forType: NSPasteboard.PasteboardType(InvoiceInternalDrag.invoiceIDsType.identifier))
                }

                return pasteboardItem
            } catch {
                NSSound.beep()
                return nil
            }
        }

        func tableView(_ tableView: NSTableView, canDragRowsWith rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
            guard let nameColumnIndex = tableView.tableColumns.firstIndex(where: {
                $0.identifier.rawValue == InvoiceBrowserColumnID.name.rawValue
            }) else {
                return false
            }

            let clickedColumn = tableView.column(at: mouseDownPoint)
            let canDragSelection = rowIndexes.contains { index in
                index >= 0 && index < displayedRows.count && displayedRows[index].invoice.canDragBetweenQueues
            }

            return clickedColumn == nameColumnIndex && canDragSelection
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forRowIndexes rowIndexes: IndexSet
        ) {
            (tableView as? FinderLikeTableView)?.didBeginDragDuringMouseInteraction = true
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            (tableView as? FinderLikeTableView)?.didBeginDragDuringMouseInteraction = false
        }

        private func idsForDragStarting(at row: Int) -> [PhysicalArtifact.ID] {
            let selectedIDs = parent.selectedArtifactIDs
            let selection = selectedIDs.contains(displayedRows[row].invoice.id)
                ? displayedRows.map(\.invoice).filter { selectedIDs.contains($0.id) }
                : [displayedRows[row].invoice]

            return selection.map(\.id)
        }

        private func orderedSelectedInvoiceIDs() -> [PhysicalArtifact.ID] {
            displayedRows
                .map(\.invoice.id)
                .filter { parent.selectedArtifactIDs.contains($0) }
        }

        func contextMenu(forRow row: Int) -> NSMenu? {
            guard row >= 0, row < displayedRows.count, let tableView else {
                return nil
            }

            let clickedInvoiceID = displayedRows[row].invoice.id
            if !parent.selectedArtifactIDs.contains(clickedInvoiceID) {
                parent.selectedArtifactIDs = [clickedInvoiceID]
                syncSelection(to: parent.selectedArtifactIDs)
            }

            let selectedArtifacts = parent.invoices.filter { parent.selectedArtifactIDs.contains($0.id) }
            let menu = NSMenu()
            let canRescan = parent.queueTab != .processed && selectedArtifacts.contains { $0.contentHash != nil }
            let allIgnored = !selectedArtifacts.isEmpty && selectedArtifacts.allSatisfy { parent.ignoredArtifactIDs.contains($0.id) }

            switch parent.queueTab {
            case .unprocessed:
                guard selectedArtifacts.contains(where: \.canMoveToInProgress) || canRescan || !selectedArtifacts.isEmpty else {
                    return nil
                }

                if selectedArtifacts.contains(where: \.canMoveToInProgress) {
                    let item = NSMenuItem(title: "Move to In Progress", action: #selector(moveSelectionToInProgress), keyEquivalent: "")
                    item.target = self
                    menu.addItem(item)
                }
            case .inProgress:
                guard selectedArtifacts.contains(where: \.canMarkDone) || canRescan || !selectedArtifacts.isEmpty else {
                    return nil
                }

                if selectedArtifacts.contains(where: \.canMarkDone) {
                    let moveToUnprocessedItem = NSMenuItem(title: "Move to Unprocessed", action: #selector(moveSelectionToUnprocessed), keyEquivalent: "")
                    moveToUnprocessedItem.target = self
                    menu.addItem(moveToUnprocessedItem)

                    let moveToProcessedItem = NSMenuItem(title: "Move to Processed", action: #selector(moveSelectionToProcessed), keyEquivalent: "")
                    moveToProcessedItem.target = self
                    menu.addItem(moveToProcessedItem)
                }
            case .processed:
                guard !selectedArtifacts.isEmpty else {
                    return nil
                }
            }

            if canRescan {
                if menu.items.isEmpty == false {
                    menu.addItem(.separator())
                }

                let rescanItem = NSMenuItem(title: "Re-scan", action: #selector(rescanSelection), keyEquivalent: "")
                rescanItem.target = self
                menu.addItem(rescanItem)
            }

            if !selectedArtifacts.isEmpty {
                if menu.items.isEmpty == false {
                    menu.addItem(.separator())
                }

                let ignoreTitle = allIgnored ? "Unignore" : "Ignore"
                let ignoreItem = NSMenuItem(title: ignoreTitle, action: #selector(toggleIgnoredSelection(_:)), keyEquivalent: "")
                ignoreItem.target = self
                ignoreItem.representedObject = allIgnored
                menu.addItem(ignoreItem)
            }

            tableView.menu = menu
            return menu
        }

        @objc
        private func moveSelectionToInProgress() {
            parent.onMoveToInProgress(orderedSelectedInvoiceIDs())
        }

        @objc
        private func moveSelectionToUnprocessed() {
            parent.onMoveToUnprocessed()
        }

        @objc
        private func moveSelectionToProcessed() {
            parent.onMoveToProcessed()
        }

        @objc
        private func rescanSelection() {
            parent.onRescan()
        }

        @objc
        private func toggleIgnoredSelection(_ sender: NSMenuItem) {
            let currentlyIgnored = (sender.representedObject as? Bool) ?? false
            parent.onSetIgnored(!currentlyIgnored)
        }

        private func syncSelection(to selectedIDs: Set<PhysicalArtifact.ID>) {
            guard let tableView else { return }

            let rowIndexes = IndexSet(displayedRows.enumerated().compactMap { index, row in
                switch row.kind {
                case .invoice, .groupChild:
                    return selectedIDs.contains(row.invoice.id) ? index : nil
                case .groupHeader:
                    if row.disclosureState == .collapsed {
                        return row.artifactIDs.isDisjoint(with: selectedIDs) ? nil : index
                    }
                    return selectedIDs.contains(row.invoice.id) ? index : nil
                }
            })

            guard tableView.selectedRowIndexes != rowIndexes else { return }

            isSyncingSelection = true
            tableView.selectRowIndexes(rowIndexes, byExtendingSelection: false)
            isSyncingSelection = false
        }

        private func toggleExpansion(for row: InvoiceBrowserRow) {
            guard case let .groupHeader(duplicateCount) = row.kind, duplicateCount > 0 else {
                return
            }

            var expandedGroupIDs = parent.browserContext.expandedGroupIDs
            if expandedGroupIDs.contains(row.invoice.id) {
                expandedGroupIDs.remove(row.invoice.id)
            } else {
                expandedGroupIDs.insert(row.invoice.id)
            }

            parent.browserContext.expandedGroupIDs = expandedGroupIDs
            displayedRows = buildInvoiceBrowserRows(
                from: sort(invoices: parent.invoices),
                documents: parent.documents,
                expandedGroupIDs: parent.browserContext.expandedGroupIDs
            )
            tableView?.reloadData()
            syncSelection(to: parent.selectedArtifactIDs)
        }

        func handleDisclosureNavigation(keyCode: UInt16) -> Bool {
            guard let tableView else { return false }

            let selectedRow = tableView.selectedRow
            guard selectedRow >= 0, selectedRow < displayedRows.count else { return false }

            guard let action = disclosureNavigationAction(for: displayedRows[selectedRow], keyCode: keyCode) else {
                return false
            }

            switch action {
            case .expand(let invoiceID), .collapse(let invoiceID):
                guard let row = displayedRows.first(where: { $0.invoice.id == invoiceID }) else { return false }
                toggleExpansion(for: row)
                if let headerIndex = displayedRows.firstIndex(where: { $0.invoice.id == invoiceID }) {
                    tableView.selectRowIndexes(IndexSet(integer: headerIndex), byExtendingSelection: false)
                }
                return true
            case .selectParent(let parentID):
                guard let parentIndex = displayedRows.firstIndex(where: { $0.invoice.id == parentID }) else {
                    return false
                }
                tableView.selectRowIndexes(IndexSet(integer: parentIndex), byExtendingSelection: false)
                return true
            }
        }

        private func badges(for row: InvoiceBrowserRow) -> [InvoiceBrowserBadge] {
            var badges: [InvoiceBrowserBadge] = []

            if case let .groupHeader(duplicateCount) = row.kind, duplicateCount > 0 {
                let label = duplicateGroupHeaderBadgeTitle(
                    for: row,
                    duplicateCount: duplicateCount,
                    documents: parent.documents,
                    queueTab: parent.queueTab
                )
                badges.append(.duplicate(label))
            } else if let duplicateBadge = parent.duplicateBadgeTitlesByArtifactID[row.invoice.id] {
                badges.append(.duplicate(duplicateBadge))
            }

            if parent.ignoredArtifactIDs.contains(row.invoice.id) {
                badges.append(.ignored)
            }

            return badges
        }

        private func sort(invoices: [PhysicalArtifact]) -> [PhysicalArtifact] {
            invoices.sorted { lhs, rhs in
                for descriptor in parent.browserContext.sortDescriptors {
                    let comparison = compare(lhs: lhs, rhs: rhs, columnID: descriptor.columnID)
                    if comparison != .orderedSame {
                        return descriptor.ascending
                            ? comparison == .orderedAscending
                            : comparison == .orderedDescending
                    }
                }

                return lhs.addedAt > rhs.addedAt
            }
        }

        private func syncTableSortDescriptorsFromContext() {
            let resolvedSortDescriptors = resolvedInvoiceBrowserSortDescriptors(
                parent.browserContext.sortDescriptors,
                for: parent.queueTab
            )

            if parent.browserContext.sortDescriptors != resolvedSortDescriptors {
                parent.browserContext.sortDescriptors = resolvedSortDescriptors
            }

            guard let tableView else { return }
            let resolvedNSSortDescriptors = nsSortDescriptors(from: resolvedSortDescriptors)
            if !nSSortDescriptorsMatch(tableView.sortDescriptors, resolvedNSSortDescriptors) {
                tableView.sortDescriptors = resolvedNSSortDescriptors
            }
        }

        private func compare(
            lhs: PhysicalArtifact,
            rhs: PhysicalArtifact,
            columnID: InvoiceBrowserColumnID
        ) -> ComparisonResult {
            switch columnID {
            case .name:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            case .addedAt:
                if lhs.addedAt == rhs.addedAt { return .orderedSame }
                return lhs.addedAt < rhs.addedAt ? .orderedAscending : .orderedDescending
            case .ocr:
                return compareOCRState(lhs: ocrStatesByArtifactID[lhs.id], rhs: ocrStatesByArtifactID[rhs.id])
            case .read:
                return compareReadState(lhs: readStatesByArtifactID[lhs.id], rhs: readStatesByArtifactID[rhs.id])
            case .fileType:
                return lhs.fileType.rawValue.localizedCaseInsensitiveCompare(rhs.fileType.rawValue)
            case .vendor:
                return (lhs.vendor ?? "").localizedCaseInsensitiveCompare(rhs.vendor ?? "")
            case .invoiceDate:
                let lhsDate = lhs.invoiceDate ?? lhs.addedAt
                let rhsDate = rhs.invoiceDate ?? rhs.addedAt
                if lhsDate == rhsDate { return .orderedSame }
                return lhsDate < rhsDate ? .orderedAscending : .orderedDescending
            }
        }

        private func compareOCRState(lhs: InvoiceOCRState?, rhs: InvoiceOCRState?) -> ComparisonResult {
            func rank(for state: InvoiceOCRState?) -> Int {
                switch state ?? .waiting {
                case .success: return 0
                case .waiting: return 1
                case .failed: return 2
                }
            }

            let lhsRank = rank(for: lhs)
            let rhsRank = rank(for: rhs)
            if lhsRank == rhsRank { return .orderedSame }
            return lhsRank < rhsRank ? .orderedAscending : .orderedDescending
        }

        private func compareReadState(lhs: InvoiceReadState?, rhs: InvoiceReadState?) -> ComparisonResult {
            func rank(for state: InvoiceReadState?) -> Int {
                switch state ?? .waiting {
                case .success: return 0
                case .review: return 1
                case .waiting: return 2
                case .failed: return 3
                }
            }

            let lhsRank = rank(for: lhs)
            let rhsRank = rank(for: rhs)
            if lhsRank == rhsRank { return .orderedSame }
            return lhsRank < rhsRank ? .orderedAscending : .orderedDescending
        }
    }
}

func duplicateGroupHeaderBadgeTitle(
    for row: InvoiceBrowserRow,
    duplicateCount: Int,
    documents: [Document],
    queueTab: InvoiceQueueTab
) -> String {
    let defaultLabel = duplicateCount == 1 ? "1 duplicate" : "\(duplicateCount) duplicates"
    guard queueTab == .unprocessed,
          documents.contains(where: { $0.contains(artifactID: row.invoice.id) && $0.hasProcessedMember }) else {
        return defaultLabel
    }

    return duplicateCount == 1
        ? "1 Duplicate - processed"
        : "\(duplicateCount) Duplicates - processed"
}

private extension InvoiceBrowserColumnID {
    var title: String {
        switch self {
        case .name:
            return "Name"
        case .ocr:
            return "OCR"
        case .read:
            return "Read"
        case .addedAt:
            return "Added"
        case .fileType:
            return "Type"
        case .vendor:
            return "Vendor"
        case .invoiceDate:
            return "Invoice Date"
        }
    }

    var width: CGFloat {
        switch self {
        case .name:
            return 320
        case .ocr:
            return 50
        case .read:
            return 55
        case .addedAt:
            return 150
        case .fileType:
            return 90
        case .vendor:
            return 150
        case .invoiceDate:
            return 140
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name:
            return 220
        case .ocr:
            return 44
        case .read:
            return 50
        case .addedAt:
            return 110
        case .fileType:
            return 80
        case .vendor:
            return 110
        case .invoiceDate:
            return 120
        }
    }

    var ascending: Bool {
        switch self {
        case .addedAt, .invoiceDate:
            return false
        case .name, .ocr, .read, .fileType, .vendor:
            return true
        }
    }
}

private func invoiceBrowserSortDescriptors(from descriptors: [NSSortDescriptor]) -> [InvoiceBrowserSortDescriptor] {
    descriptors.compactMap { descriptor in
        guard let key = descriptor.key,
              let columnID = InvoiceBrowserColumnID(rawValue: key) else {
            return nil
        }

        return InvoiceBrowserSortDescriptor(columnID: columnID, ascending: descriptor.ascending)
    }
}

private func nsSortDescriptors(from descriptors: [InvoiceBrowserSortDescriptor]) -> [NSSortDescriptor] {
    descriptors.map { descriptor in
        NSSortDescriptor(key: descriptor.columnID.rawValue, ascending: descriptor.ascending)
    }
}

private func nSSortDescriptorsMatch(_ lhs: [NSSortDescriptor], _ rhs: [NSSortDescriptor]) -> Bool {
    guard lhs.count == rhs.count else { return false }

    return zip(lhs, rhs).allSatisfy { lhsDescriptor, rhsDescriptor in
        lhsDescriptor.key == rhsDescriptor.key &&
        lhsDescriptor.ascending == rhsDescriptor.ascending
    }
}

func shouldCollapseSelectionAfterMouseInteraction(
    row: Int,
    modifierFlags: NSEvent.ModifierFlags,
    didBeginDrag: Bool
) -> Bool {
    guard row >= 0, didBeginDrag == false else { return false }
    let selectionModifiers = modifierFlags.intersection([.command, .shift])
    return selectionModifiers.isEmpty
}

enum InvoiceBrowserDisclosureState: Equatable {
    case hidden
    case collapsed
    case expanded
}

enum InvoiceBrowserRowKind: Equatable {
    case invoice
    case groupHeader(duplicateCount: Int)
    case groupChild(parentID: PhysicalArtifact.ID)
}

struct InvoiceBrowserRow: Equatable {
    let invoice: PhysicalArtifact
    let kind: InvoiceBrowserRowKind
    let artifactIDs: Set<PhysicalArtifact.ID>
    let indentationLevel: Int
    let disclosureState: InvoiceBrowserDisclosureState

    var isDirectInvoiceRow: Bool {
        switch kind {
        case .invoice, .groupChild:
            return true
        case .groupHeader:
            return false
        }
    }
}

enum InvoiceBrowserDisclosureNavigationAction: Equatable {
    case expand(PhysicalArtifact.ID)
    case collapse(PhysicalArtifact.ID)
    case selectParent(PhysicalArtifact.ID)
}

func disclosureNavigationAction(for row: InvoiceBrowserRow, keyCode: UInt16) -> InvoiceBrowserDisclosureNavigationAction? {
    switch (row.kind, row.disclosureState, keyCode) {
    case (.groupHeader, .collapsed, 124):
        return .expand(row.invoice.id)
    case (.groupHeader, .expanded, 123):
        return .collapse(row.invoice.id)
    case (.groupChild(let parentID), _, 123):
        return .selectParent(parentID)
    default:
        return nil
    }
}

enum InvoiceBrowserBadge: Equatable {
    case duplicate(String)
    case ignored

    var title: String {
        switch self {
        case .duplicate(let title):
            return title
        case .ignored:
            return "Ignored"
        }
    }

    var textColor: NSColor {
        switch self {
        case .duplicate:
            return .systemRed
        case .ignored:
            return .systemOrange
        }
    }

    var backgroundColor: NSColor {
        switch self {
        case .duplicate:
            return NSColor.systemRed.withAlphaComponent(0.12)
        case .ignored:
            return NSColor.systemOrange.withAlphaComponent(0.14)
        }
    }
}

func buildInvoiceBrowserRows(
    from invoices: [PhysicalArtifact],
    documents: [Document],
    expandedGroupIDs: Set<PhysicalArtifact.ID>
) -> [InvoiceBrowserRow] {
    let visibleArtifactsByID = Dictionary(uniqueKeysWithValues: invoices.map { ($0.id, $0) })
    var childrenByRepresentativeID: [PhysicalArtifact.ID: [PhysicalArtifact]] = [:]

    for document in documents where document.isDuplicate {
        let visibleMembers = invoices.filter { document.artifactIDs.contains($0.id) && visibleArtifactsByID[$0.id] != nil }
        guard visibleMembers.count > 1,
              let representative = visibleMembers.first else {
            continue
        }

        childrenByRepresentativeID[representative.id] = Array(visibleMembers.dropFirst())
    }

    var rows: [InvoiceBrowserRow] = []
    let groupedChildIDs = Set(childrenByRepresentativeID.values.flatMap { $0.map(\.id) })

    for invoice in invoices {
        if groupedChildIDs.contains(invoice.id) {
            continue
        }

        guard let children = childrenByRepresentativeID[invoice.id], !children.isEmpty else {
            rows.append(
                InvoiceBrowserRow(
                    invoice: invoice,
                    kind: .invoice,
                    artifactIDs: Set([invoice.id]),
                    indentationLevel: 0,
                    disclosureState: .hidden
                )
            )
            continue
        }

        let isExpanded = expandedGroupIDs.contains(invoice.id)
        rows.append(
            InvoiceBrowserRow(
                invoice: invoice,
                kind: .groupHeader(duplicateCount: children.count),
                artifactIDs: Set([invoice.id] + children.map(\.id)),
                indentationLevel: 0,
                disclosureState: isExpanded ? .expanded : .collapsed
            )
        )

        if isExpanded {
            rows.append(
                contentsOf: children.map { child in
                    InvoiceBrowserRow(
                        invoice: child,
                        kind: .groupChild(parentID: invoice.id),
                        artifactIDs: Set([child.id]),
                        indentationLevel: 1,
                        disclosureState: .hidden
                    )
                }
            )
        }
    }

    return rows
}

final class FinderLikeTableView: NSTableView {
    var contextMenuProvider: ((Int) -> NSMenu?)?
    var disclosureNavigationHandler: ((UInt16) -> Bool)?
    var didBeginDragDuringMouseInteraction = false

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        didBeginDragDuringMouseInteraction = false

        super.mouseDown(with: event)

        if shouldCollapseSelectionAfterMouseInteraction(
            row: clickedRow,
            modifierFlags: modifierFlags,
            didBeginDrag: didBeginDragDuringMouseInteraction
        ) {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        didBeginDragDuringMouseInteraction = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        return contextMenuProvider?(row)
    }

    override func keyDown(with event: NSEvent) {
        if let disclosureNavigationHandler,
           (event.keyCode == 123 || event.keyCode == 124),
           disclosureNavigationHandler(event.keyCode) {
            return
        }

        super.keyDown(with: event)
    }
}

private final class FinderLikeRowView: NSTableRowView {
    private let row: Int

    init(row: Int) {
        self.row = row
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        self.row = 0
        super.init(coder: coder)
        wantsLayer = true
    }

    override var isEmphasized: Bool {
        get { false }
        set { }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        let color = row.isMultiple(of: 2)
            ? NSColor.white
            : NSColor(calibratedWhite: 0.965, alpha: 1.0)
        color.setFill()
        dirtyRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let selectionRect = bounds.insetBy(dx: 3, dy: 1)
        let path = NSBezierPath(roundedRect: selectionRect, xRadius: 6, yRadius: 6)
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).setFill()
        path.fill()
    }
}

private final class NameCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("NameCellView")

    private let disclosureButton = NSButton()
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let stackView = NSStackView()
    private let badgeStackView = NSStackView()
    private var stackLeadingConstraint: NSLayoutConstraint?
    private var onToggleDisclosure: (() -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        identifier = Self.reuseIdentifier
        setup()
    }

    func configure(
        with invoice: PhysicalArtifact,
        icon: NSImage,
        disclosureState: InvoiceBrowserDisclosureState,
        indentationLevel: Int,
        badges: [InvoiceBrowserBadge],
        onToggleDisclosure: (() -> Void)?
    ) {
        iconView.image = icon
        nameField.stringValue = invoice.name
        self.onToggleDisclosure = onToggleDisclosure
        configureDisclosure(disclosureState)
        stackLeadingConstraint?.constant = 6 + CGFloat(indentationLevel * 16)
        renderBadges(badges)
    }

    private func setup() {
        disclosureButton.isBordered = false
        disclosureButton.bezelStyle = .regularSquare
        disclosureButton.setButtonType(.momentaryChange)
        disclosureButton.imagePosition = .imageOnly
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleDisclosure)

        iconView.imageScaling = .scaleProportionallyDown

        nameField.lineBreakMode = .byTruncatingMiddle

        badgeStackView.orientation = .horizontal
        badgeStackView.alignment = .centerY
        badgeStackView.spacing = 6
        badgeStackView.setContentCompressionResistancePriority(.required, for: .horizontal)

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(disclosureButton)
        stackView.addArrangedSubview(iconView)
        stackView.addArrangedSubview(nameField)
        stackView.addArrangedSubview(badgeStackView)

        addSubview(stackView)

        let leadingConstraint = stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)
        stackLeadingConstraint = leadingConstraint

        NSLayoutConstraint.activate([
            leadingConstraint,
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            disclosureButton.widthAnchor.constraint(equalToConstant: 14),
            disclosureButton.heightAnchor.constraint(equalToConstant: 14),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    private func configureDisclosure(_ disclosureState: InvoiceBrowserDisclosureState) {
        switch disclosureState {
        case .hidden:
            disclosureButton.isHidden = true
            disclosureButton.image = nil
        case .collapsed:
            disclosureButton.isHidden = false
            disclosureButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Expand duplicates")
        case .expanded:
            disclosureButton.isHidden = false
            disclosureButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Collapse duplicates")
        }
    }

    private func renderBadges(_ badges: [InvoiceBrowserBadge]) {
        badgeStackView.arrangedSubviews.forEach { view in
            badgeStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for badge in badges {
            let label = NSTextField(labelWithString: badge.title)
            label.font = .systemFont(ofSize: 11)
            label.drawsBackground = true
            label.isBezeled = false
            label.isBordered = false
            label.isEditable = false
            label.focusRingType = .none
            label.wantsLayer = true
            label.layer?.cornerRadius = 9
            label.lineBreakMode = .byClipping
            label.textColor = badge.textColor
            label.backgroundColor = badge.backgroundColor
            badgeStackView.addArrangedSubview(label)
        }
    }

    @objc
    private func toggleDisclosure() {
        onToggleDisclosure?()
    }
}

private final class TextCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("TextCellView")

    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func configure(text: String, secondary: Bool = false, tertiary: Bool = false, emphasized: Bool = false) {
        label.stringValue = text
        if emphasized {
            label.textColor = .systemGreen
        } else if tertiary {
            label.textColor = .tertiaryLabelColor
        } else if secondary {
            label.textColor = .secondaryLabelColor
        } else {
            label.textColor = .labelColor
        }
    }

    func configure(state: InvoiceOCRState?) {
        switch state {
        case .success?:
            configure(text: "OK", emphasized: true)
        case .failed?:
            configure(text: "X")
            label.textColor = .systemRed
        case .waiting?, nil:
            configure(text: "...")
            label.textColor = .secondaryLabelColor
        }
    }

    func configure(state: InvoiceReadState?) {
        switch state {
        case .success?:
            configure(text: "OK", emphasized: true)
        case .review?:
            configure(text: "?")
            label.textColor = .systemOrange
        case .failed?:
            configure(text: "X")
            label.textColor = .systemRed
        case .waiting?, nil:
            configure(text: "...")
            label.textColor = .secondaryLabelColor
        }
    }
}

private final class EditableTextCellView: NSTableCellView, NSTextFieldDelegate {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("EditableTextCellView")

    private let textFieldView = NSTextField()
    private var invoiceID: PhysicalArtifact.ID?
    private var onCommit: ((PhysicalArtifact.ID, String) -> Void)?
    private var isUpdating = false

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        textFieldView.translatesAutoresizingMaskIntoConstraints = false
        textFieldView.isBordered = false
        textFieldView.drawsBackground = false
        textFieldView.focusRingType = .none
        textFieldView.lineBreakMode = .byTruncatingTail
        textFieldView.delegate = self
        addSubview(textFieldView)

        NSLayoutConstraint.activate([
            textFieldView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            textFieldView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            textFieldView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func configure(
        invoiceID: PhysicalArtifact.ID,
        text: String,
        placeholder: String,
        onCommit: @escaping (PhysicalArtifact.ID, String) -> Void
    ) {
        self.invoiceID = invoiceID
        self.onCommit = onCommit
        isUpdating = true
        textFieldView.stringValue = text
        textFieldView.placeholderString = placeholder
        isUpdating = false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isUpdating,
              let invoiceID,
              let textField = obj.object as? NSTextField else { return }

        if (obj.userInfo?["NSTextMovement"] as? Int) == NSCancelTextMovement {
            return
        }

        onCommit?(invoiceID, textField.stringValue)
    }
}

private final class EditableDateCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("EditableDateCellView")

    private let datePicker = CommitOnBlurDatePicker()
    private var invoiceID: PhysicalArtifact.ID?
    private var onCommit: ((PhysicalArtifact.ID, Date) -> Void)?
    private var isUpdating = false
    private var committedDate: Date?

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        datePicker.translatesAutoresizingMaskIntoConstraints = false
        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = .yearMonthDay
        datePicker.target = self
        datePicker.action = #selector(dateChanged)
        datePicker.onBlur = { [weak self] in
            self?.commitIfNeeded()
        }
        datePicker.onCancel = { [weak self] in
            self?.revertToCommittedDate()
        }
        addSubview(datePicker)

        NSLayoutConstraint.activate([
            datePicker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            datePicker.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            datePicker.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func configure(
        invoiceID: PhysicalArtifact.ID,
        date: Date,
        onCommit: @escaping (PhysicalArtifact.ID, Date) -> Void
    ) {
        self.invoiceID = invoiceID
        self.onCommit = onCommit
        isUpdating = true
        datePicker.dateValue = date
        datePicker.committedDate = date
        committedDate = date
        isUpdating = false
    }

    @objc
    private func dateChanged() {
        guard !isUpdating else { return }
    }

    private func commitIfNeeded() {
        guard !isUpdating,
              let invoiceID,
              committedDate != datePicker.dateValue else {
            return
        }

        committedDate = datePicker.dateValue
        datePicker.committedDate = datePicker.dateValue
        onCommit?(invoiceID, datePicker.dateValue)
    }

    private func revertToCommittedDate() {
        guard let committedDate else { return }
        isUpdating = true
        datePicker.dateValue = committedDate
        datePicker.committedDate = committedDate
        isUpdating = false
    }
}
