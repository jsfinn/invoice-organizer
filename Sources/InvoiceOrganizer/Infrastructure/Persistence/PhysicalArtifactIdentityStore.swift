import Foundation

final class PhysicalArtifactIdentityStore: @unchecked Sendable {
    static let shared = PhysicalArtifactIdentityStore()

    private var pathToID: [String: String]
    private let lock = NSLock()
    static let defaultsKey = "artifact.identityMap"

    init(pathToID: [String: String] = [:]) {
        if pathToID.isEmpty {
            self.pathToID = Self.load()
        } else {
            self.pathToID = pathToID
        }
    }

    func id(forPath path: String) -> String {
        lock.withLock {
            if let existing = pathToID[path] {
                return existing
            }
            let newID = UUID().uuidString
            pathToID[path] = newID
            return newID
        }
    }

    func id(for fileURL: URL) -> String {
        id(forPath: fileURL.standardizedFileURL.path)
    }

    func existingID(forPath path: String) -> String? {
        lock.withLock { pathToID[path] }
    }

    func existingID(for fileURL: URL) -> String? {
        existingID(forPath: fileURL.standardizedFileURL.path)
    }

    func updatePath(from oldPath: String, to newPath: String) {
        lock.withLock {
            guard let existingID = pathToID.removeValue(forKey: oldPath) else { return }
            pathToID[newPath] = existingID
        }
    }

    func updateURL(from oldURL: URL, to newURL: URL) {
        updatePath(from: oldURL.standardizedFileURL.path, to: newURL.standardizedFileURL.path)
    }

    func prune(keepingPaths activePaths: Set<String>) {
        lock.withLock {
            guard !pathToID.isEmpty else { return }

            // Matching none of the known paths means the roots were unreadable
            // (permissions, unmounted volume), not that every file was deleted.
            // Pruning here would hand every file a fresh UUID on the next scan and
            // orphan every workflow record, which is keyed by the old ones.
            guard activePaths.contains(where: { pathToID[$0] != nil }) else { return }

            let staleKeys = Set(pathToID.keys).subtracting(activePaths)
            for key in staleKeys {
                pathToID.removeValue(forKey: key)
            }
        }
    }

    func save() {
        lock.withLock {
            // set(nil) removes the key outright, so a failed encode has to leave the
            // previous value alone rather than delete the map.
            guard let data = try? JSONEncoder().encode(pathToID) else { return }
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private static func load() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func isLegacyPathKey(_ key: String) -> Bool {
        key.contains("/")
    }
}
