import Foundation

enum Log {
    nonisolated(unsafe) static var verbose: Bool = false

    static func info(_ message: @autoclosure () -> String) {
        FileHandle.standardError.write(Data("• \(message())\n".utf8))
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        FileHandle.standardError.write(Data("  \(message())\n".utf8))
    }

    static func warn(_ message: @autoclosure () -> String) {
        FileHandle.standardError.write(Data("! \(message())\n".utf8))
    }

    static func error(_ message: @autoclosure () -> String) {
        FileHandle.standardError.write(Data("✗ \(message())\n".utf8))
    }
}
