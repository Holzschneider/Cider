import Foundation

// Installs the chosen graphics driver into the bundled Wine prefix.
//
// The Sikarugir Wrapper Template ships per-renderer DLLs in a clean tree:
//   Contents/Frameworks/renderer/<kind>/wine/x86_64-windows/*.dll  (64-bit)
//   Contents/Frameworks/renderer/<kind>/wine/i386-windows/*.dll    (32-bit)
//
// We mirror that into the prefix:
//   x86_64 → drive_c/windows/system32/   (used by 64-bit Windows apps)
//   i386   → drive_c/windows/syswow64/   (used by 32-bit apps via wow64)
//
// D3DMetal currently ships x86_64 only — that is expected; we warn but do not
// fail. WINEDLLOVERRIDES is set per kind so wine prefers the native (Metal)
// implementation, falling back to the builtin if the override file is missing.
struct GraphicsDriver {
    let kind: GraphicsDriverKind
    let prefix: URL
    let templateApp: URL
    let templateManager: TemplateManager

    struct Result {
        let dllOverrides: String
        let extraEnv: [String: String]
    }

    func install() throws -> Result {
        try installArch(.x86_64, into: "system32", required: true)
        try installArch(.i386, into: "syswow64", required: false)
        return Result(
            dllOverrides: kind.dllOverrides,
            extraEnv: extraEnv(for: kind)
        )
    }

    private func installArch(
        _ arch: TemplateManager.WineArch,
        into windowsSubdir: String,
        required: Bool
    ) throws {
        guard let source = templateManager.rendererDirectory(
            of: templateApp, kind: kind, arch: arch
        ) else {
            let level = required ? "error" : "warning"
            let msg = "no \(kind.rawValue) DLLs for \(arch.rawValue) in template — \(windowsSubdir) will use Wine builtins."
            if required { Log.warn(msg) } else { Log.debug(msg) }
            _ = level
            return
        }

        let destination = prefix
            .appendingPathComponent("drive_c")
            .appendingPathComponent("windows")
            .appendingPathComponent(windowsSubdir)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        var copied = 0
        for entry in entries where entry.pathExtension.lowercased() == "dll" {
            let dst = destination.appendingPathComponent(entry.lastPathComponent)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: entry, to: dst)
            copied += 1
        }
        Log.debug("installed \(copied) \(kind.rawValue) \(arch.rawValue) DLLs into \(windowsSubdir)")
    }

    private func extraEnv(for kind: GraphicsDriverKind) -> [String: String] {
        switch kind {
        case .d3dmetal: return ["MTL_HUD_ENABLED": "0"]
        case .dxmt:     return [:]
        case .dxvk:     return ["DXVK_HUD": "0"]
        }
    }
}
