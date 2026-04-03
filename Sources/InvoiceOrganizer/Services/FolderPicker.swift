import AppKit
import Foundation

enum FolderPicker {
    @MainActor
    static func pickFolder(title: String, startingAt url: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = url

        return panel.runModal() == .OK ? panel.url : nil
    }
}
