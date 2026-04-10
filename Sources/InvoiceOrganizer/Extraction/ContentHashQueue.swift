import Foundation

protocol ContentHashRequestHandler<Request>: Sendable {
    associatedtype Request: Sendable
    func contentHash(for request: Request) -> String
    func process(_ request: Request) async
}

actor ContentHashQueue<Handler: ContentHashRequestHandler> {
    private let handler: Handler
    private var onQueueDepthChanged: (@MainActor @Sendable (Int) -> Void)?

    private var pendingQueue: [Handler.Request] = []
    private var pendingHashes: Set<String> = []
    private var inFlightHashes: Set<String> = []
    private var isDraining = false

    var queueDepth: Int { pendingQueue.count + inFlightHashes.count }

    init(handler: Handler) {
        self.handler = handler
    }

    func setOnQueueDepthChanged(_ handler: @escaping @MainActor @Sendable (Int) -> Void) {
        onQueueDepthChanged = handler
    }

    func enqueue(_ requests: [Handler.Request], excludingHashes: Set<String>) async {
        for request in requests {
            let hash = handler.contentHash(for: request)
            guard !excludingHashes.contains(hash),
                  !pendingHashes.contains(hash),
                  !inFlightHashes.contains(hash) else {
                continue
            }

            pendingQueue.append(request)
            pendingHashes.insert(hash)
        }

        await onQueueDepthChanged?(queueDepth)

        guard !isDraining, !pendingQueue.isEmpty else { return }
        isDraining = true

        Task.detached(priority: .utility) { [self] in
            await drainQueue()
        }
    }

    func waitForIdle() async {
        while isDraining || !pendingQueue.isEmpty || !inFlightHashes.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func drainQueue() async {
        while let request = nextRequest() {
            await handler.process(request)
            inFlightHashes.remove(handler.contentHash(for: request))
            await onQueueDepthChanged?(queueDepth)
        }

        isDraining = false

        if !pendingQueue.isEmpty {
            isDraining = true
            Task.detached(priority: .utility) { [self] in
                await drainQueue()
            }
        }
    }

    private func nextRequest() -> Handler.Request? {
        guard !pendingQueue.isEmpty else { return nil }

        let request = pendingQueue.removeFirst()
        let hash = handler.contentHash(for: request)
        pendingHashes.remove(hash)
        inFlightHashes.insert(hash)
        return request
    }
}
