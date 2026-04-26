import Foundation
import AppKit

// Schema-v3 splash: a borderless NSWindow that just shows the user's
// splash image, centered on screen. The shaped-PNG transparent
// variant is gone — the loading-progress UI lives in a separate
// translucent window beneath this one (LoadingWindow) so the splash
// itself can be a flat decorative image regardless of alpha.
//
// Behaviours:
//   * Movable by dragging the image (no titlebar to grab).
//   * Floats above other windows while loading; SplashController
//     orderOut's it once the wine app's first window takes focus.
//   * Double-click → onDoubleClick (MoreDialog reopen path).
public final class SplashWindow: NSWindow {
    public init(image: NSImage) {
        let size = image.size == .zero ? NSSize(width: 480, height: 270) : image.size
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        self.isOpaque = true
        self.backgroundColor = .black
        self.hasShadow = true
        self.level = .floating
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        self.center()
    }

    // Keep the borderless window keyboard-eligible (Cmd-Q etc. through
    // the menu bar / NSApp delegate).
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }
}
