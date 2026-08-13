import ArgumentParser
import Foundation

/// `mihomo mode ...` — see mihomo_mode_command_spec.md for full behavior.
/// Switches are applied as a runtime overlay via KernelClient.patchConfigs,
/// never by editing the subscription file (design doc §2.4).
struct ModeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mode",
        abstract: "Switch traffic rule mode (rule / global / direct).",
        subcommands: [Status.self, Rule.self, Global.self, Direct.self]
    )

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status", abstract: "Show effective mode vs. subscription default.")

        @Flag(help: "Emit machine-readable JSON instead of formatted text.")
        var json = false

        func run() async throws {
            // TODO: KernelClient.getConfigs().mode vs. active subscription's
            // embedded default; flag "CLI override in effect" on mismatch (§2.4).
            throw stub("mode status")
        }
    }

    struct Rule: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rule", abstract: "Route per the active subscription's rule list (default).")

        func run() async throws {
            throw stub("mode rule") // TODO: guard no-kernel-running -> CLIError.noKernelRunning
        }
    }

    struct Global: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "global", abstract: "Force all traffic through the proxy tunnel.")

        @Flag(help: "Auto-confirm the behavior-change warning.")
        var yes = false

        func run() async throws {
            // TODO: confirmation prompt unless --yes (LAN/captive-portal warning).
            throw stub("mode global")
        }
    }

    struct Direct: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "direct", abstract: "Forward all traffic locally, bypassing the kernel.")

        @Flag(help: "Auto-confirm the behavior-change warning.")
        var yes = false

        func run() async throws {
            throw stub("mode direct")
        }
    }
}

private func stub(_ command: String) -> CLIError {
    CLIError(what: "not implemented", cause: "'\(command)' is a scaffold stub", exitCode: .permissionDenied)
}
