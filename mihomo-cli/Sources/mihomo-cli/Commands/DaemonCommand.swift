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
            // TODO: write ~/Library/LaunchAgents/com.mihomo-cli.agent.plist,
            // `launchctl bootstrap`. Idempotent — report "already installed"
            // rather than erroring if it exists.
            throw stub("daemon install")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "remove")

        @Flag(help: "Skip confirmation.")
        var yes = false

        func run() async throws {
            // TODO: `launchctl bootout` + delete plist. Does NOT stop a running
            // kernel — only removes supervision. Message must make this explicit.
            throw stub("daemon remove")
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status")

        @Flag(help: "Emit machine-readable JSON instead of formatted text.")
        var json = false

        func run() async throws {
            // TODO: installed?, agent running state, restart count + last reason.
            throw stub("daemon status")
        }
    }
}

private func stub(_ command: String) -> CLIError {
    CLIError(what: "not implemented", cause: "'\(command)' is a scaffold stub", exitCode: .permissionDenied)
}
