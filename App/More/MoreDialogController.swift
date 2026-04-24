import Foundation
import AppKit
import SwiftUI
import CiderModels
import CiderCore

// What the Save button hands back to the caller. `source` is nil when the
// user is editing an already-installed config and didn't drop a fresh
// source — Phase 8's Apply path treats that as "skip Installer, just
// rewrite cider.json + re-icon".
struct InstallPlan {
    let config: CiderConfig
    let mode: InstallMode
    let source: SourceAcquisition?
}

// Hosts MoreDialogView in its own NSWindow and presents it as a SHEET on
// the calling window (drop zone / splash). Sheet-based presentation is
// the only way SwiftUI controls behave reliably here — NSApp.runModal
// hosting causes SwiftUI buttons to render but never fire, leaving the
// dialog stuck. Callback-based since beginSheet is async.
@MainActor
final class MoreDialogController: NSObject, NSWindowDelegate {
    let vm = MoreDialogViewModel()
    private var window: NSWindow?
    private var completion: ((Outcome) -> Void)?

    // Static strong reference so the controller outlives the present()
    // call. Cleared in finish().
    private static var active: MoreDialogController?

    enum Outcome {
        case saved(InstallPlan)
        case cancelled
    }

    static func present(
        prefill: CiderConfig?,
        dropped: DropZoneViewModel.DroppedSource,
        initialError: String? = nil,
        completion: @escaping (Outcome) -> Void
    ) {
        // Re-entrancy guard: ignore if a dialog is already up.
        guard active == nil else { return }
        let controller = MoreDialogController()
        if let prefill { controller.vm.load(from: prefill) }
        controller.vm.seed(fromDrop: dropped)
        controller.vm.generalError = initialError
        controller.completion = completion
        active = controller
        controller.show()
    }

    private func show() {
        let view = MoreDialogView(
            vm: vm,
            // STRONG self — the controller is pinned alive by Self.active
            // for the lifetime of the dialog. This was the second bug
            // contributing to "buttons don't work": [weak self] meant the
            // closures became no-ops when the controller hit the autorelease
            // pool early.
            onCancel: { self.finish(.cancelled) },
            onSave: {
                let plan = InstallPlan(
                    config: self.vm.buildConfig(),
                    mode: self.vm.installMode,
                    source: self.vm.sourceAcquisition
                )
                self.finish(.saved(plan))
            }
        )
        let host = NSHostingController(rootView: view)
        let initialSize = NSSize(width: 620, height: 760)
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
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(initialSize)
        self.window = window

        // Sheet attached to whichever window is currently key (drop zone
        // or splash). Falls back to a regular ordered-front window if no
        // parent — the controller still hangs on to itself via Self.active
        // and the user can close it via the close-X / Cancel.
        if let parent = NSApp.keyWindow {
            parent.beginSheet(window) { _ in /* no-op; finish() drives outcome */ }
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func finish(_ outcome: Outcome) {
        let cb = completion
        completion = nil
        if let parent = window?.sheetParent, let w = window {
            parent.endSheet(w)
        }
        window?.close()
        window = nil
        Self.active = nil
        cb?(outcome)
    }

    // Red close-button: treat as cancel, end the sheet cleanly.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(.cancelled)
        return false   // we already closed/ended; tell AppKit not to
                       // double-process by returning false
    }
}
