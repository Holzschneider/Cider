import Foundation
import AppKit
import SwiftUI
import CiderModels

// Hosts MoreDialogView in its own NSWindow. Modal-ish: blocks the
// caller via NSApp.runModal(for:). Phase 9 calls this from DropZone's
// "More…" button and from Splash's double-click reopen path.
@MainActor
final class MoreDialogController {
    let vm = MoreDialogViewModel()
    private var window: NSWindow?

    // The result populated when the user clicks Save. nil → cancelled.
    enum Outcome {
        case saved(CiderConfig, storeInSourceFolder: Bool)
        case cancelled
    }

    // Convenience: present synchronously and return the user's choice.
    static func present(prefill: CiderConfig?, dropped: DropZoneViewModel.DroppedSource) -> Outcome {
        let controller = MoreDialogController()
        if let prefill {
            controller.vm.load(from: prefill)
        }
        controller.vm.seed(fromDrop: dropped)
        return controller.runModal()
    }

    private func runModal() -> Outcome {
        var outcome: Outcome = .cancelled
        let view = MoreDialogView(
            vm: vm,
            onCancel: { [weak self] in
                outcome = .cancelled
                self?.endModal()
            },
            onSave: { [weak self] cfg in
                outcome = .saved(cfg, storeInSourceFolder: self?.vm.storeInSourceFolder ?? false)
                self?.endModal()
            }
        )
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = "Cider — Configuration"
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        NSApp.runModal(for: window)
        window.orderOut(nil)
        return outcome
    }

    private func endModal() {
        NSApp.stopModal()
    }
}
