import Foundation
import AppKit
import SwiftUI

// Translucent, modern, borderless NSWindow that hosts the new
// LoadingContentView. Sits below the splash image (or centered on
// screen when no splash is configured) and shows the progress bar +
// last-status-line UI while wine is starting.
//
// Behaviours:
//   * Borderless + .clear background so the SwiftUI .ultraThinMaterial
//     content renders translucent against whatever is behind it.
//   * Floats above other windows but below the splash image so the
//     two stack visually.
//   * Becomes key so the (X) close button is hit-testable; when it
//     loses key (usually because wine's window came up and took
//     focus), the controller dismisses it.
final class LoadingWindow: NSWindow {

    init(model: LoadingProgressModel) {
        let initialSize = NSSize(width: 480, height: 92)
        super.init(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]

        let host = NSHostingView(rootView: LoadingContentView(model: model))
        host.frame = NSRect(origin: .zero, size: initialSize)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
