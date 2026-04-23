import Foundation

// Entry point. Dispatches to either the CLI or the GUI based on argv +
// whether stdin is attached to a terminal. Real GUI integration arrives in
// Phase 4 via SplashWindow + DropZoneWindow.
@main
struct CiderApp {
    static func main() {
        CLIRouter.run()
    }
}
