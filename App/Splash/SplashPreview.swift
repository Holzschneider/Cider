import Foundation
import AppKit

// Stand-alone splash + loading preview launched from the Configure
// dialog's Presentation section. Shows what the live launch will
// look like with the current form values, with the loading bar at a
// fixed sample fraction so the user can verify visual proportions.
//
// Dismissed by:
//   - the (X) button on the loading window
//   - any click outside the preview window (mode = .preview drives
//     SplashController to observe the loading window's resignKey)
//   - an automatic 8 s timeout (in case neither of the above fires
//     because the user wandered away)
@MainActor
enum SplashPreview {
    private static let timeout: Double = 8.0
    // Strong reference so the controller outlives the function call.
    private static var active: SplashController?

    static func show(splashURL: URL?, loadingEnabled: Bool) {
        // Tear down any prior preview so back-to-back clicks don't
        // accumulate windows.
        active?.requestClose()
        active = nil

        guard let controller = SplashController.load(
            splashFile: splashURL,
            showLoadingWindow: loadingEnabled,
            mode: .preview
        ) else { return }

        active = controller
        controller.attach()
        controller.loadingProgress.fraction = 0.45
        controller.loadingProgress.statusLine = "Loading sample assets…"
        controller.loadingProgress.onCancel = {
            Task { @MainActor in
                controller.requestClose()
                if active === controller { active = nil }
            }
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if active === controller {
                controller.requestClose()
                active = nil
            }
        }
    }
}
