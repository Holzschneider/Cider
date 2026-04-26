import Foundation
import AppKit
import SwiftUI
import CiderCore

// Owns whichever launch-time UI windows the user's config asks for:
//   * SplashWindow (centered image) when cider.json's `splash.file`
//     points at a readable image.
//   * LoadingWindow (translucent progress card) when cider.json's
//     `loading.enabled` is true (or absent → default true).
//
// Either, both, or neither may be present depending on config.
//
// Defers the AppKit run loop to AppShell.
@MainActor
public final class SplashController {
    // Legacy progress model kept around for the engine-download /
    // prefix-init / settle phases that LaunchPipeline reports
    // through it. With the schema-v3 LoadingWindow in place the
    // old ProgressOverlayView no longer renders — but
    // LaunchPipeline still calls into `progress` and we forward
    // the relevant signals onto loadingProgress below.
    public let progress = ProgressModel()
    public let loadingProgress = LoadingProgressModel()

    private var splashWindow: SplashWindow?
    private var splashContent: SplashContentView?
    private var loadingWindow: LoadingWindow?
    private var resignActiveObserver: NSObjectProtocol?
    private var loadingResignKeyObserver: NSObjectProtocol?

    public enum Mode {
        // Real launch — close on app-level resignActive (wine's
        // window came up and stole focus from Cider).
        case live
        // Preview from Configure → close on window-level resignKey
        // (any click elsewhere, even inside Cider, dismisses).
        case preview
    }

    private let image: NSImage?
    private let showLoadingWindow: Bool
    private let mode: Mode

    // Callback for the splash double-click — Phase 9 routes this to the
    // MoreDialog reopen path so a configured bundle can be reconfigured.
    public var onDoubleClick: (() -> Void)?

    public init(image: NSImage?, showLoadingWindow: Bool, mode: Mode = .live) {
        self.image = image
        self.showLoadingWindow = showLoadingWindow
        self.mode = mode
    }

    public static func load(splashFile: URL?,
                            showLoadingWindow: Bool,
                            mode: Mode = .live) -> SplashController? {
        let image: NSImage? = splashFile.flatMap { NSImage(contentsOf: $0) }
        // No image AND no loading window → no UI at all → no
        // controller (caller falls back to its own behaviour).
        if image == nil, !showLoadingWindow { return nil }
        return SplashController(image: image, showLoadingWindow: showLoadingWindow,
                                mode: mode)
    }

    // Builds and shows whichever windows are configured. Splash sits
    // centered above the loading window when both are present; the
    // loading window centres on screen when alone. Caller runs the
    // event loop via AppShell.
    public func attach() {
        // Splash window first (so we know its frame for positioning
        // the loading window beneath it).
        if let image {
            let splash = SplashWindow(image: image)
            let content = SplashContentView(image: image)
            content.onDoubleClick = { [weak self] in self?.onDoubleClick?() }
            splash.contentView = content
            self.splashWindow = splash
            self.splashContent = content
            splash.center()
            splash.makeKeyAndOrderFront(nil)
        }

        if showLoadingWindow {
            let loading = LoadingWindow(model: loadingProgress)
            self.loadingWindow = loading
            positionLoadingBelowSplash(loading)
            loading.makeKeyAndOrderFront(nil)

            switch mode {
            case .live:
                // Wine's window appearing pulls focus away from
                // Cider entirely → app-level resignActive fires.
                resignActiveObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didResignActiveNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    self?.requestClose()
                }
            case .preview:
                // Anything else clicked (Configure dialog, Finder,
                // …) takes key from the preview window.
                loadingResignKeyObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification,
                    object: loading, queue: .main
                ) { [weak self] _ in
                    self?.requestClose()
                }
            }
        }

        // Forward the legacy ProgressModel.title/detail events into
        // the LoadingProgressModel's status line so engine-download
        // and prefix-init progress shows up in the new window during
        // the pre-launch phase.
        progress.onChange = { [weak self] title, detail, fraction in
            guard let self else { return }
            let merged = detail.isEmpty ? title : "\(title): \(detail)"
            self.loadingProgress.ingestLine(merged)
            if let fraction { self.loadingProgress.fraction = fraction }
        }
    }

    private func positionLoadingBelowSplash(_ loading: LoadingWindow) {
        let screenVisible = (NSScreen.main?.visibleFrame) ?? .zero
        let loadingSize = loading.frame.size
        let origin: NSPoint
        if let splash = splashWindow {
            let splashFrame = splash.frame
            // 16pt tasteful gap between splash and loading window.
            let x = splashFrame.midX - loadingSize.width / 2
            let y = splashFrame.minY - 16 - loadingSize.height
            origin = NSPoint(x: x, y: y)
        } else {
            origin = NSPoint(
                x: screenVisible.midX - loadingSize.width / 2,
                y: screenVisible.midY - loadingSize.height / 2
            )
        }
        loading.setFrameOrigin(origin)
    }

    // Forcibly close everything. Called when the user clicks the
    // loading window's (X) — orchestration of "kill the wine
    // process if alive" lives in WineLauncher / CLIRouter.
    public func requestClose() {
        if let obs = resignActiveObserver {
            NotificationCenter.default.removeObserver(obs)
            resignActiveObserver = nil
        }
        if let obs = loadingResignKeyObserver {
            NotificationCenter.default.removeObserver(obs)
            loadingResignKeyObserver = nil
        }
        loadingWindow?.orderOut(nil)
        splashWindow?.orderOut(nil)
        loadingWindow = nil
        splashWindow = nil
        splashContent = nil
    }

    // Convenience for callers that want both attach + run in one call.
    // Stores a strong reference to the shell so NSApplication.delegate's
    // weak slot stays valid for the whole event loop.
    private var shell: AppShell?
    public func runEventLoop() {
        let shell = AppShell()
        self.shell = shell
        shell.run { _ in self.attach() }
    }
}
