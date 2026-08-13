import ArgumentParser
import Foundation

/// `mihomo start` — manual lifecycle control, independent of daemon supervision.
struct StartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start the active kernel.")

    @Option(help: "Run this specific version once, without changing which kernel is marked active.")
    var version: String?

    func run() async throws {
        // TODO: refuse if already running ("use 'mihomo restart' instead").
        // Same integrity recheck + liveness check as `kernel use` (§4.1.3).
        throw stub("start")
    }
}

/// `mihomo stop` — graceful shutdown, marked user-initiated so the daemon
/// (if installed) does not treat this as a crash requiring auto-restart.
/// This distinction is what makes design doc §4.1.2 actually work correctly.
struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop the running kernel.")

    func run() async throws {
        // TODO: SIGTERM, wait, SIGKILL after timeout. Set a "user-initiated"
        // flag/file the daemon checks before deciding to auto-restart.
        throw stub("stop")
    }
}

/// `mihomo restart` — stop + start, atomic from the user's perspective.
struct RestartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart", abstract: "Restart the running kernel.")

    func run() async throws {
        // TODO: single lock hold across both steps; on liveness failure,
        // attempt to bring the previous configuration back up rather than
        // leaving the kernel stopped.
        throw stub("restart")
    }
}

private func stub(_ command: String) -> CLIError {
    CLIError(what: "not implemented", cause: "'\(command)' is a scaffold stub", exitCode: .permissionDenied)
}
