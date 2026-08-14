import AppKit
import Foundation

/// Runs as an accessory app (`.accessory` activation policy): no Dock icon,
/// no app menu bar of its own, just the persistent NSStatusItem. Set at
/// runtime rather than via an Info.plist `LSUIElement` key, deliberately —
/// this stays a bare SwiftPM executable with no `.app` bundle, matching
/// AI.md §3 convention #10 (no packaging/signing/versioning machinery for a
/// single-machine personal tool).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let bridge = CLIBridge()
        let loginAgent = LoginItemAgent()
        statusItemController = StatusItemController(bridge: bridge, loginAgent: loginAgent)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
