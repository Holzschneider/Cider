import Foundation
import AppKit

// Shared AppKit setup used by every GUI entry point (splash, drop zone,
// later the More dialog). Avoids each controller redoing the same
// activation-policy / menu-bar / run-loop dance.
@MainActor
final class AppShell: NSObject, NSApplicationDelegate {
    private var setup: ((NSApplication) -> Void)?

    // Blocking. Builds the menu bar, calls `setup` once AppKit is up, and
    // runs the event loop until the user quits.
    func run(activationPolicy: NSApplication.ActivationPolicy = .regular,
             setup: @escaping (NSApplication) -> Void) {
        self.setup = setup
        let app = NSApplication.shared
        app.setActivationPolicy(activationPolicy)
        app.delegate = self
        installMenuBar(app: app)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setup?(NSApplication.shared)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Minimal menu bar so the standard chords (Cmd-Q, Cmd-H, Cmd-W) work
    // even when the only visible window is borderless.
    private func installMenuBar(app: NSApplication) {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        appMenu.addItem(NSMenuItem(title: "About \(appName)", action: nil, keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Hide \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(
            title: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        app.mainMenu = mainMenu
    }
}
