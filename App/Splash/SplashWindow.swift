import Foundation
import AppKit

// Borderless transparent NSWindow used as the splash. PNG with alpha gives
// you a "shaped" window — the transparent regions are see-through and the
// image itself is the visible window shape.
//
// Behaviours:
//  - movable by dragging the image (no titlebar to grab)
//  - sits at the .floating window level so it stays above other windows
//    while loading; we lower it to .normal after the game window appears
//  - clicks pass through to onDoubleClick (Phase 4 stub; Phase 9 routes
//    that to the MoreDialog reopen path)
public final class SplashWindow: NSWindow {
    public init(image: NSImage, transparent: Bool) {
        let size = image.size == .zero ? NSSize(width: 480, height: 270) : image.size
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        if transparent {
            self.isOpaque = false
            self.backgroundColor = .clear
            self.hasShadow = false
        } else {
            self.isOpaque = true
            self.backgroundColor = .black
            self.hasShadow = true
        }
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
