import Foundation

public enum Log {
    nonisolated(unsafe) public static var verbose: Bool = false

    public static func info(_ message: @autoclosure () -> String) {
        FileHandle.standardError.write(Data("• \(message())\n".utf8))
    }

    public static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        FileHandle.standardError.write(Data("  \(message())\n".utf8))
    }

    public static func warn(_ message: @autoclosure () -> String) {
        FileHandle.standardError.write(Data("! \(message())\n".utf8))
    }

    public static func error(_ message: @autoclosure () -> String) {
        FileHandle.standardError.write(Data("✗ \(message())\n".utf8))
    }
}
