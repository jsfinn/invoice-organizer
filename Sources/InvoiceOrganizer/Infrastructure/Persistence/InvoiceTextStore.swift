import Foundation

protocol InvoiceTextStoring: Sendable {
    func cachedText(forContentHash contentHash: String) async -> InvoiceTextRecord?
    func hasCachedText(forContentHash contentHash: String) async -> Bool
    func save(_ record: InvoiceTextRecord, forContentHash contentHash: String) async
    func removeCachedText(forContentHash contentHash: String) async
    func cachedContentHashes() async -> Set<String>
    func cachedRecords() async -> [String: InvoiceTextRecord]
}

actor InvoiceTextStore: InvoiceTextStoring {
    static let shared = InvoiceTextStore()

    private static let defaultsKey = "workflow.invoiceExtractedText"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    init(suiteName: String) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    func cachedText(forContentHash contentHash: String) async -> InvoiceTextRecord? {
        loadAll()[contentHash]
    }

    func hasCachedText(forContentHash contentHash: String) async -> Bool {
        loadAll()[contentHash] != nil
    }

    func save(_ record: InvoiceTextRecord, forContentHash contentHash: String) async {
        var records = loadAll()
        records[contentHash] = record
        persist(records)
    }

    func removeCachedText(forContentHash contentHash: String) async {
        var records = loadAll()
        records.removeValue(forKey: contentHash)
        persist(records)
    }

    func cachedContentHashes() async -> Set<String> {
        Set(loadAll().keys)
    }

    func cachedRecords() async -> [String: InvoiceTextRecord] {
        loadAll()
    }

    private func loadAll() -> [String: InvoiceTextRecord] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let records = try? JSONDecoder().decode([String: InvoiceTextRecord].self, from: data) else {
            return [:]
        }

        return records
    }

    private func persist(_ records: [String: InvoiceTextRecord]) {
        let data = try? JSONEncoder().encode(records)
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
