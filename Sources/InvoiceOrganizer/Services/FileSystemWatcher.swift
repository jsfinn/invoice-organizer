import CoreServices
import Foundation

final class FileSystemWatcher {
    private var stream: FSEventStreamRef?
    private let callback: @Sendable () -> Void

    init(paths: [String], callback: @escaping @Sendable () -> Void) {
        self.callback = callback
        start(paths: paths)
    }

    deinit {
        stop()
    }

    func restart(paths: [String]) {
        stop()
        start(paths: paths)
    }

    private func start(paths: [String]) {
        let watchedPaths = Array(Set(paths.filter { !$0.isEmpty }))
        guard !watchedPaths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, clientCallBackInfo, _, _, _, _ in
                guard let clientCallBackInfo else { return }
                let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
                watcher.callback()
            },
            &context,
            watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else {
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    private func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
