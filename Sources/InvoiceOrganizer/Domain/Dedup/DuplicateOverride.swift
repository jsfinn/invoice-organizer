import Foundation

/// An unordered pair of content hashes that the user has explicitly declared to be
/// *distinct* documents. Used as a "cannot-link" constraint in duplicate clustering:
/// two documents whose content hashes form a separated pair are never grouped together.
///
/// Keyed by content hash (not file path) so the override survives file moves and renames.
/// A content edit that changes a file's hash (e.g. rotate/reorder) naturally clears any
/// override referencing the old hash, which is acceptable — it is effectively new content.
struct ContentHashPair: Hashable, Codable, Sendable {
    let first: String
    let second: String

    init(_ a: String, _ b: String) {
        if a <= b {
            first = a
            second = b
        } else {
            first = b
            second = a
        }
    }
}

/// Persists the set of user-declared "not a duplicate" overrides.
enum DuplicateOverrideStore {
    private static let defaultsKey = "dedup.separatedContentHashPairs"

    static func load() -> Set<ContentHashPair> {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let pairs = try? JSONDecoder().decode([ContentHashPair].self, from: data) else {
            return []
        }
        return Set(pairs)
    }

    static func save(_ pairs: Set<ContentHashPair>) {
        let data = try? JSONEncoder().encode(Array(pairs))
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
