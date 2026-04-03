import AppKit
import SwiftUI

@main
struct InvoiceOrganizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var rotationCoordinator = PreviewRotationCoordinator()

    var body: some Scene {
        WindowGroup("Invoice Organizer") {
            ContentView(model: model, rotationCoordinator: rotationCoordinator)
                .task {
                    rotationCoordinator.persistHandler = { draft in
                        await model.persistPreviewRotation(for: draft)
                    }
                    appDelegate.rotationCoordinator = rotationCoordinator
                }
        }
        .defaultSize(width: 1280, height: 760)

        Settings {
            SettingsView(model: model)
                .frame(width: 860, height: 560)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var rotationCoordinator: PreviewRotationCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = image
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let rotationCoordinator, rotationCoordinator.hasPendingWork else {
            return .terminateNow
        }

        Task { @MainActor [weak rotationCoordinator] in
            await rotationCoordinator?.commitAllPendingDrafts()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
