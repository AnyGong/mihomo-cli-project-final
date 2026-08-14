import Foundation

final class LifecycleService {

    private let runningKernel: () async throws -> RunningKernelState?
    private let setRunningKernel: (RunningKernelState?) async throws -> Void
    private let activeKernel: () async throws -> KernelRecord?
    private let kernelByVersion: (String) async throws -> KernelRecord?
    private let markKernelStopExpected: () async throws -> Void
    private let markKernelStartObserved: () async throws -> Void
    private let controlAPICredentials: () async throws -> ControlAPICredentials?
    private let clientFactory: (ControlAPICredentials) -> KernelClient
    private let processSpawner: (_ binaryPath: String, _ configPath: String, _ stdoutPath: String, _ stderrPath: String, _ elevated: Bool) throws -> Int32
    /// Delivers a signal to `pid`. When `elevated` is true (i.e. the target
    /// process was launched via `sudo` for Tun mode), the signal must also
    /// go through `sudo` — an unprivileged `kill(2)` against a root-owned
    /// process fails with EPERM. Returns the underlying exit/return code;
    /// callers use `isProcessRunning`, not this return value, to check
    /// liveness (see its doc comment for why).
    private let processKiller: (_ pid: Int32, _ signal: Int32, _ elevated: Bool) -> Int32
    /// True if `pid` is still alive. Deliberately separate from
    /// `processKiller(pid, 0, _)`'s return code: `kill(pid, 0)` returns
    /// nonzero both when the process doesn't exist (ESRCH) *and* when it
    /// exists but this process lacks permission to signal it (EPERM) — the
    /// latter is exactly the elevated-kernel case, and conflating the two
    /// would make `stop()`'s wait loop believe a still-running root-owned
    /// kernel had already exited. Mirrors the check `ProcessController`
    /// already uses for the `kernel use` launch path.
    private let isProcessRunning: (_ pid: Int32) -> Bool
    private let tunPrivilege: TunPrivilegeManaging
    private let logger: AppLogger
    private let printLine: (String) -> Void
    private let now: () -> Date

    init(
        runningKernel: @escaping () async throws -> RunningKernelState? = { try await MetadataStore.shared.runningKernel() },
        setRunningKernel: @escaping (RunningKernelState?) async throws -> Void = { try await MetadataStore.shared.setRunningKernel($0) },
        activeKernel: @escaping () async throws -> KernelRecord? = { try await MetadataStore.shared.activeKernel() },
        kernelByVersion: @escaping (String) async throws -> KernelRecord? = { try await MetadataStore.shared.kernel(version: $0) },
        markKernelStopExpected: @escaping () async throws -> Void = { try await MetadataStore.shared.markKernelStopExpected() },
        markKernelStartObserved: @escaping () async throws -> Void = { try await MetadataStore.shared.markKernelStartObserved() },
        controlAPICredentials: @escaping () async throws -> ControlAPICredentials? = { try await MetadataStore.shared.controlAPICredentials() },
        clientFactory: @escaping (ControlAPICredentials) -> KernelClient = { HTTPKernelClient(port: $0.port, secret: $0.secret) },
        processSpawner: @escaping (_ binaryPath: String, _ configPath: String, _ stdoutPath: String, _ stderrPath: String, _ elevated: Bool) throws -> Int32 = { binaryPath, configPath, stdoutPath, stderrPath, elevated in
            let process = Process()
            if elevated {
                // Entitlement is primed (interactive `sudo -v`) by the
                // caller (NetService.tunOn) before this closure ever runs —
                // `-n` here means "use the cached ticket, never prompt",
                // since stdout/stderr are about to be redirected to log
                // files and couldn't show a password prompt anyway.
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                process.arguments = ["-n", binaryPath, "-f", configPath]
            } else {
                process.executableURL = URL(fileURLWithPath: binaryPath)
                process.arguments = ["-f", configPath]
            }

            FileManager.default.createFile(atPath: stdoutPath, contents: nil)
            FileManager.default.createFile(atPath: stderrPath, contents: nil)

            if let out = FileHandle(forWritingAtPath: stdoutPath),
               let err = FileHandle(forWritingAtPath: stderrPath) {
                process.standardOutput = out
                process.standardError = err
            }

            try process.run()
            return process.processIdentifier
        },
        processKiller: @escaping (_ pid: Int32, _ signal: Int32, _ elevated: Bool) -> Int32 = { pid, signal, elevated in
            guard elevated else {
                return kill(pid, signal)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", "/bin/kill", "-\(signal)", "\(pid)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            } catch {
                return -1
            }
        },
        isProcessRunning: @escaping (_ pid: Int32) -> Bool = { pid in
            guard pid > 0 else { return false }
            return kill(pid, 0) == 0 || errno == EPERM
        },
        tunPrivilege: TunPrivilegeManaging = TunPrivilege(),
        logger: AppLogger = AppLogger.shared,
        printLine: @escaping (String) -> Void = { print($0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.runningKernel = runningKernel
        self.setRunningKernel = setRunningKernel
        self.activeKernel = activeKernel
        self.kernelByVersion = kernelByVersion
        self.markKernelStopExpected = markKernelStopExpected
        self.markKernelStartObserved = markKernelStartObserved
        self.controlAPICredentials = controlAPICredentials
        self.clientFactory = clientFactory
        self.processSpawner = processSpawner
        self.processKiller = processKiller
        self.isProcessRunning = isProcessRunning
        self.tunPrivilege = tunPrivilege
        self.logger = logger
        self.printLine = printLine
        self.now = now
    }

    // MARK: - Start

    func start(version requestedVersion: String?) async throws {
        return try await AdvisoryLock().withLock {
            try await performStart(version: requestedVersion, elevated: false)
        }
    }

    private func performStart(version requestedVersion: String?, elevated: Bool) async throws {
        if let current = try await runningKernel() {
            throw CLIError(
                what: "kernel already running",
                cause: "kernel already running (pid \(current.pid)) — use 'mihomo restart' to restart it, or 'mihomo stop' first",
                fix: "run 'mihomo restart' or 'mihomo stop'",
                exitCode: .permissionDenied
            )
        }

        let targetKernel: KernelRecord
        if let v = requestedVersion {
            guard let record = try await kernelByVersion(v) else {
                throw CLIError(
                    what: "kernel version not found",
                    cause: "version '\(v)' is not installed",
                    fix: "run 'mihomo kernel fetch \(v)' or 'mihomo kernel list'",
                    exitCode: .notFound
                )
            }
            targetKernel = record
        } else {
            guard let active = try await activeKernel() else {
                throw CLIError(
                    what: "no active kernel",
                    cause: "no kernel is currently marked active",
                    fix: "run 'mihomo kernel use <version>' first",
                    exitCode: .notFound
                )
            }
            targetKernel = active
        }

        // Validate binary presence and non-zero length (§4.1.3)
        guard FileManager.default.fileExists(atPath: targetKernel.binaryPath) else {
            throw CLIError(
                what: "kernel binary missing",
                cause: "binary not found on disk at \(targetKernel.binaryPath)",
                fix: "run 'mihomo kernel fetch \(targetKernel.version)' to reinstall",
                exitCode: .sourceVerificationFailure
            )
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: targetKernel.binaryPath),
           let size = attrs[.size] as? Int64, size == 0 {
            throw CLIError(
                what: "kernel binary corrupted",
                cause: "binary at \(targetKernel.binaryPath) is zero bytes",
                fix: "run 'mihomo kernel fetch \(targetKernel.version)' to reinstall",
                exitCode: .sourceVerificationFailure
            )
        }

        let runDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mihomo-cli/run")
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let configPath = runDir.appendingPathComponent("config.yaml").path
        let stdoutPath = runDir.appendingPathComponent("mihomo.stdout.log").path
        let stderrPath = runDir.appendingPathComponent("mihomo.stderr.log").path

        let pid = try processSpawner(targetKernel.binaryPath, configPath, stdoutPath, stderrPath, elevated)

        let creds = try await controlAPICredentials() ?? ControlAPICredentials(port: 9090, secret: "")
        let client = clientFactory(creds)

        let liveness = try await client.livenessCheck(expectedVersion: targetKernel.version, expectedConfigPatch: nil)
        switch liveness {
        case .healthy:
            break
        case .unresponsive(let reason):
            _ = processKiller(pid, SIGKILL, elevated)
            throw CLIError(
                what: "kernel startup failed",
                cause: "kernel started (pid \(pid)) but did not respond on control API: \(reason)",
                fix: "check configuration or run logs with 'mihomo log'",
                exitCode: .permissionDenied
            )
        case .versionMismatch(let expected, let actual):
            _ = processKiller(pid, SIGKILL, elevated)
            throw CLIError(
                what: "kernel version mismatch",
                cause: "expected version '\(expected)', got '\(actual)'",
                exitCode: .permissionDenied
            )
        case .configMismatch(let field, let expected, let actual):
            _ = processKiller(pid, SIGKILL, elevated)
            throw CLIError(
                what: "kernel configuration mismatch",
                cause: "field '\(field)' expected '\(expected)', got '\(actual)'",
                exitCode: .permissionDenied
            )
        }

        let state = RunningKernelState(
            version: targetKernel.version,
            pid: pid,
            startedAt: now(),
            controlPort: creds.port,
            mixedPort: 7890,
            configPath: configPath,
            stdoutPath: stdoutPath,
            stderrPath: stderrPath,
            elevated: elevated
        )

        try await setRunningKernel(state)
        try await markKernelStartObserved()

        logger.info("kernel: started v\(targetKernel.version) (pid \(pid))\(elevated ? " [elevated, Tun mode]" : "")")
        logger.recordAudit(action: "kernel.start", target: targetKernel.version, result: "success")

        printLine("✅ Started mihomo v\(targetKernel.version) (pid \(pid))\(elevated ? " with elevated privileges for Tun mode." : ".")")
    }

    // MARK: - Stop

    func stop() async throws {
        return try await AdvisoryLock().withLock {
            try await performStop()
        }
    }

    private func performStop() async throws {
        guard let current = try await runningKernel() else {
            throw CLIError(
                what: "kernel not running",
                cause: "no active kernel process is currently running",
                exitCode: .permissionDenied
            )
        }

        try await markKernelStopExpected()

        _ = processKiller(current.pid, SIGTERM, current.elevated)

        // Wait up to 2 seconds for graceful shutdown
        var terminated = false
        for _ in 0..<20 {
            if !isProcessRunning(current.pid) {
                terminated = true
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if !terminated {
            _ = processKiller(current.pid, SIGKILL, current.elevated)
        }

        try await setRunningKernel(nil)

        logger.info("kernel: stopped (pid \(current.pid))")
        logger.recordAudit(action: "kernel.stop", target: current.version, result: "success")

        printLine("✅ Stopped mihomo (pid \(current.pid)).")
    }

    // MARK: - Restart

    func restart() async throws {
        return try await AdvisoryLock().withLock {
            let previous = try await runningKernel()
            if let p = previous {
                try await performStop()
                do {
                    // Preserve elevation across restart — a crash-restart
                    // (or manual `mihomo restart`) while Tun mode is active
                    // must not silently drop back to an unprivileged
                    // process, which would leave Tun mode "on" in the
                    // metadata store while doing nothing on the wire.
                    try await performStart(version: p.version, elevated: p.elevated)
                } catch {
                    logger.error("kernel: restart failed to bring up v\(p.version): \(error.localizedDescription)")
                    throw error
                }
            } else {
                try await performStart(version: nil, elevated: false)
            }
        }
    }

    // MARK: - Tun elevation

    /// Ensures the currently running kernel is launched with (or without)
    /// `sudo` elevation, relaunching it if its current state doesn't match.
    /// This is the mechanism `net tun on`/`net tun off` uses to satisfy the
    /// privilege requirement confirmed by the hardware spike
    /// (docs/mihomo_tun_privilege_spike_guide.md) — Tun mode does not work
    /// by flipping a flag; it requires the kernel process itself to be
    /// re-launched as root.
    ///
    /// No-op if the kernel is already running with the requested elevation.
    /// Throws if no kernel is running at all — Tun mode has nothing to
    /// elevate without an active kernel process.
    func setTunElevation(_ elevated: Bool) async throws {
        return try await AdvisoryLock().withLock {
            guard let current = try await runningKernel() else {
                throw CLIError(
                    what: elevated ? "cannot enable Tun mode" : "cannot disable Tun mode",
                    cause: "no kernel is currently running",
                    fix: "run 'mihomo kernel use <version>' or 'mihomo start' first",
                    exitCode: .permissionDenied
                )
            }

            guard current.elevated != elevated else {
                return // already in the requested state
            }

            if elevated {
                try tunPrivilege.acquireEntitlement()
            }

            try await performStop()
            do {
                try await performStart(version: current.version, elevated: elevated)
            } catch {
                logger.error("kernel: Tun elevation change failed to bring v\(current.version) back up: \(error.localizedDescription)")
                throw error
            }
        }
    }
}
