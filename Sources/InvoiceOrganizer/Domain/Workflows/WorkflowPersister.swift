import Foundation

@MainActor
final class WorkflowPersister {
    private var saveTask: Task<Void, Never>?
    private let save: @MainActor () -> Void

    init(save: @escaping @MainActor () -> Void) {
        self.save = save
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }
}
