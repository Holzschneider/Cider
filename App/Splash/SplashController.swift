import Foundation
import AppKit
import SwiftUI
import CiderCore

// Owns the splash window, the image view, and the SwiftUI progress overlay,
// and runs the AppKit event loop. Phases 5–7 plug into this from the launch
// pipeline by mutating `progress` and (eventually) calling `requestClose()`
// when wine has settled.
@MainActor
public final class SplashController: NSObject, NSApplicationDelegate {
    public let progress = ProgressModel()
    private var window: SplashWindow!
    private var content: SplashContentView!

    // Loaded image + transparency hint. Stored to defer window creation
    // until the AppKit run loop is up.
    private let image: NSImage
    private let transparent: Bool

    // Callback for the splash double-click — kept on this class so the
    // config dialog reopen logic can be injected from Phase 9 later.
    public var onDoubleClick: (() -> Void)?

    public init(image: NSImage, transparent: Bool) {
        self.image = image
        self.transparent = transparent
    }

    // Convenience: load splash from a URL and return nil if it can't be
    // decoded. Caller handles the missing-asset case (typically falls back
    // to a default splash bundled in Resources/).
    public static func load(splashFile: URL?, transparentHint: Bool) -> SplashController? {
        guard let splashFile,
              let image = NSImage(contentsOf: splashFile)
        else { return nil }
        // Treat as transparent only when the user said so AND the image
        // actually has an alpha channel.
        let transparent = transparentHint && Self.imageHasAlpha(image)
        return SplashController(image: image, transparent: transparent)
    }

    private static func imageHasAlpha(_ image: NSImage) -> Bool {
        guard let rep = image.representations.first as? NSBitmapImageRep else { return true }
        return rep.hasAlpha
    }

    // Blocking. Builds the window, runs the AppKit event loop. Returns
    // when the user quits (Cmd-Q) or `requestClose()` is called.
    public func runEventLoop() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = self
        installMenuBar(app: app)
        app.run()
    }

    public func requestClose() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - NSApplicationDelegate

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let window = SplashWindow(image: image, transparent: transparent)
        let content = SplashContentView(image: image)
        content.onDoubleClick = { [weak self] in self?.onDoubleClick?() }
        window.contentView = content

        let host = NSHostingView(rootView: ProgressOverlayView(model: progress))
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        // SwiftUI hosting view's own background must be clear to keep the
        // splash transparency working.
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        content.addOverlay(host)

        self.window = window
        self.content = content

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // Minimal menu bar so Cmd-Q and the standard "About / Hide / Quit"
    // chords work even though the splash window is borderless.
    private func installMenuBar(app: NSApplication) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        appMenu.addItem(NSMenuItem(
            title: "About \(appName)", action: nil, keyEquivalent: ""))
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
        app.mainMenu = mainMenu
    }
}
