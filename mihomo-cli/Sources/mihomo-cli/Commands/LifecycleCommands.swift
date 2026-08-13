import ArgumentParser
import Foundation

/// `mihomo start` — manual lifecycle control, independent of daemon supervision.
struct StartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start the active kernel.")

    @Option(help: "Run this specific version once, without changing which kernel is marked active.")
    var version: String?

    func run() async throws {
        try await LifecycleService().start(version: version)
    }
}

/// `mihomo stop` — graceful shutdown, marked user-initiated so the daemon
/// (if installed) does not treat this as a crash requiring auto-restart.
/// This distinction is what makes design doc §4.1.2 actually work correctly.
struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop the running kernel.")

    func run() async throws {
        try await LifecycleService().stop()
    }
}

/// `mihomo restart` — stop + start, atomic from the user's perspective.
struct RestartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart", abstract: "Restart the running kernel.")

    func run() async throws {
        try await LifecycleService().restart()
    }
}
