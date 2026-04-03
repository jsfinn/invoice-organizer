import Foundation

enum InvoiceWorkflowStore {
    private static let defaultsKey = "workflow.invoiceMetadata"

    static func load() -> [String: StoredInvoiceWorkflow] {
        let defaults = UserDefaults.standard

        guard let data = defaults.data(forKey: defaultsKey) else {
            return [:]
        }

        return (try? JSONDecoder().decode([String: StoredInvoiceWorkflow].self, from: data)) ?? [:]
    }

    static func save(_ workflowByID: [String: StoredInvoiceWorkflow]) {
        let defaults = UserDefaults.standard
        let filtered = workflowByID.filter { !$0.value.isEmpty }
        let data = try? JSONEncoder().encode(filtered)
        defaults.set(data, forKey: defaultsKey)
    }
}

private extension StoredInvoiceWorkflow {
    var isEmpty: Bool {
        vendor?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
        invoiceDate == nil &&
        invoiceNumber?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
        documentType == nil &&
        !isInProgress
    }
}
