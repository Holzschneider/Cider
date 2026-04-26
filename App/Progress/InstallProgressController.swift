import Foundation
import AppKit
import SwiftUI
import CiderCore

// Presents an InstallProgressSheet as a sheet attached to a parent
// window, runs the supplied async work with a callback that updates the
// model, and dismisses the sheet when the work completes (success,
// failure, or user cancel).
//
// Usage from Phase 8's Apply / Create:
//
//   await InstallProgressController.run(parent: dropZoneWindow) { progress in
//       try await Installer().run(
//           source: ..., mode: ..., baseConfig: ..., bundleURL: ...,
//           progress: progress
//       )
//   }
//
// The closure receives an `InstallProgressCallback` that's safe to call
// from any thread; the controller marshals updates to the main actor.
@MainActor
enum InstallProgressController {

    enum Outcome<T> {
        // Work succeeded. `choice` is the user's pick from the post-
        // completion button bar (Run / OpenInFinder / Close / Revert)
        // when the caller passed `showsCompletionChoices: true`; nil
        // when the sheet auto-dismissed without showing the bar
        // (legacy Apply mode).
        case completed(T, choice: InstallProgressModel.CompletionChoice?)
        case cancelled
        case failure(Swift.Error)
    }

    static func run<T>(
        parent: NSWindow?,
        title: String = "Configuring Cider",
        showsCompletionChoices: Bool = false,
        work: @escaping @Sendable (@escaping InstallProgressCallback) async throws -> T
    ) async -> Outcome<T> {
        let model = InstallProgressModel()
        model.showsCompletionChoices = showsCompletionChoices
        let sheet = SheetHost(model: model, title: title)
        sheet.present(over: parent)

        // Bridge progress events from the worker (any thread) to the
        // main-actor model.
        let progress: InstallProgressCallback = { event in
            Task { @MainActor in
                model.apply(event)
            }
        }

        // Live ALT-state for the Run / Open in Finder swap. Also drives
        // the drop zone's existing primary-button swap, so installing a
        // local monitor here is harmless.
        let altMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            model.isOptionPressed = event.modifierFlags.contains(.option)
            return event
        }
        defer {
            if let altMonitor { NSEvent.removeMonitor(altMonitor) }
        }

        // Pin the work in a Task so the Cancel button can cancel it.
        let task = Task<T, Swift.Error> {
            try await work(progress)
        }
        model.onCancel = { task.cancel() }

        do {
            let value = try await task.value
            // Work finished without throwing. Sweep any phases still
            // showing as .running / .pending to .done before flipping
            // the bar — work() schedules phaseDone events via
            // `Task { @MainActor in … }` and the trailing ones can
            // arrive late, leaving the visual state inconsistent
            // with "succeeded". This sweep makes the state coherent
            // at the moment we flip.
            model.markAllPhasesDone()
            if showsCompletionChoices {
                model.completionState = .succeeded
                let choice = await withCheckedContinuation { (cont: CheckedContinuation<InstallProgressModel.CompletionChoice, Never>) in
                    model.onCompletionChoice = { c in cont.resume(returning: c) }
                }
                sheet.dismiss()
                return .completed(value, choice: choice)
            } else {
                sheet.dismiss()
                return .completed(value, choice: nil)
            }
        } catch is CancellationError {
            model.completionState = .cancelled
            sheet.dismiss()
            return .cancelled
        } catch {
            // A SIGTERM'd subprocess surfaces as a non-cancellation error
            // even when the user pressed Cancel; classify by the model's
            // own state so the caller doesn't show "install failed" when
            // the user explicitly aborted.
            if model.isCancelling {
                model.completionState = .cancelled
                sheet.dismiss()
                return .cancelled
            }
            model.completionState = .failed(message: String(describing: error))
            sheet.dismiss()
            return .failure(error)
        }
    }
}

// AppKit shell hosting the SwiftUI sheet. Kept simple — no resizing, no
// title bar (sheets don't show theirs anyway), no delegate; the
// controller drives lifecycle explicitly.
@MainActor
private final class SheetHost {
    private let window: NSWindow
    private weak var parent: NSWindow?

    init(model: InstallProgressModel, title: String) {
        let host = NSHostingController(rootView: InstallProgressSheet(model: model))
        let initialSize = NSSize(width: 420, height: 160)
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        w.contentViewController = host
        w.title = title
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.setContentSize(initialSize)
        self.window = w
    }

    func present(over parent: NSWindow?) {
        self.parent = parent
        if let parent {
            parent.beginSheet(window) { _ in /* lifecycle driven by dismiss() */ }
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func dismiss() {
        if let parent {
            parent.endSheet(window)
        }
        window.close()
    }
}
