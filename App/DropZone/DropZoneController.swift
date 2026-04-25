import Foundation
import AppKit
import SwiftUI
import CiderModels
import CiderCore

// Wires the DropZone window to its view-model and the Create / Apply
// actions. Listens for option-key flag changes via NSEvent and forwards
// them into the view-model so the primary button label can swap live
// (default is Create…; ALT swaps to Apply).
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
            icnsURL = try resolveIcon(for: plan.config, source: plan.source)
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
            // Phase 9: auto-reopen MoreDialog with the failure surfaced
            // as a banner. Lets the user fix the offending field and try
            // again without retyping everything.
            reopenMoreDialogWithError(plan: plan, error: error)
        }
    }

    private func reopenMoreDialogWithError(plan: InstallPlan, error: Swift.Error) {
        let message = String(describing: error)
        vm.statusMessage = "Apply failed — see More… for details."
        MoreDialogController.present(
            prefill: plan.config,
            dropped: vm.dropped,
            initialError: message
        ) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .saved(let updated):
                self.vm.loadedConfig = updated.config
                self.vm.installPlan = updated
                self.vm.statusMessage = "Configured \"\(updated.config.displayName)\" (mode: \(updated.mode.rawValue)) — click Create… or hold ⌥ for Apply."
            case .cancelled:
                break
            }
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

    // If the configured icon path isn't already .icns, convert it to one
    // via IconConverter. Accepts PNG, JPEG, and Windows .ico (and
    // anything else NSImage can read). Relative icon paths are resolved
    // against the source folder (only meaningful for `.folder` sources).
    // nil if there's no icon configured.
    private func resolveIcon(for config: CiderConfig, source: SourceAcquisition?) throws -> URL? {
        guard let iconPath = config.icon, !iconPath.isEmpty else { return nil }
        let expanded = (iconPath as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded)
        } else if case .folder(let folder)? = source {
            url = folder.appendingPathComponent(expanded)
        } else {
            // Relative path with no folder source to resolve against —
            // fall back to CWD-relative (the legacy behaviour).
            url = URL(fileURLWithPath: expanded)
        }
        if url.pathExtension.lowercased() == "icns" {
            return url
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-icon-\(UUID().uuidString).icns")
        try IconConverter.convert(image: url, destination: tmp)
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

            // 3. Phase-10 rename-on-Save: if the user changed the
            //    Application Name AND we're editing an existing
            //    install (no fresh source), move the AppSupport assets
            //    to the new name *before* writing the new config.
            //    For with-source applies the Installer writes fresh
            //    data anyway, so we just clean up the old name in
            //    step 6.
            let oldName = previousAppSupportName(currentBundle: currentBundle, target: target)
            let newName = BundleTransmogrifier.sanitiseBundleName(plan.config.displayName)
            var effectiveConfig = plan.config
            if plan.source == nil, let oldName, !oldName.isEmpty, oldName != newName {
                progress(.stage("Renaming application", detail: "\(oldName) → \(newName)"))
                effectiveConfig = try renameAppSupportAssets(
                    from: oldName, to: newName,
                    config: plan.config, mode: plan.mode
                )
            }

            // 4. Install (writes data + cider.json) when a fresh source
            //    is provided. Otherwise just rewrite cider.json in place.
            if let source = plan.source {
                _ = try await Installer().run(
                    source: source,
                    mode: plan.mode,
                    baseConfig: effectiveConfig,
                    bundleURL: bundle,
                    progress: progress
                )
            } else {
                progress(.stage("Writing configuration", detail: ""))
                let target = configURL(forName: newName, mode: plan.mode, bundle: bundle)
                try effectiveConfig.write(to: target)
            }

            // 5. With-source orphan cleanup: a fresh install under a new
            //    name leaves the old AppSupport entries behind. Remove
            //    them now that the new ones are in place.
            if plan.source != nil, let oldName, !oldName.isEmpty, oldName != newName {
                cleanupOrphanedAppSupport(name: oldName, mode: plan.mode)
            }

            // 6. Apply Finder custom icon (sibling of Contents/, signature-safe).
            if let icnsURL {
                progress(.stage("Applying icon", detail: ""))
                _ = IconConverter.applyAsCustomIcon(at: icnsURL, to: bundle)
            }

            // 7. Rename in-place bundles to <Application Name>.app.
            //    Clone-to bundles use the user-picked filename as-is.
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

    nonisolated static func wipeStaleInBundleConfig(at bundle: URL, keepingForBundleMode: Bool) throws {
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

    nonisolated static func configURL(for plan: InstallPlan, bundle: URL) -> URL {
        let name = BundleTransmogrifier.sanitiseBundleName(plan.config.displayName)
        return configURL(forName: name, mode: plan.mode, bundle: bundle)
    }

    nonisolated static func configURL(forName name: String, mode: InstallMode, bundle: URL) -> URL {
        switch mode {
        case .bundle:
            return bundle.appendingPathComponent("cider.json")
        case .install, .link:
            return AppSupport.config(forBundleNamed: name)
        }
    }

    // MARK: - Phase 10: rename-on-Save helpers

    // Returns the AppSupport key the running bundle currently uses
    // (its filename stem), or nil for the vanilla `Cider` bundle and
    // for Create flows (cloning starts a fresh slot, not a rename).
    nonisolated static func previousAppSupportName(currentBundle: URL, target: ApplyTarget) -> String? {
        guard case .applyInPlace = target else { return nil }
        let stem = currentBundle.deletingPathExtension().lastPathComponent
        return stem == "Cider" ? nil : stem
    }

    // Moves the AppSupport assets from <oldName> to <newName> and
    // returns a config with `applicationPath` re-pointed at the new
    // location (Install mode only — Link's path is external, Bundle
    // doesn't use AppSupport for its config).
    @discardableResult
    nonisolated static func renameAppSupportAssets(
        from oldName: String,
        to newName: String,
        config: CiderConfig,
        mode: InstallMode
    ) throws -> CiderConfig {
        let fm = FileManager.default
        var updated = config

        switch mode {
        case .install:
            let oldDir = AppSupport.programFiles(forBundleNamed: oldName)
            let newDir = AppSupport.programFiles(forBundleNamed: newName)
            if fm.fileExists(atPath: oldDir.path) {
                if fm.fileExists(atPath: newDir.path) {
                    throw OrchestratorError.targetExists(newDir)
                }
                try fm.createDirectory(
                    at: newDir.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fm.moveItem(at: oldDir, to: newDir)
            }
            updated.applicationPath = newDir.standardizedFileURL.path
        case .link:
            // Link points at an external folder — nothing to move.
            break
        case .bundle:
            // Bundle's data lives inside the .app, not AppSupport.
            break
        }

        // Move the cider.json file too. If the old config doesn't exist
        // (e.g. first edit after manual rename), that's fine — we'll
        // just write the new one.
        let oldCfg = AppSupport.config(forBundleNamed: oldName)
        let newCfg = AppSupport.config(forBundleNamed: newName)
        if fm.fileExists(atPath: oldCfg.path), !fm.fileExists(atPath: newCfg.path) {
            try fm.createDirectory(
                at: newCfg.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.moveItem(at: oldCfg, to: newCfg)
        }
        return updated
    }

    // Removes the AppSupport entries belonging to `name`. Called after a
    // with-source apply renamed the application — the Installer wrote
    // fresh data under the new name, so the old slot is orphaned.
    // Best-effort: silently ignore missing files / errors. Bundle mode
    // doesn't touch AppSupport, so this is a no-op for it.
    nonisolated static func cleanupOrphanedAppSupport(name: String, mode: InstallMode) {
        let fm = FileManager.default
        switch mode {
        case .install:
            try? fm.removeItem(at: AppSupport.programFiles(forBundleNamed: name))
        case .link, .bundle:
            break
        }
        try? fm.removeItem(at: AppSupport.config(forBundleNamed: name))
    }

    nonisolated static func renameToDisplayName(_ bundle: URL, displayName: String) throws -> URL {
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
                return "Application Name is empty — fill it in via More… first."
            case .targetExists(let url):
                return "A bundle already exists at \(url.path). Pick a different name or remove the existing one."
            }
        }
    }
}
