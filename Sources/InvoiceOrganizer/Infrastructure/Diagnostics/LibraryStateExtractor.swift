import Foundation

/// The five persisted blobs that make up the library's operational state.
///
/// This is the only description of how that state is laid out in UserDefaults.
/// Phase 1 serializes it into a diagnostic dump; phase 2 seeds the Application
/// Support store from the same values, so the migration consumes exactly what was
/// validated against real data rather than a second, divergent read path.
struct LegacyLibraryState: Codable, Equatable, Sendable {
    var workflowByArtifactID: [String: StoredInvoiceWorkflow]
    var identityMapByPath: [String: String]
    var extractedTextByContentHash: [String: InvoiceTextRecord]
    var structuredDataByContentHash: [String: InvoiceStructuredDataRecord]
    var separatedContentHashPairs: [ContentHashPair]

    /// Keys that held data but could not be decoded. Empty on a healthy library;
    /// a non-empty list is the single most useful thing a dump can tell us.
    var undecodableKeys: [String]

    static let empty = LegacyLibraryState(
        workflowByArtifactID: [:],
        identityMapByPath: [:],
        extractedTextByContentHash: [:],
        structuredDataByContentHash: [:],
        separatedContentHashPairs: [],
        undecodableKeys: []
    )

    var isEmpty: Bool {
        workflowByArtifactID.isEmpty &&
        identityMapByPath.isEmpty &&
        extractedTextByContentHash.isEmpty &&
        structuredDataByContentHash.isEmpty &&
        separatedContentHashPairs.isEmpty
    }
}

/// Reads legacy library state. Never writes and never removes a key.
enum LibraryStateExtractor {
    /// Domains earlier builds wrote to. Release builds use the bundle identifier;
    /// builds launched without a bundle fall back to the process name.
    static let legacySuiteNames = ["com.pkm.invoiceorganizer", "InvoiceOrganizer"]

    static func extract(defaults: UserDefaults = .standard) -> LegacyLibraryState {
        var undecodableKeys: [String] = []

        func read<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
            guard let data = firstData(forKey: key, defaults: defaults) else {
                return nil
            }
            guard let decoded = try? JSONDecoder().decode(type, from: data) else {
                undecodableKeys.append(key)
                return nil
            }
            return decoded
        }

        let workflow = read([String: StoredInvoiceWorkflow].self, forKey: InvoiceWorkflowStore.defaultsKey)
        let identity = read([String: String].self, forKey: PhysicalArtifactIdentityStore.defaultsKey)
        let text = read([String: InvoiceTextRecord].self, forKey: InvoiceTextStore.defaultsKey)
        let structured = read([String: InvoiceStructuredDataRecord].self, forKey: InvoiceStructuredDataStore.defaultsKey)
        let pairs = read([ContentHashPair].self, forKey: DuplicateOverrideStore.defaultsKey)

        return LegacyLibraryState(
            workflowByArtifactID: workflow ?? [:],
            identityMapByPath: identity ?? [:],
            extractedTextByContentHash: text ?? [:],
            structuredDataByContentHash: structured ?? [:],
            separatedContentHashPairs: pairs ?? [],
            undecodableKeys: undecodableKeys
        )
    }

    /// Looks in the supplied defaults first, then in the legacy suites. The suite
    /// fallback only applies to the standard domain so an injected test suite can
    /// never reach into the real user's preferences.
    private static func firstData(forKey key: String, defaults: UserDefaults) -> Data? {
        if let data = defaults.data(forKey: key), !data.isEmpty {
            return data
        }

        guard defaults === UserDefaults.standard else {
            return nil
        }

        for suiteName in legacySuiteNames {
            if let data = UserDefaults(suiteName: suiteName)?.data(forKey: key), !data.isEmpty {
                return data
            }
        }

        return nil
    }
}
