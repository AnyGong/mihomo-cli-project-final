import ArgumentParser
import Foundation

/// `mihomo log` — tail leveled logs (design doc §4.1.5).
struct LogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "log", abstract: "View or tail leveled logs.")

    @Option(help: "Minimum level to show: info | warning | error.")
    var level: String?

    @Flag(help: "Follow the log (like tail -f).")
    var follow = false

    @Flag(help: "Emit newline-delimited JSON (NDJSON) instead of formatted text.")
    var json = false

    func run() async throws {
        // TODO: read across rotated files transparently (§4.1.6 retention policy)
        // when the requested range spans a rotation boundary.
        throw stub("log")
    }
}

/// `mihomo audit` — query the immutable audit trail (design doc §4.1.5).
struct AuditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "audit", abstract: "Query the audit trail.")

    @Option(help: "Filter to entries since this date (YYYY-MM-DD) or relative form (7d, 24h).")
    var since: String?

    @Option(help: "Filter to a specific action type (e.g. kernel.use, sub.switch).")
    var action: String?

    @Flag(help: "Emit machine-readable JSON instead of formatted text.")
    var json = false

    func run() async throws {
        throw stub("audit") // TODO: read-only query, never mutates the trail
    }
}

/// `mihomo doctor` — dry-run of every pre-flight check from §4.1.3, no side effects.
struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Run all pre-flight checks without applying changes.")

    @Flag(help: "Emit machine-readable JSON instead of formatted text.")
    var json = false

    func run() async throws {
        // TODO: kernel integrity, subscription validity, port availability,
        // system-proxy consistency, Tun entitlement, daemon health, disk/log
        // headroom. Never exits non-zero for warnings alone — only if a check
        // can't run at all (e.g. kernel binary missing/zero-length on disk -> .sourceVerificationFailure).
        throw stub("doctor")
    }
}

/// `mihomo uninstall` — full teardown (design doc §2.5), fixed safe order,
/// each step reports independently so partial cleanup beats none.
struct UninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Remove all system-level state installed by this tool.")

    @Flag(help: "Also remove downloaded kernels, subscriptions, and logs.")
    var purgeData = false

    @Flag(help: "Skip the confirmation prompt.")
    var yes = false

    func run() async throws {
        // TODO order: stop kernel (user-initiated) -> remove launchd agent ->
        // revert system proxy -> tear down Tun interface -> (if --purge-data)
        // remove downloaded binaries/subscriptions/logs. Continue past
        // individual step failures; report each with its own status line.
        throw stub("uninstall")
    }
}

private func stub(_ command: String) -> CLIError {
    CLIError(what: "not implemented", cause: "'\(command)' is a scaffold stub", exitCode: .permissionDenied)
}
