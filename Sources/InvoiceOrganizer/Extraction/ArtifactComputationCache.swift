import Foundation

@MainActor
final class ArtifactComputationCache {
    private let textStore: any InvoiceTextStoring
    private let structuredDataStore: any InvoiceStructuredDataStoring

    private(set) var textRecordsByHash: [String: InvoiceTextRecord] = [:]
    private(set) var structuredRecordsByHash: [String: InvoiceStructuredDataRecord] = [:]
    private(set) var duplicateTokensByHash: [String: Set<String>] = [:]
    private(set) var firstPageDuplicateTokensByHash: [String: Set<String>] = [:]

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
        duplicateTokensByHash = [:]
        firstPageDuplicateTokensByHash = [:]
    }

    func loadAll() async {
        let textRecords = await textStore.cachedRecords()
        let structuredRecords = await structuredDataStore.cachedRecords()
        textRecordsByHash = textRecords
        structuredRecordsByHash = structuredRecords
        duplicateTokensByHash = DuplicateDetector.normalizedTokenSets(from: textRecords)
        firstPageDuplicateTokensByHash = DuplicateDetector.normalizedFirstPageTokenSets(from: textRecords)
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

    func duplicateTokens(forContentHash contentHash: String) -> Set<String>? {
        duplicateTokensByHash[contentHash]
    }

    func syncExtractedText(forContentHash contentHash: String) async {
        if let record = await textStore.cachedText(forContentHash: contentHash) {
            textRecordsByHash[contentHash] = record
            duplicateTokensByHash[contentHash] = DuplicateDetector.normalizedTokenSet(for: record.text)
            firstPageDuplicateTokensByHash[contentHash] = DuplicateDetector.normalizedTokenSet(for: record.firstPageText)
        } else {
            textRecordsByHash.removeValue(forKey: contentHash)
            duplicateTokensByHash.removeValue(forKey: contentHash)
            firstPageDuplicateTokensByHash.removeValue(forKey: contentHash)
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
            duplicateTokensByHash.removeValue(forKey: contentHash)
            firstPageDuplicateTokensByHash.removeValue(forKey: contentHash)
        }
    }

    func migrate(from previousContentHash: String, to updatedContentHash: String) async {
        if let cachedText = await textStore.cachedText(forContentHash: previousContentHash) {
            await textStore.save(cachedText, forContentHash: updatedContentHash)
            await textStore.removeCachedText(forContentHash: previousContentHash)
            textRecordsByHash.removeValue(forKey: previousContentHash)
            textRecordsByHash[updatedContentHash] = cachedText
            duplicateTokensByHash.removeValue(forKey: previousContentHash)
            duplicateTokensByHash[updatedContentHash] = DuplicateDetector.normalizedTokenSet(for: cachedText.text)
            firstPageDuplicateTokensByHash.removeValue(forKey: previousContentHash)
            firstPageDuplicateTokensByHash[updatedContentHash] = DuplicateDetector.normalizedTokenSet(for: cachedText.firstPageText)
        }

        if let cachedStructuredData = await structuredDataStore.cachedData(forContentHash: previousContentHash) {
            await structuredDataStore.save(cachedStructuredData, forContentHash: updatedContentHash)
            await structuredDataStore.removeCachedData(forContentHash: previousContentHash)
            structuredRecordsByHash.removeValue(forKey: previousContentHash)
            structuredRecordsByHash[updatedContentHash] = cachedStructuredData
        }
    }
}
