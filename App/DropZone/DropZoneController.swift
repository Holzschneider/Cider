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
        // Phase-8 swap: default = Create (NSSavePanel), ALT = Apply in place.
        vm.create = { [weak self] in self?.startCreate() }
        vm.applyInPlace = { [weak self] in self?.startApplyInPlace() }
    }

    private func openMoreDialog(prefill: CiderConfig?, dropped: DropZoneViewModel.DroppedSource) {
        MoreDialogController.present(
            prefill: prefill ?? vm.loadedConfig,
            dropped: dropped == .none ? vm.dropped : dropped
        ) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .saved(let plan):
                self.vm.loadedConfig = plan.config
                self.vm.installPlan = plan
                self.vm.statusMessage = "Configured \"\(plan.config.displayName)\" (mode: \(plan.mode.rawValue)) — click Apply to land it."
            case .cancelled:
                break
            }
        }
    }

    // MARK: - Apply / Create entry points

    // ALT-held button. Transmogrifies the running Cider.app in place.
    private func startApplyInPlace() {
        guard let plan = vm.installPlan else { return }
        Task { await runApply(plan: plan, target: .applyInPlace) }
    }

    // Default button. NSSavePanel for the destination, then clone +
    // install + finalize at the chosen location.
    private func startCreate() {
        guard let plan = vm.installPlan else { return }
        let panel = NSSavePanel()
        panel.title = "Create configured Cider bundle"
        panel.message = "Choose where to save the configured .app."
        let suggested = BundleTransmogrifier.sanitiseBundleName(plan.config.displayName)
        panel.nameFieldStringValue = "\(suggested).app"
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task { await runApply(plan: plan, target: .cloneTo(dest)) }
    }

    // MARK: - Orchestrator

    enum ApplyTarget {
        case applyInPlace
        case cloneTo(URL)
    }

    private func runApply(plan: InstallPlan, target: ApplyTarget) async {
        let icnsURL: URL?
        do {
            icnsURL = try resolveIcon(for: plan.config)
        } catch {
            showAlert("Could not prepare icon", error)
            return
        }

        let currentBundle = bundleEnv.bundleURL
        let outcome = await InstallProgressController.run(
            parent: window,
            title: title(for: target)
        ) { progress in
            try await Self.performApply(
                plan: plan,
                target: target,
                currentBundle: currentBundle,
                icnsURL: icnsURL,
                progress: progress
            )
        }

        switch outcome {
        case .success(let finalBundle):
            // Relaunch the (renamed/cloned) bundle, then quit.
            let openProcess = Process()
            openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            openProcess.arguments = ["-n", finalBundle.path]
            try? openProcess.run()
            NSApplication.shared.terminate(nil)
        case .cancelled:
            vm.statusMessage = "Cancelled."
        case .failure(let error):
            showAlert("Could not apply configuration", error)
        }
    }

    private func title(for target: ApplyTarget) -> String {
        switch target {
        case .applyInPlace: return "Applying configuration"
        case .cloneTo:      return "Creating configured bundle"
        }
    }

    private func showAlert(_ title: String, _ error: Swift.Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // If the configured icon path is a PNG (or non-icns), convert it to
    // .icns once via IconConverter into a temp file. nil if there's no
    // icon configured.
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

    // MARK: - Static work (runs inside InstallProgressController.run)

    // Pulled to a static so it can run inside the @Sendable progress
    // closure without capturing `self` (which is @MainActor isolated).
    // `internal` for testability via @testable import CiderApp.
    static func performApply(
        plan: InstallPlan,
        target: ApplyTarget,
        currentBundle: URL,
        icnsURL: URL?,
        progress: @escaping InstallProgressCallback
    ) async throws -> URL {
        // 1. Resolve target bundle URL + clone if needed.
        let bundle: URL
        var partialClone: URL? = nil
        switch target {
        case .applyInPlace:
            bundle = currentBundle
        case .cloneTo(let dest):
            bundle = dest
            // Refuse to clobber existing paths — Phase 10's --force will
            // change this; for now surface the conflict immediately.
            if FileManager.default.fileExists(atPath: dest.path) {
                throw OrchestratorError.targetExists(dest)
            }
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            progress(.stage("Cloning bundle", detail: dest.lastPathComponent))
            // cp -a preserves codesign xattrs.
            try await Shell.runAsync("/bin/cp", ["-a", currentBundle.path, dest.path],
                                     captureOutput: true)
            partialClone = dest
        }

        do {
            // 2. Wipe stale in-bundle config unless Bundle mode is going
            //    to write a fresh one there.
            try wipeStaleInBundleConfig(at: bundle, keepingForBundleMode: plan.mode == .bundle)

            // 3. Install (writes data + cider.json) when a fresh source
            //    is provided. Otherwise just rewrite cider.json in place.
            if let source = plan.source {
                _ = try await Installer().run(
                    source: source,
                    mode: plan.mode,
                    baseConfig: plan.config,
                    bundleURL: bundle,
                    progress: progress
                )
            } else {
                progress(.stage("Writing configuration", detail: ""))
                let configURL = configURL(for: plan, bundle: bundle)
                try plan.config.write(to: configURL)
            }

            // 4. Apply Finder custom icon (sibling of Contents/, signature-safe).
            if let icnsURL {
                progress(.stage("Applying icon", detail: ""))
                _ = IconConverter.applyAsCustomIcon(at: icnsURL, to: bundle)
            }

            // 5. Rename in-place bundles to <DisplayName>.app. Clone-to
            //    bundles use the user-picked filename as-is.
            let final: URL
            if case .applyInPlace = target {
                final = try renameToDisplayName(bundle, displayName: plan.config.displayName)
            } else {
                final = bundle
            }

            partialClone = nil  // success — keep the cloned bundle
            return final
        } catch {
            // Roll back a half-cloned bundle so a cancel / mid-install
            // failure doesn't leave junk on disk for Create mode. Apply
            // mode mutated the running bundle in place — we can't roll
            // that back without recording the original state.
            if let partial = partialClone {
                try? FileManager.default.removeItem(at: partial)
            }
            throw error
        }
    }

    static func wipeStaleInBundleConfig(at bundle: URL, keepingForBundleMode: Bool) throws {
        let staleCider = bundle.appendingPathComponent("cider.json")
        if !keepingForBundleMode, FileManager.default.fileExists(atPath: staleCider.path) {
            try FileManager.default.removeItem(at: staleCider)
        }
        // v1 schema parked the override under CiderConfig/. Always remove it.
        let v1 = bundle.appendingPathComponent("CiderConfig", isDirectory: true)
        if FileManager.default.fileExists(atPath: v1.path) {
            try FileManager.default.removeItem(at: v1)
        }
    }

    static func configURL(for plan: InstallPlan, bundle: URL) -> URL {
        switch plan.mode {
        case .bundle:
            return bundle.appendingPathComponent("cider.json")
        case .install, .link:
            let name = BundleTransmogrifier.sanitiseBundleName(plan.config.displayName)
            return AppSupport.config(forBundleNamed: name)
        }
    }

    static func renameToDisplayName(_ bundle: URL, displayName: String) throws -> URL {
        let targetName = BundleTransmogrifier.sanitiseBundleName(displayName)
        guard !targetName.isEmpty else {
            throw OrchestratorError.emptyDisplayName
        }
        let parent = bundle.deletingLastPathComponent()
        let renamed = parent.appendingPathComponent("\(targetName).app", isDirectory: true)
        if renamed == bundle {
            return bundle
        }
        if FileManager.default.fileExists(atPath: renamed.path) {
            throw OrchestratorError.targetExists(renamed)
        }
        try FileManager.default.moveItem(at: bundle, to: renamed)
        return renamed
    }

    enum OrchestratorError: Swift.Error, CustomStringConvertible {
        case emptyDisplayName
        case targetExists(URL)
        var description: String {
            switch self {
            case .emptyDisplayName:
                return "Display name is empty — fill it in via More… first."
            case .targetExists(let url):
                return "A bundle already exists at \(url.path). Pick a different name or remove the existing one."
            }
        }
    }
}
