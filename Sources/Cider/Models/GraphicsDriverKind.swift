import ArgumentParser
import Foundation

enum GraphicsDriverKind: String, CaseIterable, ExpressibleByArgument, Codable {
    case dxmt
    case d3dmetal
    case dxvk

    static var defaultForThisMachine: GraphicsDriverKind {
        #if arch(arm64)
        return .d3dmetal
        #else
        return .dxvk
        #endif
    }

    var dllOverrides: String {
        switch self {
        case .dxmt, .d3dmetal:
            return "d3d11,dxgi,d3d10core,d3d12=n,b"
        case .dxvk:
            return "d3d9,d3d10core,d3d11,dxgi=n,b"
        }
    }
}
