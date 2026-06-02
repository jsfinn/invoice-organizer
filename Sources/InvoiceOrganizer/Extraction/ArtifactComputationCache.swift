import Foundation

@MainActor
final class ArtifactComputationCache {
    private let textStore: any InvoiceTextStoring
    private let structuredDataStore: any InvoiceStructuredDataStoring

    private(set) var textRecordsByHash: [String: InvoiceTextRecord] = [:]
    private(set) var structuredRecordsByHash: [String: InvoiceStructuredDataRecord] = [:]
    private(set) var duplicateTermFrequenciesByHash: [String: [String: Int]] = [:]
    private(set) var firstPageDuplicateTermFrequenciesByHash: [String: [String: Int]] = [:]

    init(
        textStore: any InvoiceTextStoring,
        structuredDataStore: any InvoiceStructuredDataStoring
    ) {
        self.textStore = textStore
        self.structuredDataStore = structuredDataStore
    }

    var extractedTextHashes: Set<String> {
        Set(textRecordsByHash.keys)
    }

    var structuredDataHashes: Set<String> {
        Set(structuredRecordsByHash.keys)
    }

    func reset() {
        textRecordsByHash = [:]
        structuredRecordsByHash = [:]
        duplicateTermFrequenciesByHash = [:]
        firstPageDuplicateTermFrequenciesByHash = [:]
    }

    func loadAll() async {
        let textRecords = await textStore.cachedRecords()
        let structuredRecords = await structuredDataStore.cachedRecords()
        textRecordsByHash = textRecords
        structuredRecordsByHash = structuredRecords
        duplicateTermFrequenciesByHash = DuplicateDetector.termFrequenciesFromRecords(textRecords)
        firstPageDuplicateTermFrequenciesByHash = DuplicateDetector.firstPageTermFrequenciesFromRecords(textRecords)
    }

    @discardableResult
    func reloadStructuredRecords() async -> Set<String> {
        let structuredRecords = await structuredDataStore.cachedRecords()
        structuredRecordsByHash = structuredRecords
        return Set(structuredRecords.keys)
    }

    func hasCachedText(forContentHash contentHash: String) async -> Bool {
        if textRecordsByHash[contentHash] != nil {
            return true
        }

        return await textStore.hasCachedText(forContentHash: contentHash)
    }

    func hasCachedStructuredData(forContentHash contentHash: String) async -> Bool {
        if structuredRecordsByHash[contentHash] != nil {
            return true
        }

        return await structuredDataStore.hasCachedData(forContentHash: contentHash)
    }

    func textRecord(forContentHash contentHash: String) -> InvoiceTextRecord? {
        textRecordsByHash[contentHash]
    }

    func structuredRecord(forContentHash contentHash: String) -> InvoiceStructuredDataRecord? {
        structuredRecordsByHash[contentHash]
    }

    func duplicateTermFrequencies(forContentHash contentHash: String) -> [String: Int]? {
        duplicateTermFrequenciesByHash[contentHash]
    }

    func syncExtractedText(forContentHash contentHash: String) async {
        if let record = await textStore.cachedText(forContentHash: contentHash) {
            textRecordsByHash[contentHash] = record
            duplicateTermFrequenciesByHash[contentHash] = DuplicateDetector.normalizedTermFrequencies(for: record.text)
            firstPageDuplicateTermFrequenciesByHash[contentHash] = DuplicateDetector.normalizedTermFrequencies(for: record.firstPageText)
        } else {
            textRecordsByHash.removeValue(forKey: contentHash)
            duplicateTermFrequenciesByHash.removeValue(forKey: contentHash)
            firstPageDuplicateTermFrequenciesByHash.removeValue(forKey: contentHash)
        }
    }

    func setStructuredRecord(_ record: InvoiceStructuredDataRecord, forContentHash contentHash: String) {
        structuredRecordsByHash[contentHash] = record
    }

    func invalidate(contentHashes: Set<String>) async {
        for contentHash in contentHashes {
            await textStore.removeCachedText(forContentHash: contentHash)
            await structuredDataStore.removeCachedData(forContentHash: contentHash)
            textRecordsByHash.removeValue(forKey: contentHash)
            structuredRecordsByHash.removeValue(forKey: contentHash)
            duplicateTermFrequenciesByHash.removeValue(forKey: contentHash)
            firstPageDuplicateTermFrequenciesByHash.removeValue(forKey: contentHash)
        }
    }

    func migrate(from previousContentHash: String, to updatedContentHash: String) async {
        if let cachedText = await textStore.cachedText(forContentHash: previousContentHash) {
            await textStore.save(cachedText, forContentHash: updatedContentHash)
            await textStore.removeCachedText(forContentHash: previousContentHash)
            textRecordsByHash.removeValue(forKey: previousContentHash)
            textRecordsByHash[updatedContentHash] = cachedText
            duplicateTermFrequenciesByHash.removeValue(forKey: previousContentHash)
            duplicateTermFrequenciesByHash[updatedContentHash] = DuplicateDetector.normalizedTermFrequencies(for: cachedText.text)
            firstPageDuplicateTermFrequenciesByHash.removeValue(forKey: previousContentHash)
            firstPageDuplicateTermFrequenciesByHash[updatedContentHash] = DuplicateDetector.normalizedTermFrequencies(for: cachedText.firstPageText)
        }

        if let cachedStructuredData = await structuredDataStore.cachedData(forContentHash: previousContentHash) {
            await structuredDataStore.save(cachedStructuredData, forContentHash: updatedContentHash)
            await structuredDataStore.removeCachedData(forContentHash: previousContentHash)
            structuredRecordsByHash.removeValue(forKey: previousContentHash)
            structuredRecordsByHash[updatedContentHash] = cachedStructuredData
        }
    }
}
