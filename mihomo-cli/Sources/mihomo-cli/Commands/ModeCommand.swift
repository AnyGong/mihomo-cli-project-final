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
            try await ModeService().status(json: json)
        }
    }

    struct Rule: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rule", abstract: "Route per the active subscription's rule list (default).")

        func run() async throws {
            try await ModeService().switchMode(to: "rule", yes: true)
        }
    }

    struct Global: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "global", abstract: "Force all traffic through the proxy tunnel.")

        @Flag(help: "Auto-confirm the behavior-change warning.")
        var yes = false

        func run() async throws {
            try await ModeService().switchMode(to: "global", yes: yes)
        }
    }

    struct Direct: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "direct", abstract: "Forward all traffic locally, bypassing the kernel.")

        @Flag(help: "Auto-confirm the behavior-change warning.")
        var yes = false

        func run() async throws {
            try await ModeService().switchMode(to: "direct", yes: yes)
        }
    }
}
