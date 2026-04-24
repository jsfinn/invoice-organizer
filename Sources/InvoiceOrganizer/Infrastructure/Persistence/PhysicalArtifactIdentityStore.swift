import Foundation

final class PhysicalArtifactIdentityStore: @unchecked Sendable {
    static let shared = PhysicalArtifactIdentityStore()

    private var pathToID: [String: String]
    private let lock = NSLock()
    private static let defaultsKey = "artifact.identityMap"

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
            let staleKeys = Set(pathToID.keys).subtracting(activePaths)
            for key in staleKeys {
                pathToID.removeValue(forKey: key)
            }
        }
    }

    func save() {
        let snapshot = lock.withLock { pathToID }
        let data = try? JSONEncoder().encode(snapshot)
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func load() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func isLegacyPathKey(_ key: String) -> Bool {
        key.contains("/")
    }
}
