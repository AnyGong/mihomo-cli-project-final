import Foundation

/// Finds the `mihomo-cli` executable this app should drive. Resolution order:
/// 1. `MIHOMO_CLI_PATH` env var, if set (explicit override, e.g. for
///    development builds run from `.build/debug`).
/// 2. A `mihomo-cli` binary sitting next to this app's own executable —
///    true whenever both targets were built by the same `swift build`
///    invocation, which is the expected day-to-day setup for this
///    single-machine personal tool (see AI.md §3 convention #10).
/// 3. `/usr/local/bin/mihomo-cli`, the conventional install location if the
///    binary was ever copied there manually.
enum CLILocator {
    static func resolve(fileManager: FileManager = .default) -> String? {
        if let override = ProcessInfo.processInfo.environment["MIHOMO_CLI_PATH"],
           fileManager.isExecutableFile(atPath: override) {
            return override
        }

        let ownExecutableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let sibling = ownExecutableURL.deletingLastPathComponent().appendingPathComponent("mihomo-cli").path
        if fileManager.isExecutableFile(atPath: sibling) {
            return sibling
        }

        let fallback = "/usr/local/bin/mihomo-cli"
        if fileManager.isExecutableFile(atPath: fallback) {
            return fallback
        }

        return nil
    }
}
