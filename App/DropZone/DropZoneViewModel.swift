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
        case none

        var displayLabel: String {
            switch self {
            case .folder(let url): return "📁  \(url.lastPathComponent)"
            case .zip(let url):    return "🗜  \(url.lastPathComponent)"
            case .bareConfig:      return "📄  cider.json (loaded)"
            case .none:            return ""
            }
        }
    }

    @Published var dropped: DroppedSource = .none
    @Published var loadedConfig: CiderConfig? = nil
    @Published var statusMessage: String = ""
    @Published var isOptionPressed: Bool = false

    // Surfaced from MoreDialog's "Store cider.json in the source folder"
    // checkbox; consumed by the controller when transmogrifying.
    var storeInSourceFolderPreferred: Bool = false

    // Set by DropZoneController so the More dialog can be opened (Phase 9
    // wires the real flow; Phase 8 just stubs it).
    var openMoreDialog: ((CiderConfig?, DroppedSource) -> Void)?

    // Apply / Clone & Apply hooks. Phase 8 fills these in via the controller.
    var apply: (() -> Void)?
    var cloneAndApply: (() -> Void)?

    var canApply: Bool { loadedConfig != nil }

    var primaryButtonLabel: String {
        isOptionPressed ? "Clone & Apply…" : "Apply"
    }

    func handleDrop(_ url: URL) {
        statusMessage = ""
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
            statusMessage = "Unsupported drop: \(url.lastPathComponent). Drop a folder, .zip, or cider.json."
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
