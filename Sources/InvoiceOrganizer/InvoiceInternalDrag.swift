import Foundation
import UniformTypeIdentifiers

enum InvoiceInternalDrag {
    // Use a system-defined content type so internal drag-and-drop does not depend
    // on app bundle UTI registration.
    static let invoiceIDsType = UTType.json
    @MainActor private static var activeInvoiceIDs: [String] = []

    static func encode(_ invoiceIDs: [String]) -> Data? {
        try? JSONEncoder().encode(invoiceIDs)
    }

    static func decode(_ data: Data) -> [String]? {
        try? JSONDecoder().decode([String].self, from: data)
    }

    @MainActor
    static func beginDrag(_ invoiceIDs: [String]) {
        activeInvoiceIDs = invoiceIDs
    }

    @MainActor
    static func consumeActiveInvoiceIDs() -> [String] {
        defer { activeInvoiceIDs = [] }
        return activeInvoiceIDs
    }
}
