import Foundation
import CiderModels

// Detects when an Application Name the user typed in MoreDialog would
// collide with state already on disk under another bundle's slot:
//
//   * Install mode: Configs/<Name>.json OR Program Files/<Name>/
//     already exists. Both paths belong to the AppSupport key derived
//     from the bundle name; using the same name from a different
//     bundle would silently overwrite it on Create.
//   * Link mode: only Configs/<Name>.json — Link doesn't own a
//     Program Files slot.
//   * Bundle mode: no AppSupport state, no clash possible.
//
// `originalName` lets the caller distinguish "the user is editing
// their own existing config" (the slot exists, but it belongs to
// them) from "the user just typed a name that another bundle owns".
// Pass nil for fresh-create flows.
public enum NameClashChecker {

    public static func clash(
        for name: String,
        mode: InstallMode,
        originalName: String?,
        fileManager: FileManager = .default
    ) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Editing in place: the slot belongs to us, ignore.
        if let originalName,
           originalName.trimmingCharacters(in: .whitespaces) == trimmed {
            return nil
        }

        switch mode {
        case .bundle:
            return nil

        case .install:
            let cfg = AppSupport.config(forBundleNamed: trimmed)
            let pf  = AppSupport.programFiles(forBundleNamed: trimmed)
            if fileManager.fileExists(atPath: cfg.path) {
                return "Another bundle already owns the Application Support slot \"\(trimmed)\". Pick a different Application Name or remove \(cfg.path)."
            }
            if fileManager.fileExists(atPath: pf.path) {
                return "Application Support already has a Program Files folder for \"\(trimmed)\" — using this name would overwrite it. Pick a different Application Name or remove \(pf.path)."
            }
            return nil

        case .link:
            let cfg = AppSupport.config(forBundleNamed: trimmed)
            if fileManager.fileExists(atPath: cfg.path) {
                return "Another bundle already owns the Application Support slot \"\(trimmed)\". Pick a different Application Name or remove \(cfg.path)."
            }
            return nil
        }
    }
}
