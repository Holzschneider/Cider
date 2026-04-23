import Foundation
import AppKit
import SwiftUI
import CiderModels
import CiderCore

// Wires the DropZone window to its view-model and the Apply / Clone & Apply
// actions. Listens for option-key flag changes via NSEvent and forwards
// them into the view-model so the primary button label can swap live.
@MainActor
final class DropZoneController {
    private let vm = DropZoneViewModel()
    private var window: NSWindow?
    private var flagsMonitor: Any?

    let bundleEnv: BundleEnvironment

    init(bundleEnv: BundleEnvironment) {
        self.bundleEnv = bundleEnv
        wireActions()
    }

    func attach() {
        let view = DropZoneView(vm: vm)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "Cider"
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak vm] event in
            vm?.isOptionPressed = event.modifierFlags.contains(.option)
            return event
        }
    }

    deinit {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
        }
    }

    // MARK: - Action wiring

    private func wireActions() {
        vm.openMoreDialog = { [weak self] cfg, dropped in
            self?.openMoreDialog(prefill: cfg, dropped: dropped)
        }
        vm.apply = { [weak self] in self?.applyInPlace() }
        vm.cloneAndApply = { [weak self] in self?.cloneAndApply() }
    }

    private func openMoreDialog(prefill: CiderConfig?, dropped: DropZoneViewModel.DroppedSource) {
        // Phase 9 lands the real form. Phase 8 surfaces a placeholder so
        // the wiring is exercised end-to-end.
        let alert = NSAlert()
        alert.messageText = "More… (Phase 9)"
        alert.informativeText =
            "The full configuration form lands in the next phase. " +
            "For now, drop a folder containing a cider.json or a bare cider.json " +
            "to enable Apply."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func applyInPlace() {
        guard let cfg = vm.loadedConfig else { return }
        runTransmogrification(config: cfg, mode: .applyInPlace)
    }

    private func cloneAndApply() {
        guard let cfg = vm.loadedConfig else { return }
        let panel = NSSavePanel()
        panel.title = "Clone & Apply"
        panel.message = "Choose where to save the configured Cider bundle."
        let suggested = BundleTransmogrifier.sanitiseBundleName(cfg.displayName)
        panel.nameFieldStringValue = "\(suggested).app"
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        runTransmogrification(config: cfg, mode: .cloneTo(dest))
    }

    private func runTransmogrification(config: CiderConfig, mode: BundleTransmogrifier.Mode) {
        do {
            let result = try BundleTransmogrifier(
                currentBundle: bundleEnv.bundleURL,
                config: config,
                icnsURL: nil,                  // Phase 9 wires icon
                storage: .appSupport,
                allowOverwrite: false
            ).transmogrify(mode: mode)

            // Relaunch the (renamed/cloned) bundle, then quit current.
            let openProcess = Process()
            openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            openProcess.arguments = ["-n", result.finalBundleURL.path]
            try openProcess.run()
            NSApplication.shared.terminate(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not apply configuration"
            alert.informativeText = String(describing: error)
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
