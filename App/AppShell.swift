import Foundation
import AppKit

// Shared AppKit setup used by every GUI entry point (splash, drop zone,
// More dialog). Avoids each controller redoing the same activation-policy
// / menu-bar / run-loop dance.
@MainActor
final class AppShell: NSObject, NSApplicationDelegate {
    private var setup: ((NSApplication) -> Void)?
    private var settingsAction: (() -> Void)?

    // Blocking. Builds the menu bar, calls `setup` once AppKit is up, and
    // runs the event loop until the user quits.
    //
    //   - appName: drives the application menu items ("About <appName>",
    //     "Hide <appName>", "Quit <appName>"). Pass the configured
    //     Application Name (CiderConfig.displayName for a configured
    //     bundle) so the menu reflects the launched product, not the
    //     `cider` process. Falls back to ProcessInfo.processName when nil.
    //   - onSettings: when non-nil, adds a "Settings…" item with Cmd-,
    //     that calls this closure. Both the drop-zone and the configured-
    //     bundle entry points wire it to MoreDialog.
    func run(activationPolicy: NSApplication.ActivationPolicy = .regular,
             appName: String? = nil,
             onSettings: (() -> Void)? = nil,
             setup: @escaping (NSApplication) -> Void) {
        self.setup = setup
        self.settingsAction = onSettings
        let app = NSApplication.shared
        app.setActivationPolicy(activationPolicy)
        app.delegate = self
        installMenuBar(app: app, appName: appName ?? ProcessInfo.processInfo.processName,
                       hasSettings: onSettings != nil)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setup?(NSApplication.shared)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc fileprivate func invokeSettings(_ sender: Any?) {
        settingsAction?()
    }

    // Minimal menu bar so the standard chords (Cmd-Q, Cmd-H, Cmd-W, Cmd-,)
    // work even when the only visible window is borderless.
    private func installMenuBar(app: NSApplication, appName: String, hasSettings: Bool) {
        let mainMenu = NSMenu()

        // Both the menu item's title and the submenu's title need to be
        // set for the menu-bar label to read what we want — AppKit's
        // application-menu-name resolution looks at the title of the
        // first top-level item; CFBundleName otherwise wins at startup.
        let appItem = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: appName)
        appMenu.addItem(NSMenuItem(title: "About \(appName)", action: nil, keyEquivalent: ""))
        if hasSettings {
            appMenu.addItem(.separator())
            let settings = NSMenuItem(
                title: "Settings…",
                action: #selector(invokeSettings(_:)),
                keyEquivalent: ",")
            settings.target = self
            appMenu.addItem(settings)
        }
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
