import Foundation

/// Fixes: "Daemon does not restart kernel when killed" (issue: the generated
/// launchd plist ran `mihomo start`, which spawns the kernel in the
/// background and exits 0 — `KeepAlive.SuccessfulExit: false` then only
/// re-runs `start` if *that* command itself fails, never when the kernel it
/// already detached from later dies. launchd was supervising the wrong
/// process.)
///
/// This type is the process launchd should actually keep alive instead: a
/// long-running loop that polls the currently tracked kernel PID and
/// relaunches it on unexpected exit. `DaemonService.generatePlist` points
/// `ProgramArguments` at `daemon _supervise` (this loop) rather than `start`,
/// so `KeepAlive` now applies to something that keeps running for as long as
/// supervision should last, and whose *own* unexpected exit is the only
/// thing that should make launchd restart it.
///
/// Deliberately does not reimplement kernel spawning — it reuses
/// `LifecycleService.start(version:)`, the exact path `mihomo start` and
/// `kernel use` already exercise, so config generation, credential
/// rotation, and the post-launch liveness check all stay on one tested code
/// path instead of a second, divergent one.
///
/// Distinguishing "the kernel exited because `mihomo stop` was run" from "it
/// crashed" uses `DaemonState.lastStopWasUserInitiated` — which
/// `LifecycleService.performStop()`/`performStart()` already set and clear.
/// That flag's doc comment already described this exact use case; this loop
/// is simply the piece that was never written to read it.
final class DaemonSupervisor {
    private let runningKernel: () async throws -> RunningKernelState?
    private let daemonState: () async throws -> DaemonState
    private let updateDaemonState: ((inout DaemonState) -> Void) async throws -> Void
    private let isProcessRunning: (Int32) -> Bool
    private let startKernel: (String?) async throws -> Void
    private let logger: AppLogger
    private let pollIntervalSeconds: UInt64
    private let sleepFn: (UInt64) async -> Void

    init(
        runningKernel: @escaping () async throws -> RunningKernelState? = { try await MetadataStore.shared.runningKernel() },
        daemonState: @escaping () async throws -> DaemonState = { try await MetadataStore.shared.daemonState() },
        updateDaemonState: @escaping ((inout DaemonState) -> Void) async throws -> Void = { try await MetadataStore.shared.updateDaemonState($0) },
        isProcessRunning: @escaping (Int32) -> Bool = { pid in
            // Mirrors LifecycleService's own check: EPERM means the process
            // exists but is root-owned (elevated Tun-mode kernel) — still
            // alive, just not signalable by us. Only ESRCH means "gone."
            guard pid > 0 else { return false }
            if kill(pid, 0) == 0 { return true }
            return errno == EPERM
        },
        startKernel: @escaping (String?) async throws -> Void = { version in
            try await LifecycleService().start(version: version)
        },
        logger: AppLogger = AppLogger.shared,
        pollIntervalSeconds: UInt64 = 2,
        sleepFn: @escaping (UInt64) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        }
    ) {
        self.runningKernel = runningKernel
        self.daemonState = daemonState
        self.updateDaemonState = updateDaemonState
        self.isProcessRunning = isProcessRunning
        self.startKernel = startKernel
        self.logger = logger
        self.pollIntervalSeconds = pollIntervalSeconds
        self.sleepFn = sleepFn
    }

    /// Runs until the process itself is terminated (launchd `bootout` during
    /// `daemon remove` sends the default SIGTERM, which just ends the
    /// process — deliberately no custom handler: the kernel it was watching
    /// is intentionally left running, matching `DaemonService.remove`'s own
    /// "daemon removed, kernel is still running" message; AdvisoryLock's
    /// flock is released automatically on process exit regardless).
    func run() async {
        logger.info("daemon: supervisor started (pid \(ProcessInfo.processInfo.processIdentifier))")
        while true {
            await tick()
            await sleepFn(pollIntervalSeconds)
        }
    }

    /// One poll iteration, exposed (not private) so tests can drive it
    /// directly instead of racing a real sleep loop.
    func tick() async {
        do {
            guard let running = try await runningKernel() else {
                // Nothing tracked as running yet (e.g. daemon installed
                // before the first `kernel use`/`start`) — nothing to
                // supervise this tick.
                return
            }

            if isProcessRunning(running.pid) {
                return // healthy
            }

            let state = try await daemonState()
            if state.lastStopWasUserInitiated {
                // `mihomo stop` set this before signaling the process.
                // Respect it — stay idle until the user runs `start` or
                // `kernel use` again, rather than immediately undoing
                // their own stop.
                return
            }

            logger.info("daemon: kernel v\(running.version) (pid \(running.pid)) exited unexpectedly — restarting")
            do {
                try await startKernel(running.version)
                try await updateDaemonState { s in
                    s.restartCount += 1
                    s.lastRestartAt = Date()
                    s.lastRestartReason = "kernel exited unexpectedly (was pid \(running.pid))"
                }
                logger.recordAudit(action: "daemon.restart", target: running.version, result: "success")
            } catch {
                logger.error("daemon: restart of v\(running.version) failed: \(error.localizedDescription)")
                logger.recordAudit(action: "daemon.restart", target: running.version, result: "failure: \(error.localizedDescription)")
                // Leave it for the next tick rather than tight-looping on a
                // persistent failure (e.g. binary removed from disk).
            }
        } catch {
            logger.error("daemon: supervisor tick failed: \(error.localizedDescription)")
        }
    }
}
