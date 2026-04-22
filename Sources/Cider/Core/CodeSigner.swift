import Foundation

enum CodeSigner {
    static func sign(bundle: URL, identity: BundleConfig.SignIdentity) throws {
        Log.info("signing bundle (\(identitySummary(identity)))")
        try Shell.run("/usr/bin/codesign", [
            "--force",
            "--deep",
            "--sign", identity.codesignArgument,
            bundle.path
        ], captureOutput: true)
    }

    static func verify(bundle: URL) throws {
        try Shell.run("/usr/bin/codesign", [
            "--verify",
            "--verbose=2",
            bundle.path
        ], captureOutput: true)
    }

    private static func identitySummary(_ identity: BundleConfig.SignIdentity) -> String {
        switch identity {
        case .adHoc: return "ad-hoc"
        case .developerID(let id): return id
        }
    }
}
