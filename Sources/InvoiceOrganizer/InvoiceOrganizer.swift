import AppKit
import Sparkle
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
                    rotationCoordinator.persistHandler = { request in
                        await model.persistPreviewRotation(for: request)
                    }
                    appDelegate.rotationCoordinator = rotationCoordinator
                }
        }
        .defaultSize(width: 1280, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: appDelegate.updaterController.updater)
            }
        }

        Settings {
            SettingsView(model: model)
                .frame(width: 860, height: 560)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: !isDebugBuild,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
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
            await rotationCoordinator?.commitAllPendingRequests()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
