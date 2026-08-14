import ArgumentParser
import Foundation

/// `mihomo daemon ...` — see mihomo_daemon_lifecycle_diagnostics_spec.md.
/// Manages the per-user launchd agent that provides auto-restart and
/// persistence beyond terminal closure (design doc §2.3, §4.1.2).
struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Manage the launchd supervision agent.",
        subcommands: [Install.self, Remove.self, Status.self, Supervise.self]
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

    /// Internal — this is what the generated launchd plist actually
    /// launches now (see `DaemonService.generatePlist`), not something a
    /// person runs directly. `shouldDisplay: false` keeps it out of
    /// `mihomo daemon --help`. Runs `DaemonSupervisor.run()`, which loops
    /// forever polling and relaunching the kernel — this is the fix for
    /// "daemon does not restart kernel when killed": launchd's `KeepAlive`
    /// now watches this long-running process instead of the one-shot
    /// `mihomo start`, which always exited 0 after merely spawning the
    /// kernel and detaching from it.
    struct Supervise: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "_supervise", shouldDisplay: false)

        func run() async throws {
            await DaemonSupervisor().run()
        }
    }
}
