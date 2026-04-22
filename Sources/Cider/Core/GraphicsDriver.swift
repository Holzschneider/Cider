import Foundation

// Installs the chosen graphics driver into the bundled Wine prefix.
// For v1 we stage the necessary DLLs into drive_c/windows/system32 and record
// the WINEDLLOVERRIDES string for the launcher. We deliberately avoid
// downloading DXMT/DXVK binaries at build time when the engine already ships
// with the DLLs we need (CrossOver engines bundle D3DMetal); this keeps the
// offline path working.
struct GraphicsDriver {
    let kind: GraphicsDriverKind
    let prefix: URL
    let engineRoot: URL

    struct Result {
        let dllOverrides: String
        let extraEnv: [String: String]
    }

    func install() throws -> Result {
        switch kind {
        case .d3dmetal:
            try installFromEngineIfAvailable(
                searchPaths: [
                    "lib/external/D3DMetal",
                    "lib64/external/D3DMetal",
                    "D3DMetal"
                ],
                requiredDLLs: ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "d3d12.dll"]
            )
        case .dxmt:
            try installFromEngineIfAvailable(
                searchPaths: ["lib/external/DXMT", "DXMT"],
                requiredDLLs: ["d3d11.dll", "dxgi.dll", "d3d10core.dll"]
            )
        case .dxvk:
            try installFromEngineIfAvailable(
                searchPaths: ["lib/external/DXVK", "DXVK"],
                requiredDLLs: ["d3d9.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll"]
            )
        }

        return Result(
            dllOverrides: kind.dllOverrides,
            extraEnv: extraEnv(for: kind)
        )
    }

    // Looks for the required DLLs inside the engine and copies them into
    // system32. If not found, leaves the prefix alone and warns — the user may
    // have selected a driver the engine doesn't ship, and Wine will fall back
    // to its builtin behaviour.
    private func installFromEngineIfAvailable(
        searchPaths: [String],
        requiredDLLs: [String]
    ) throws {
        let fm = FileManager.default
        let system32 = prefix
            .appendingPathComponent("drive_c")
            .appendingPathComponent("windows")
            .appendingPathComponent("system32")

        // Try a few relative directories under engineRoot.
        for rel in searchPaths {
            let base = engineRoot.appendingPathComponent(rel, isDirectory: true)
            guard fm.fileExists(atPath: base.path) else { continue }
            var copiedAny = false
            for dll in requiredDLLs {
                let src = base.appendingPathComponent(dll)
                guard fm.fileExists(atPath: src.path) else { continue }
                let dst = system32.appendingPathComponent(dll)
                try fm.createDirectory(at: system32, withIntermediateDirectories: true)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
                copiedAny = true
            }
            if copiedAny {
                Log.debug("installed \(kind.rawValue) DLLs from \(rel)")
                return
            }
        }

        // Last resort: glob for the DLLs anywhere in the engine tree.
        if let found = try findFirstMatching(under: engineRoot, names: Set(requiredDLLs)), !found.isEmpty {
            try fm.createDirectory(at: system32, withIntermediateDirectories: true)
            for src in found {
                let dst = system32.appendingPathComponent(src.lastPathComponent)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
            }
            Log.debug("installed \(kind.rawValue) DLLs via engine-wide search")
            return
        }

        Log.warn("""
            Could not locate \(kind.rawValue) DLLs in engine \
            \(engineRoot.lastPathComponent). Wine will use its builtin fallback. \
            Re-bundle with a different --graphics driver if the app requires \
            DirectX translation.
            """)
    }

    private func findFirstMatching(under root: URL, names: Set<String>) throws -> [URL]? {
        var results: [String: URL] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            let name = url.lastPathComponent.lowercased()
            if names.contains(where: { $0.lowercased() == name }),
               results[name] == nil {
                results[name] = url
            }
            if results.count == names.count { break }
        }
        return results.isEmpty ? nil : Array(results.values)
    }

    private func extraEnv(for kind: GraphicsDriverKind) -> [String: String] {
        switch kind {
        case .d3dmetal: return ["MTL_HUD_ENABLED": "0"]
        case .dxmt:     return [:]
        case .dxvk:     return ["DXVK_HUD": "0"]
        }
    }
}
