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
        let minLevel: LogLevel?
        if let l = level {
            guard let parsed = LogLevel(rawValue: l.lowercased()) else {
                throw CLIError(
                    what: "invalid log level",
                    cause: "unknown log level '\(l)'",
                    fix: "valid levels: info, warning, error",
                    exitCode: .validationFailure
                )
            }
            minLevel = parsed
        } else {
            minLevel = nil
        }

        let lines = try AppLogger.shared.queryLogs(minLevel: minLevel, json: json)
        for line in lines {
            print(line)
        }
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
        let lines = try AppLogger.shared.queryAudit(since: since, actionFilter: action, json: json)
        for line in lines {
            print(line)
        }
    }
}

/// `mihomo doctor` — dry-run of every pre-flight check from §4.1.3, no side effects.
struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Run all pre-flight checks without applying changes.")

    @Flag(help: "Emit machine-readable JSON instead of formatted text.")
    var json = false

    func run() async throws {
        try await DoctorService().run(json: json)
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
        try await UninstallService().uninstall(purgeData: purgeData, yes: yes)
    }
}
