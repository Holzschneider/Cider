import Foundation
import AppKit
import SwiftUI
import CiderCore

// Owns the splash window, the image view, and the SwiftUI progress overlay.
// Defers the AppKit run loop to AppShell.
@MainActor
public final class SplashController {
    public let progress = ProgressModel()
    private var window: SplashWindow?
    private var content: SplashContentView?

    private let image: NSImage
    private let transparent: Bool

    // Callback for the splash double-click — Phase 9 routes this to the
    // MoreDialog reopen path so a configured bundle can be reconfigured.
    public var onDoubleClick: (() -> Void)?

    public init(image: NSImage, transparent: Bool) {
        self.image = image
        self.transparent = transparent
    }

    public static func load(splashFile: URL?, transparentHint: Bool) -> SplashController? {
        guard let splashFile, let image = NSImage(contentsOf: splashFile) else { return nil }
        let transparent = transparentHint && Self.imageHasAlpha(image)
        return SplashController(image: image, transparent: transparent)
    }

    private static func imageHasAlpha(_ image: NSImage) -> Bool {
        guard let rep = image.representations.first as? NSBitmapImageRep else { return true }
        return rep.hasAlpha
    }

    // Builds and shows the splash window. Caller is responsible for
    // running the event loop (AppShell.run).
    public func attach() {
        let window = SplashWindow(image: image, transparent: transparent)
        let content = SplashContentView(image: image)
        content.onDoubleClick = { [weak self] in self?.onDoubleClick?() }
        window.contentView = content

        let host = NSHostingView(rootView: ProgressOverlayView(model: progress))
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        content.addOverlay(host)

        self.window = window
        self.content = content
        window.makeKeyAndOrderFront(nil)
    }

    public func requestClose() {
        NSApplication.shared.terminate(nil)
    }

    // Convenience for callers that want both attach + run in one call.
    public func runEventLoop() {
        AppShell().run { _ in self.attach() }
    }
}
