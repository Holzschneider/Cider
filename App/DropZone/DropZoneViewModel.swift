import Foundation
import AppKit
import Combine
import CiderModels
import CiderCore

// State driving the drop-zone window. Holds the memorised source URL,
// any pre-loaded cider.json from the drop, and the option-key state for
// the Create… ↔ Apply button-label swap.
@MainActor
final class DropZoneViewModel: ObservableObject {
    enum DroppedSource: Equatable {
        case folder(URL)            // memorised path, NOT copied per UX spec
        case zip(URL)               // memorised path
        case bareConfig(URL)        // a plain cider.json — content matters, not path
        case url(URL)               // remote URL (zip, or cider.json indirection)
        case none

        // The on-disk URL we use both for memorisation and (cosmetically)
        // for fetching the macOS file icon to render in the drop zone.
        // Returns nil for remote URLs since they have no file icon.
        var sourceURL: URL? {
            switch self {
            case .folder(let url), .zip(let url), .bareConfig(let url): return url
            case .url, .none: return nil
            }
        }

        // Display-friendly label for the dropped item (file name for local,
        // host+path for remote URLs).
        var label: String? {
            switch self {
            case .folder(let url), .zip(let url), .bareConfig(let url):
                return url.lastPathComponent
            case .url(let url):
                return url.absoluteString
            case .none:
                return nil
            }
        }
    }

    @Published var dropped: DroppedSource = .none
    @Published var loadedConfig: CiderConfig? = nil
    // The full install plan from MoreDialog (config + mode + source).
    // Phase 8 hands this to Installer.run() on Apply / Create.
    var installPlan: InstallPlan? = nil
    @Published var statusMessage: String = ""
    @Published var isOptionPressed: Bool = false

    // (storeInSourceFolderPreferred removed in schema-v2; Phase 6
    // re-introduces storage choice via the install-mode picker.)

    // Set by DropZoneController so the More dialog can be opened (Phase 9
    // wires the real flow; Phase 8 just stubs it).
    var openMoreDialog: ((CiderConfig?, DroppedSource) -> Void)?

    // Reset to the empty / unconfigured state. Wired to the drop area's
    // double-click + the hover-revealed ✕ button.
    func clearSource() {
        dropped = .none
        loadedConfig = nil
        statusMessage = ""
    }

    // Phase-8 swap: default action is "Create…" (clone-to-new-bundle via
    // NSSavePanel), ALT-held is "Apply" (in-place transformation of the
    // running Cider.app). The names swap on screen as the user holds /
    // releases ALT.
    var create: (() -> Void)?
    var applyInPlace: (() -> Void)?

    var canApply: Bool { loadedConfig != nil }

    var primaryButtonLabel: String {
        isOptionPressed ? "Apply" : "Create…"
    }

    func handleDrop(_ url: URL) {
        statusMessage = ""

        // Web URLs (http/https) take the URL-source path: HEAD-disambiguate
        // and either record the URL for the Installer to download, or
        // (for cider.json) fetch + pre-populate MoreDialog.
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            handleWebURL(url)
            return
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            statusMessage = "Dropped item not found: \(url.path)"
            return
        }

        if isDir.boolValue {
            dropped = .folder(url)
            // Auto-detect cider.json in this priority order:
            //   1. AppSupport/Configs/<sanitised-folder-name>.json —
            //      lets a previously-saved config flow back in even if
            //      the user never saved a copy alongside the source.
            //   2. <dropped>/cider.json — distributor-shipped config
            //      living inside the source tree.
            // Either parse → set loadedConfig + synthesise installPlan
            // so Create / Apply work without a Configure round-trip.
            for probe in autoLoadProbes(for: url) {
                guard fm.fileExists(atPath: probe.url.path) else { continue }
                if tryLoadConfig(from: probe.url, label: probe.label) {
                    if let cfg = loadedConfig {
                        installPlan = Self.synthesisePlan(
                            from: cfg, droppedFolder: url)
                    }
                    return
                }
                // Parse failed for this candidate — keep probing.
            }
            statusMessage = "No matching Cider configuration found — click Configure to set it up."
            loadedConfig = nil
            return
        }

        switch url.pathExtension.lowercased() {
        case "json":
            dropped = .bareConfig(url)
            if !tryLoadConfig(from: url, label: "loaded from \(url.lastPathComponent)") {
                statusMessage = "\(url.lastPathComponent) isn't a valid Cider v2 config — click Configure to set it up."
            }
        case "zip":
            dropped = .zip(url)
            if let cfg = peekZipForConfig(url) {
                loadedConfig = cfg
                statusMessage = "Loaded cider.json from inside \(url.lastPathComponent)."
            } else {
                loadedConfig = nil
                statusMessage = "Zip has no cider.json at root — click Configure to set it up."
            }
        default:
            statusMessage = "Unsupported drop: \(url.lastPathComponent). Drop a folder, .zip, cider.json, or a URL."
        }
    }

    // MARK: - Web URL handling (Phase 5)

    private func handleWebURL(_ url: URL) {
        dropped = .url(url)
        loadedConfig = nil
        statusMessage = "Resolving \(url.absoluteString)…"
        Task { @MainActor in
            do {
                let resolved = try await URLSourceResolver.resolve(url: url)
                switch resolved {
                case .zip:
                    statusMessage = "URL points at a zip — click Configure, then Apply to download and install."
                case .ciderJSON(let cfg, let dataURL, _):
                    loadedConfig = cfg
                    if dataURL == nil {
                        statusMessage = "Loaded cider.json from \(url.absoluteString) — but it has no distributionURL. Click Configure and add one before applying."
                    } else {
                        statusMessage = "Loaded cider.json from \(url.absoluteString)."
                    }
                }
            } catch {
                statusMessage = "Could not resolve URL: \(error)"
            }
        }
    }

    // Two-stage probe: AppSupport-by-folder-name first, then the
    // dropped folder's own cider.json. Order is load-bearing — a user
    // who renamed their source dir but kept the AppSupport config
    // should pick up the saved config rather than nothing.
    struct AutoLoadProbe {
        let url: URL
        let label: String
    }

    private func autoLoadProbes(for folder: URL) -> [AutoLoadProbe] {
        let bundleName = BundleTransmogrifier.sanitiseBundleName(
            folder.lastPathComponent)
        var probes: [AutoLoadProbe] = []
        if !bundleName.isEmpty {
            probes.append(AutoLoadProbe(
                url: AppSupport.config(forBundleNamed: bundleName),
                label: "Loaded \(bundleName) from Application Support."
            ))
        }
        probes.append(AutoLoadProbe(
            url: folder.appendingPathComponent("cider.json"),
            label: "Loaded cider.json from \(folder.lastPathComponent)/."
        ))
        return probes
    }

    // Build an InstallPlan from an auto-loaded config so the Create /
    // Apply buttons can fire directly (no Configure round-trip
    // needed). Mode is inferred from applicationPath the same way
    // MoreDialogViewModel does; source is the dropped folder itself.
    static func synthesisePlan(from config: CiderConfig,
                               droppedFolder: URL) -> InstallPlan {
        InstallPlan(
            config: config,
            mode: MoreDialogViewModel.inferMode(from: config.applicationPath),
            source: .folder(droppedFolder)
        )
    }

    // Returns true on a clean v2-schema parse (loadedConfig + status set);
    // false if the file is missing required fields / malformed (caller
    // decides whether to surface a friendly fallback message).
    @discardableResult
    private func tryLoadConfig(from url: URL, label: String) -> Bool {
        do {
            loadedConfig = try CiderConfig.read(from: url)
            statusMessage = label
            return true
        } catch {
            loadedConfig = nil
            return false
        }
    }

    // Peek inside a zip for a top-level `cider.json` without doing a full
    // extract. `unzip -p` writes the file content to stdout (or fails if
    // not present).
    private func peekZipForConfig(_ zipURL: URL) -> CiderConfig? {
        let result = try? Shell.run("/usr/bin/unzip", ["-p", zipURL.path, "cider.json"],
                                    captureOutput: true)
        guard let r = result, !r.stdout.isEmpty,
              let data = r.stdout.data(using: .utf8) else { return nil }
        return try? CiderConfig.decode(data)
    }
}
