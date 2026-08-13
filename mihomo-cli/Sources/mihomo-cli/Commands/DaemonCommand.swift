import ArgumentParser
import Foundation

/// `mihomo daemon ...` — see mihomo_daemon_lifecycle_diagnostics_spec.md.
/// Manages the per-user launchd agent that provides auto-restart and
/// persistence beyond terminal closure (design doc §2.3, §4.1.2).
struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Manage the launchd supervision agent.",
        subcommands: [Install.self, Remove.self, Status.self]
    )

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "install")

        @Flag(help: "Skip confirmation.")
        var yes = false

        func run() async throws {
            try await DaemonService().install(yes: yes)
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "remove")

        @Flag(help: "Skip confirmation.")
        var yes = false

        func run() async throws {
            try await DaemonService().remove(yes: yes)
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status")

        @Flag(help: "Emit machine-readable JSON instead of formatted text.")
        var json = false

        func run() async throws {
            try await DaemonService().status(json: json)
        }
    }
}
