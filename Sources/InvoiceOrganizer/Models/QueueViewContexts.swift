import Foundation

struct QueueScreenContext: Equatable {
    var selectedTab: InvoiceQueueTab
    var showIgnoredInvoices: Bool
    private var tabContexts: [InvoiceQueueTab: QueueTabContext]

    init(
        selectedTab: InvoiceQueueTab = .unprocessed,
        showIgnoredInvoices: Bool = false,
        tabContexts: [InvoiceQueueTab: QueueTabContext] = [:]
    ) {
        self.selectedTab = selectedTab
        self.showIgnoredInvoices = showIgnoredInvoices
        self.tabContexts = Dictionary(
            uniqueKeysWithValues: InvoiceQueueTab.allCases.map { tab in
                (tab, tabContexts[tab] ?? QueueTabContext(queueTab: tab))
            }
        )
    }

    var activeTabContext: QueueTabContext {
        context(for: selectedTab)
    }

    func context(for tab: InvoiceQueueTab) -> QueueTabContext {
        tabContexts[tab] ?? QueueTabContext(queueTab: tab)
    }

    mutating func setContext(_ context: QueueTabContext, for tab: InvoiceQueueTab) {
        tabContexts[tab] = context
    }

    mutating func updateContext(for tab: InvoiceQueueTab, _ transform: (inout QueueTabContext) -> Void) {
        var context = context(for: tab)
        transform(&context)
        setContext(context, for: tab)
    }
}

struct QueueTabContext: Equatable {
    var searchText: String
    var selectedArtifactIDs: Set<PhysicalArtifact.ID>
    var selectedArtifactID: PhysicalArtifact.ID?
    var browserContext: InvoiceBrowserContext

    init(
        queueTab: InvoiceQueueTab,
        searchText: String = "",
        selectedArtifactIDs: Set<PhysicalArtifact.ID> = [],
        selectedArtifactID: PhysicalArtifact.ID? = nil,
        browserContext: InvoiceBrowserContext? = nil
    ) {
        self.searchText = searchText
        self.selectedArtifactIDs = selectedArtifactIDs
        self.selectedArtifactID = selectedArtifactID
        self.browserContext = browserContext ?? InvoiceBrowserContext(queueTab: queueTab)
    }
}

struct InvoiceBrowserContext: Equatable {
    var sortDescriptors: [InvoiceBrowserSortDescriptor]
    var expandedGroupIDs: Set<PhysicalArtifact.ID>

    init(
        queueTab: InvoiceQueueTab,
        sortDescriptors: [InvoiceBrowserSortDescriptor]? = nil,
        expandedGroupIDs: Set<PhysicalArtifact.ID> = []
    ) {
        self.sortDescriptors = sortDescriptors ?? defaultInvoiceBrowserSortDescriptors(for: queueTab)
        self.expandedGroupIDs = expandedGroupIDs
    }
}

struct InvoiceBrowserSortDescriptor: Equatable {
    var columnID: InvoiceBrowserColumnID
    var ascending: Bool
}

enum InvoiceBrowserColumnID: String, CaseIterable {
    case name
    case ocr
    case read
    case addedAt
    case fileType
    case vendor
    case invoiceDate
}

func defaultInvoiceBrowserSortDescriptors(for queueTab: InvoiceQueueTab) -> [InvoiceBrowserSortDescriptor] {
    resolvedInvoiceBrowserSortDescriptors([], for: queueTab)
}

func resolvedInvoiceBrowserSortDescriptors(
    _ descriptors: [InvoiceBrowserSortDescriptor],
    for queueTab: InvoiceQueueTab
) -> [InvoiceBrowserSortDescriptor] {
    let visibleColumnIDs = Set(invoiceBrowserVisibleColumnIDs(for: queueTab))
    let filteredDescriptors = descriptors.filter { visibleColumnIDs.contains($0.columnID) }

    return filteredDescriptors.isEmpty
        ? [InvoiceBrowserSortDescriptor(columnID: .addedAt, ascending: false)]
        : filteredDescriptors
}

func invoiceBrowserSortDescriptorsMatch(
    _ lhs: [InvoiceBrowserSortDescriptor],
    _ rhs: [InvoiceBrowserSortDescriptor]
) -> Bool {
    lhs == rhs
}

func invoiceBrowserVisibleColumnIDs(for queueTab: InvoiceQueueTab) -> [InvoiceBrowserColumnID] {
    switch queueTab {
    case .unprocessed:
        return [.name, .ocr, .read, .addedAt, .fileType]
    case .inProgress:
        return [.name, .ocr, .read, .vendor, .invoiceDate, .addedAt, .fileType]
    case .processed:
        return [.name, .vendor, .invoiceDate, .addedAt, .fileType]
    }
}
