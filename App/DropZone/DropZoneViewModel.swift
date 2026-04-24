import Foundation
import AppKit
import Combine
import CiderModels
import CiderCore

// State driving the drop-zone window. Holds the memorised source URL,
// any pre-loaded cider.json from the drop, and the option-key state for
// the Apply ↔ Clone & Apply button label.
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

    // Apply / Clone & Apply hooks. Phase 8 fills these in via the controller.
    var apply: (() -> Void)?
    var cloneAndApply: (() -> Void)?

    var canApply: Bool { loadedConfig != nil }

    var primaryButtonLabel: String {
        isOptionPressed ? "Clone & Apply…" : "Apply"
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
            // Auto-detect cider.json inside the folder.
            let candidate = url.appendingPathComponent("cider.json")
            if fm.fileExists(atPath: candidate.path) {
                loadConfigFromDisk(candidate, label: "from \(url.lastPathComponent)/cider.json")
            } else {
                loadedConfig = nil
                statusMessage = "Folder has no cider.json — click More… to configure."
                openMoreDialog?(nil, dropped)
            }
            return
        }

        switch url.pathExtension.lowercased() {
        case "json":
            dropped = .bareConfig(url)
            loadConfigFromDisk(url, label: "loaded from \(url.lastPathComponent)")
        case "zip":
            dropped = .zip(url)
            if let cfg = peekZipForConfig(url) {
                loadedConfig = cfg
                statusMessage = "Loaded cider.json from inside \(url.lastPathComponent)."
            } else {
                loadedConfig = nil
                statusMessage = "Zip has no cider.json at root — click More… to configure."
                openMoreDialog?(nil, dropped)
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
                    statusMessage = "URL points at a zip — click More… to configure, then Apply to download and install."
                    openMoreDialog?(nil, dropped)
                case .ciderJSON(let cfg, let dataURL, _):
                    loadedConfig = cfg
                    if dataURL == nil {
                        statusMessage = "Loaded cider.json from \(url.absoluteString) — but it has no distributionURL. Add one in More… before applying."
                        openMoreDialog?(cfg, dropped)
                    } else {
                        statusMessage = "Loaded cider.json from \(url.absoluteString)."
                    }
                }
            } catch {
                statusMessage = "Could not resolve URL: \(error)"
            }
        }
    }

    private func loadConfigFromDisk(_ url: URL, label: String) {
        do {
            loadedConfig = try CiderConfig.read(from: url)
            statusMessage = label
        } catch {
            loadedConfig = nil
            statusMessage = "Could not parse cider.json: \(error)"
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
