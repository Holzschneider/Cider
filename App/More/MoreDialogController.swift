import Foundation
import AppKit
import SwiftUI
import CiderModels

// Hosts MoreDialogView in its own NSWindow and presents it modally via
// NSApp.runModal. Returns the user's choice synchronously so callers
// (DropZone "More…" button, Splash double-click) can drive the next step.
@MainActor
final class MoreDialogController: NSObject, NSWindowDelegate {
    let vm = MoreDialogViewModel()
    private var window: NSWindow?
    private var outcome: Outcome = .cancelled

    enum Outcome {
        case saved(CiderConfig, storeInSourceFolder: Bool)
        case cancelled
    }

    static func present(prefill: CiderConfig?, dropped: DropZoneViewModel.DroppedSource) -> Outcome {
        let controller = MoreDialogController()
        if let prefill {
            controller.vm.load(from: prefill)
        }
        controller.vm.seed(fromDrop: dropped)
        return controller.runModal()
    }

    private func runModal() -> Outcome {
        let view = MoreDialogView(
            vm: vm,
            onCancel: { [weak self] in
                self?.outcome = .cancelled
                self?.endModal()
            },
            onSave: { [weak self] cfg in
                self?.outcome = .saved(cfg, storeInSourceFolder: self?.vm.storeInSourceFolder ?? false)
                self?.endModal()
            }
        )
        let host = NSHostingController(rootView: view)

        // Build the window with the right style mask up-front (mutating
        // it after a default init is the source of the focus/cursor
        // weirdness — first responder gets stuck on whatever the default
        // style attached). .resizable so the user can grow the window if
        // the default 720pt height isn't enough on smaller displays.
        let initialSize = NSSize(width: 620, height: 720)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        window.title = "Cider — Configuration"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        // Force the content area to our explicit size — NSHostingController
        // otherwise picks the SwiftUI MIN size, clipping the buttons.
        window.setContentSize(initialSize)
        self.window = window

        // Make sure the modal window actually becomes key BEFORE runModal
        // hands control to NSApp's modal session — otherwise SwiftUI
        // TextFields stay non-key and won't show a cursor or accept paste.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return outcome
    }

    private func endModal() {
        NSApp.stopModal()
    }

    // The red close button ("X") doesn't go through onCancel — handle it
    // here so the modal session ends and the parent (drop zone) regains
    // input. Treat close-via-X as a cancel.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        outcome = .cancelled
        endModal()
        return true
    }
}
