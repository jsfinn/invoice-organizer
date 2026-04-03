import Foundation

protocol InvoiceStructuredDataStoring: Sendable {
    func cachedData(forContentHash contentHash: String) async -> InvoiceStructuredDataRecord?
    func hasCachedData(forContentHash contentHash: String) async -> Bool
    func save(_ record: InvoiceStructuredDataRecord, forContentHash contentHash: String) async
    func removeCachedData(forContentHash contentHash: String) async
    func cachedContentHashes() async -> Set<String>
    func cachedRecords() async -> [String: InvoiceStructuredDataRecord]
}

actor InvoiceStructuredDataStore: InvoiceStructuredDataStoring {
    static let shared = InvoiceStructuredDataStore()

    private static let defaultsKey = "workflow.invoiceStructuredData"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    init(suiteName: String) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    func cachedData(forContentHash contentHash: String) async -> InvoiceStructuredDataRecord? {
        loadAll()[contentHash]
    }

    func hasCachedData(forContentHash contentHash: String) async -> Bool {
        loadAll()[contentHash] != nil
    }

    func save(_ record: InvoiceStructuredDataRecord, forContentHash contentHash: String) async {
        var records = loadAll()
        records[contentHash] = record
        persist(records)
    }

    func removeCachedData(forContentHash contentHash: String) async {
        var records = loadAll()
        records.removeValue(forKey: contentHash)
        persist(records)
    }

    func cachedContentHashes() async -> Set<String> {
        Set(loadAll().keys)
    }

    func cachedRecords() async -> [String: InvoiceStructuredDataRecord] {
        loadAll()
    }

    private func loadAll() -> [String: InvoiceStructuredDataRecord] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let records = try? JSONDecoder().decode([String: InvoiceStructuredDataRecord].self, from: data) else {
            return [:]
        }

        return records
    }

    private func persist(_ records: [String: InvoiceStructuredDataRecord]) {
        let data = try? JSONEncoder().encode(records)
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
