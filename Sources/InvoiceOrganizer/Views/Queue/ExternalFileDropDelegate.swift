import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Handles files dragged onto the Unprocessed view from outside the app.
///
/// Two drag flavors are supported:
/// 1. Real files from Finder/Desktop, read as `fileURL`s from the drag pasteboard.
/// 2. File promises from apps like Mail (attachments) or web browsers, which are
///    resolved through `NSFilePromiseReceiver` into a scratch directory.
///
/// SwiftUI has no native support for file promises, so both flavors are read
/// straight off the drag pasteboard rather than from `DropInfo` item providers.
struct ExternalFileDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let isEnabled: () -> Bool
    let onImport: @MainActor ([URL]) -> Void

    /// Content types the drop region must accept so macOS routes these drags to us.
    /// `.item` keeps the region permissive enough for promise-based drags (Mail);
    /// unwanted drags are filtered later in `validateDrop`/`performDrop`.
    static var acceptedContentTypes: [UTType] {
        var types: [UTType] = [.fileURL, .item]
        types += NSFilePromiseReceiver.readableDraggedTypes.compactMap { UTType($0) }
        return types
    }

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled() && !isInternalInvoiceDrag
    }

    func dropEntered(info: DropInfo) {
        if isEnabled() && !isInternalInvoiceDrag {
            isTargeted = true
        }
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard isEnabled(), !isInternalInvoiceDrag else { return false }

        let pasteboard = NSPasteboard(name: .drag)

        // Real files (Finder/Desktop): originals stay put; we copy them into the inbox.
        let readingOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: readingOptions) as? [URL],
           !fileURLs.isEmpty {
            onImport(fileURLs)
            return true
        }

        // File promises (Mail attachments, browser images, ...).
        guard let promises = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver], !promises.isEmpty else {
            return false
        }

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("InvoiceDrop-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        } catch {
            return false
        }

        let operationQueue = OperationQueue()
        for promise in promises {
            promise.receivePromisedFiles(atDestination: destinationURL, options: [:], operationQueue: operationQueue) { url, error in
                guard error == nil else { return }
                Task { @MainActor in
                    onImport([url])
                }
            }
        }

        return true
    }

    private var isInternalInvoiceDrag: Bool {
        InvoiceInternalDrag.isDragInFlight
    }
}
