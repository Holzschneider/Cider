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
        self.window = window

        // Show the window invisible so SwiftUI can lay it out without
        // the user seeing the default position. Once layout settles on
        // the next runloop tick, centre it and fade in. This is the
        // simplest reliable way to avoid the "appears off, snaps to
        // centre" flicker — no measurement before show, no fighting
        // sizeThatFits / NSHostingController layout-timing quirks.
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.centerOnScreen(window)
            window.alphaValue = 1
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak vm] event in
            vm?.isOptionPressed = event.modifierFlags.contains(.option)
            return event
        }
    }

    // Geometric centre against the visible area (excluding menu bar and
    // Dock). NSWindow.center() biases toward the upper third on purpose
    // ("alert area" convention).
    private func centerOnScreen(_ window: NSWindow) {
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let frame = window.frame
        let origin = NSPoint(
            x: (visible.midX - frame.width / 2).rounded(),
            y: (visible.midY - frame.height / 2).rounded()
        )
        window.setFrameOrigin(origin)
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
        MoreDialogController.present(
            prefill: prefill ?? vm.loadedConfig,
            dropped: dropped == .none ? vm.dropped : dropped
        ) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .saved(let cfg, let storeInSource):
                self.vm.loadedConfig = cfg
                self.vm.storeInSourceFolderPreferred = storeInSource
                self.vm.statusMessage = "Configured \"\(cfg.displayName)\" — click Apply to land it."
            case .cancelled:
                break
            }
        }
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

    // Decide where to write cider.json based on the user's MoreDialog
    // preference + which source mode is active. "Store in source folder"
    // only makes sense for mode=.path; otherwise we fall through to
    // AppSupport.
    private func computeStorage(for config: CiderConfig) -> BundleTransmogrifier.ConfigStorage {
        if vm.storeInSourceFolderPreferred,
           config.source.mode == .path,
           let path = config.source.path {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
               isDir.boolValue {
                return .sourceFolder(url)
            }
        }
        return .appSupport
    }

    // If the configured icon path is a PNG (or non-icns), convert it to
    // .icns once via IconConverter into a temp file and pass that to
    // BundleTransmogrifier. nil if there's no icon configured.
    private func resolveIcon(for config: CiderConfig) throws -> URL? {
        guard let iconPath = config.icon, !iconPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: iconPath)
        if url.pathExtension.lowercased() == "icns" {
            return url
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-icon-\(UUID().uuidString).icns")
        try IconConverter.convert(png: url, destination: tmp)
        return tmp
    }

    private func runTransmogrification(config: CiderConfig, mode: BundleTransmogrifier.Mode) {
        do {
            let storage = computeStorage(for: config)
            let icnsURL = try resolveIcon(for: config)
            let result = try BundleTransmogrifier(
                currentBundle: bundleEnv.bundleURL,
                config: config,
                icnsURL: icnsURL,
                storage: storage,
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
