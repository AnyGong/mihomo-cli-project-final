import Foundation

struct KernelUseResult: Equatable {
    enum Outcome: Equatable {
        case alreadyActive
        case switched
    }

    let outcome: Outcome
    let version: String
}

private struct KernelLaunchContext {
    let state: RunningKernelState
    let credentials: ControlAPICredentials
}

final class KernelUseService {
    private let kernel: (String) async throws -> KernelRecord?
    private let activeKernel: () async throws -> KernelRecord?
    private let runningKernel: () async throws -> RunningKernelState?
    private let setActiveKernel: (String) async throws -> Void
    private let setRunningKernel: (RunningKernelState?) async throws -> Void
    private let regenerateCredentials: (Int) async throws -> ControlAPICredentials
    private let markStopExpected: () async throws -> Void
    private let markStartObserved: () async throws -> Void
    private let configWriter: RuntimeConfigWriting
    private let processController: KernelProcessControlling
    private let portChecker: PortChecking
    private let clientFactory: (ControlAPICredentials) -> KernelClient
    private let now: () -> Date
    private let controlPort: Int
    private let mixedPort: Int
    private let logDirectory: URL
    private let livenessTimeout: TimeInterval

    init(
        kernel: @escaping (String) async throws -> KernelRecord? = { try MetadataStore.shared.kernel(version: $0) },
        activeKernel: @escaping () async throws -> KernelRecord? = { try MetadataStore.shared.activeKernel() },
        runningKernel: @escaping () async throws -> RunningKernelState? = { try MetadataStore.shared.runningKernel() },
        setActiveKernel: @escaping (String) async throws -> Void = { try MetadataStore.shared.setActiveKernel(version: $0) },
        setRunningKernel: @escaping (RunningKernelState?) async throws -> Void = { try MetadataStore.shared.setRunningKernel($0) },
        regenerateCredentials: @escaping (Int) async throws -> ControlAPICredentials = { try MetadataStore.shared.regenerateControlAPICredentials(port: $0) },
        markStopExpected: @escaping () async throws -> Void = { try MetadataStore.shared.markKernelStopExpected() },
        markStartObserved: @escaping () async throws -> Void = { try MetadataStore.shared.markKernelStartObserved() },
        configWriter: RuntimeConfigWriting = RuntimeConfigWriter(),
        processController: KernelProcessControlling = ProcessController(),
        portChecker: PortChecking = LoopbackPortChecker(),
        clientFactory: @escaping (ControlAPICredentials) -> KernelClient = { HTTPKernelClient(port: $0.port, secret: $0.secret) },
        now: @escaping () -> Date = Date.init,
        controlPort: Int = 9090,
        mixedPort: Int = 7890,
        logDirectory: URL = URL(fileURLWithPath: "\(NSHomeDirectory())/.mihomo-cli/logs"),
        livenessTimeout: TimeInterval = 5
    ) {
        self.kernel = kernel
        self.activeKernel = activeKernel
        self.runningKernel = runningKernel
        self.setActiveKernel = setActiveKernel
        self.setRunningKernel = setRunningKernel
        self.regenerateCredentials = regenerateCredentials
        self.markStopExpected = markStopExpected
        self.markStartObserved = markStartObserved
        self.configWriter = configWriter
        self.processController = processController
        self.portChecker = portChecker
        self.clientFactory = clientFactory
        self.now = now
        self.controlPort = controlPort
        self.mixedPort = mixedPort
        self.logDirectory = logDirectory
        self.livenessTimeout = livenessTimeout
    }

    func use(version: String) async throws -> KernelUseResult {
        if try await activeKernel()?.version == version {
            return KernelUseResult(outcome: .alreadyActive, version: version)
        }

        return try await AdvisoryLock().withLock {
            if try await activeKernel()?.version == version {
                return KernelUseResult(outcome: .alreadyActive, version: version)
            }

            guard let target = try await kernel(version) else {
                throw CLIError(
                    what: "kernel not found",
                    cause: "no installed kernel matches '\(version)'",
                    fix: "run 'mihomo kernel fetch \(version)' first",
                    exitCode: .notFound
                )
            }
            try verifyBinaryPresent(target)

            let previousActive = try await activeKernel()
            let previousRunning = try await runningKernel()
            var launchedContext: KernelLaunchContext?

            do {
                let context = try await launch(record: target, replacing: previousRunning)
                launchedContext = context
                let liveness = try await waitForLiveness(
                    client: clientFactory(context.credentials),
                    expectedVersion: version
                )
                try handle(liveness: liveness, stage: "liveness check", version: version)
                try await setActiveKernel(version)
                try await setRunningKernel(context.state)
                try await markStartObserved()
                return KernelUseResult(outcome: .switched, version: version)
            } catch {
                if let launchedContext, processController.isRunning(pid: launchedContext.state.pid) {
                    try? await markStopExpected()
                    try? await processController.stop(pid: launchedContext.state.pid, timeout: 5)
                }
                try await attemptRollback(previousActive: previousActive, previousRunning: previousRunning, originalError: error)
                throw error
            }
        }
    }

    private func launch(record: KernelRecord, replacing previousRunning: RunningKernelState?) async throws -> KernelLaunchContext {
        let selectedControlPort = try await preparePortsAndStopPrevious(previousRunning)
        let credentials = try await regenerateCredentials(selectedControlPort)
        let runtimeConfig = try configWriter.write(version: record.version, credentials: credentials, mixedPort: mixedPort)
        let stdoutURL = logDirectory.appendingPathComponent("kernel-\(record.version)-stdout.log")
        let stderrURL = logDirectory.appendingPathComponent("kernel-\(record.version)-stderr.log")
        let launched = try processController.start(KernelLaunchRequest(
            binaryPath: record.binaryPath,
            configURL: runtimeConfig.configURL,
            workDirectory: runtimeConfig.workDirectory,
            stdoutURL: stdoutURL,
            stderrURL: stderrURL
        ))

        let state = RunningKernelState(
            version: record.version,
            pid: launched.pid,
            startedAt: now(),
            controlPort: credentials.port,
            mixedPort: mixedPort,
            configPath: runtimeConfig.configURL.path,
            stdoutPath: stdoutURL.path,
            stderrPath: stderrURL.path
        )
        return KernelLaunchContext(state: state, credentials: credentials)
    }

    private func preparePortsAndStopPrevious(_ previousRunning: RunningKernelState?) async throws -> Int {
        if let previousRunning, processController.isRunning(pid: previousRunning.pid) {
            try await markStopExpected()
            try await processController.stop(pid: previousRunning.pid, timeout: 5)
            guard await portChecker.waitUntilAvailable(previousRunning.controlPort, timeout: 3) else {
                throw CLIError(
                    what: "kernel switch aborted at 'port release'",
                    cause: "old kernel did not release control port \(previousRunning.controlPort) in time",
                    fix: "run 'mihomo stop' and retry, or inspect the process using the port",
                    exitCode: .portUnavailable
                )
            }
            guard await portChecker.waitUntilAvailable(previousRunning.mixedPort, timeout: 3) else {
                throw CLIError(
                    what: "kernel switch aborted at 'port release'",
                    cause: "old kernel did not release mixed-port \(previousRunning.mixedPort) in time",
                    fix: "run 'mihomo stop' and retry, or inspect the process using the port",
                    exitCode: .portUnavailable
                )
            }
            return previousRunning.controlPort
        }

        return firstAvailablePort(startingAt: controlPort)
    }

    private func firstAvailablePort(startingAt port: Int) -> Int {
        var candidate = port
        while !portChecker.isPortAvailable(candidate) {
            candidate += 1
        }
        return candidate
    }

    private func attemptRollback(
        previousActive: KernelRecord?,
        previousRunning: RunningKernelState?,
        originalError: Error
    ) async throws {
        guard let previousActive else {
            try await setRunningKernel(nil)
            throw rollbackFailed(originalError: originalError, rollbackCause: "no previous active kernel was available")
        }

        do {
            try verifyBinaryPresent(previousActive)
            let restored = try await launch(record: previousActive, replacing: nil)
            let liveness = try await waitForLiveness(
                client: clientFactory(restored.credentials),
                expectedVersion: previousActive.version
            )
            try handle(liveness: liveness, stage: "rollback liveness check", version: previousActive.version)
            try await setRunningKernel(restored.state)
            try await markStartObserved()
        } catch {
            try await setRunningKernel(nil)
            throw rollbackFailed(originalError: originalError, rollbackCause: error.localizedDescription)
        }
    }

    private func rollbackFailed(originalError: Error, rollbackCause: String) -> CLIError {
        CLIError(
            what: "kernel switch failed and automatic rollback also failed",
            cause: "\(describe(originalError)); rollback failed because \(rollbackCause)",
            fix: "no kernel is currently running; run 'mihomo kernel use <version>' after resolving the error",
            exitCode: .sourceVerificationFailure
        )
    }

    private func waitForLiveness(client: KernelClient, expectedVersion: String) async throws -> LivenessResult {
        let deadline = Date().addingTimeInterval(livenessTimeout)
        var lastResult = try await client.livenessCheck(expectedVersion: expectedVersion, expectedConfigPatch: nil)
        while Date() < deadline {
            switch lastResult {
            case .healthy, .versionMismatch, .configMismatch:
                return lastResult
            case .unresponsive:
                try? await Task.sleep(nanoseconds: 100_000_000)
                lastResult = try await client.livenessCheck(expectedVersion: expectedVersion, expectedConfigPatch: nil)
            }
        }
        return lastResult
    }

    private func verifyBinaryPresent(_ record: KernelRecord) throws {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: record.binaryPath),
              let size = attrs[.size] as? NSNumber,
              size.intValue > 0 else {
            throw CLIError(
                what: "cannot use '\(record.version)'",
                cause: "kernel binary is missing or zero-length at \(record.binaryPath)",
                fix: "run 'mihomo kernel fetch \(record.version)' again",
                exitCode: .sourceVerificationFailure
            )
        }
    }

    private func handle(liveness: LivenessResult, stage: String, version: String) throws {
        switch liveness {
        case .healthy:
            return
        case .unresponsive(let reason):
            throw CLIError(
                what: "kernel switch aborted at '\(stage)'",
                cause: reason,
                fix: "run 'mihomo log --level error' for the kernel's stderr output",
                exitCode: .permissionDenied
            )
        case .versionMismatch(let expected, let actual):
            throw CLIError(
                what: "kernel switch aborted at '\(stage)'",
                cause: "expected \(expected), but control API reported \(actual)",
                fix: "run 'mihomo log --level error' for the kernel's stderr output",
                exitCode: .permissionDenied
            )
        case .configMismatch(let field, let expected, let actual):
            throw CLIError(
                what: "kernel switch aborted at '\(stage)'",
                cause: "\(field) expected \(expected), actual \(actual) while starting \(version)",
                fix: "run 'mihomo log --level error' for the kernel's stderr output",
                exitCode: .permissionDenied
            )
        }
    }

    private func describe(_ error: Error) -> String {
        if let cliError = error as? CLIError {
            return cliError.description
        }
        return error.localizedDescription
    }
}
