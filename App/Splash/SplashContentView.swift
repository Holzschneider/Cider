import Foundation
import AppKit

// Container NSView that stacks the splash image (bottom) and a callback
// hook for double-clicks (top). The progress overlay is added as a third
// subview by SplashController via NSHostingView.
public final class SplashContentView: NSView {
    private let imageView: NSImageView

    // Callback fired on double-click anywhere in the splash. Phase 9 wires
    // this to "open MoreDialog" so a configured bundle can be reconfigured.
    public var onDoubleClick: (() -> Void)?

    public init(image: NSImage) {
        self.imageView = NSImageView()
        super.init(frame: NSRect(origin: .zero, size: image.size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public func addOverlay(_ view: NSView) {
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .above, relativeTo: imageView)
    }

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        // Single click: defer to NSWindow.isMovableByWindowBackground for drag.
        super.mouseDown(with: event)
    }
}
