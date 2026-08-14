import XCTest
@testable import mihomo_cli

final class LifecycleServiceTests: XCTestCase {

    private var tempDir: URL!
    private var dummyBinary: URL!
    /// A real AppLogger, but pointed at this test's own temp directory —
    /// never the real ~/.mihomo-cli/logs. Every LifecycleService below
    /// must inject this explicitly; the class's default `logger:` param is
    /// AppLogger.shared, the real singleton. Confirmed as a genuine bug on
    /// real hardware: without this, every `swift test` run permanently
    /// appends these tests' fixture data (fake PIDs, fake versions) into
    /// the user's actual log file.
    private var testLogger: AppLogger!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dummyBinary = tempDir.appendingPathComponent("mihomo")
        try? "binary-content".data(using: .utf8)?.write(to: dummyBinary)
        testLogger = AppLogger(logsDirectory: tempDir.appendingPathComponent("logs"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testStart_alreadyRunning_throwsExit2() async throws {
        let running = RunningKernelState(version: "1.19.10", pid: 4000, startedAt: Date(), controlPort: 9090, mixedPort: 7890, configPath: "", stdoutPath: "", stderrPath: "")
        let service = LifecycleService(
            runningKernel: { running },
            logger: testLogger
        )

        do {
            try await service.start(version: nil)
            XCTFail("Expected permissionDenied exit 2 when already running")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .permissionDenied)
            XCTAssertTrue(err.what.contains("already running"))
        }
    }

    func testStart_noActiveKernel_throwsExit3() async throws {
        let service = LifecycleService(
            runningKernel: { nil },
            activeKernel: { nil },
            logger: testLogger
        )

        do {
            try await service.start(version: nil)
            XCTFail("Expected notFound exit 3 when no active kernel")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .notFound)
        }
    }

    func testStart_missingBinary_throwsExit8() async throws {
        let record = KernelRecord(version: "1.19.10", binaryPath: "/nonexistent/path/mihomo", addedAt: Date(), isActive: true)
        let service = LifecycleService(
            runningKernel: { nil },
            activeKernel: { record },
            logger: testLogger
        )

        do {
            try await service.start(version: nil)
            XCTFail("Expected sourceVerificationFailure exit 8 when binary missing")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .sourceVerificationFailure)
        }
    }

    func testStart_success() async throws {
        let record = KernelRecord(version: "1.19.10", binaryPath: dummyBinary.path, addedAt: Date(), isActive: true)
        var savedRunning: RunningKernelState? = nil
        var startObserved = false
        var printed: [String] = []

        let service = LifecycleService(
            runningKernel: { savedRunning },
            setRunningKernel: { savedRunning = $0 },
            activeKernel: { record },
            markKernelStartObserved: { startObserved = true },
            regenerateCredentials: { port in ControlAPICredentials(port: port, secret: "test-secret") },
            clientFactory: { _ in FakeLifecycleKernelClient(result: .healthy) },
            configWriter: FakeLifecycleConfigWriter(),
            processSpawner: { _, _, _, _, _ in 5555 },
            logger: testLogger,
            printLine: { printed.append($0) }
        )

        try await service.start(version: nil)

        XCTAssertNotNil(savedRunning)
        XCTAssertEqual(savedRunning?.pid, 5555)
        XCTAssertEqual(savedRunning?.version, "1.19.10")
        XCTAssertFalse(savedRunning?.elevated ?? true, "plain 'start' must never launch elevated")
        XCTAssertEqual(savedRunning?.configPath, "/tmp/fake-config-1.19.10.yaml", "regression guard: 'start' must actually write and use a real runtime config, not a path nothing ever wrote to")
        XCTAssertTrue(startObserved)
        XCTAssertTrue(printed.contains(where: { $0.contains("Started mihomo v1.19.10 (pid 5555)") }))
    }

    func testStop_notRunning_throwsExit2() async throws {
        let service = LifecycleService(
            runningKernel: { nil },
            logger: testLogger
        )

        do {
            try await service.stop()
            XCTFail("Expected permissionDenied exit 2 when not running")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .permissionDenied)
            XCTAssertTrue(err.what.contains("not running"))
        }
    }

    func testStop_running_marksExpectedAndSignals() async throws {
        var running: RunningKernelState? = RunningKernelState(version: "1.19.10", pid: 4102, startedAt: Date(), controlPort: 9090, mixedPort: 7890, configPath: "", stdoutPath: "", stderrPath: "")
        var stopExpected = false
        var signaledSignals: [Int32] = []
        var printed: [String] = []

        let service = LifecycleService(
            runningKernel: { running },
            setRunningKernel: { running = $0 },
            markKernelStopExpected: { stopExpected = true },
            processKiller: { pid, sig, elevated in
                signaledSignals.append(sig)
                return 0
            },
            isProcessRunning: { _ in false }, // simulate immediate graceful termination after SIGTERM
            logger: testLogger,
            printLine: { printed.append($0) }
        )

        try await service.stop()

        XCTAssertTrue(stopExpected)
        XCTAssertNil(running)
        XCTAssertTrue(signaledSignals.contains(SIGTERM))
        XCTAssertTrue(printed.contains(where: { $0.contains("Stopped mihomo (pid 4102)") }))
    }

    func testStop_elevatedKernel_signalsViaSudo() async throws {
        var running: RunningKernelState? = RunningKernelState(version: "1.19.10", pid: 4200, startedAt: Date(), controlPort: 9090, mixedPort: 7890, configPath: "", stdoutPath: "", stderrPath: "", elevated: true)
        var elevatedFlags: [Bool] = []

        let service = LifecycleService(
            runningKernel: { running },
            setRunningKernel: { running = $0 },
            markKernelStopExpected: {},
            processKiller: { _, _, elevated in
                elevatedFlags.append(elevated)
                return 0
            },
            isProcessRunning: { _ in false },
            logger: testLogger
        )

        try await service.stop()

        XCTAssertEqual(elevatedFlags, [true], "stopping an elevated kernel must signal it via sudo, not a plain kill()")
    }

    func testSetTunElevation_noRunningKernel_throws() async throws {
        let service = LifecycleService(
            runningKernel: { nil },
            logger: testLogger
        )

        do {
            try await service.setTunElevation(true)
            XCTFail("Expected an error when no kernel is running to elevate")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .permissionDenied)
        }
    }

    func testSetTunElevation_alreadyInRequestedState_isNoOp() async throws {
        let running = RunningKernelState(version: "1.19.10", pid: 4300, startedAt: Date(), controlPort: 9090, mixedPort: 7890, configPath: "", stdoutPath: "", stderrPath: "", elevated: true)
        var spawnCount = 0

        let service = LifecycleService(
            runningKernel: { running },
            processSpawner: { _, _, _, _, _ in
                spawnCount += 1
                return 9999
            },
            logger: testLogger
        )

        try await service.setTunElevation(true)

        XCTAssertEqual(spawnCount, 0, "must not relaunch when already in the requested elevation state")
    }

    func testSetTunElevation_relaunchesElevatedAndPreservesVersion() async throws {
        var running: RunningKernelState? = RunningKernelState(version: "1.19.10", pid: 4400, startedAt: Date(), controlPort: 9090, mixedPort: 7890, configPath: "", stdoutPath: "", stderrPath: "", elevated: false)
        let record = KernelRecord(version: "1.19.10", binaryPath: dummyBinary.path, addedAt: Date(), isActive: true)
        var acquireCalled = false
        var spawnedElevated: [Bool] = []

        let service = LifecycleService(
            runningKernel: { running },
            setRunningKernel: { running = $0 },
            activeKernel: { record },
            kernelByVersion: { _ in record },
            markKernelStopExpected: {},
            markKernelStartObserved: {},
            controlAPICredentials: { ControlAPICredentials(port: 9090, secret: "s3cr3t") },
            regenerateCredentials: { port in ControlAPICredentials(port: port, secret: "s3cr3t-2") },
            clientFactory: { _ in FakeLifecycleKernelClient(result: .healthy) },
            configWriter: FakeLifecycleConfigWriter(),
            processSpawner: { _, _, _, _, elevated in
                spawnedElevated.append(elevated)
                return 4401
            },
            processKiller: { _, _, _ in 0 },
            isProcessRunning: { _ in false },
            tunPrivilege: FakeLifecycleTunPrivilege(onAcquire: { acquireCalled = true }),
            logger: testLogger
        )

        try await service.setTunElevation(true)

        XCTAssertTrue(acquireCalled, "must warm the sudo timestamp cache before an elevated relaunch")
        XCTAssertEqual(spawnedElevated, [true])
        XCTAssertEqual(running?.pid, 4401)
        XCTAssertEqual(running?.elevated, true)
        XCTAssertEqual(running?.version, "1.19.10", "must preserve the running kernel's version across an elevation change")
    }
}

private final class FakeLifecycleTunPrivilege: TunPrivilegeManaging {
    let onAcquire: () -> Void
    init(onAcquire: @escaping () -> Void) { self.onAcquire = onAcquire }
    func hasEntitlement() -> Bool { false }
    func acquireEntitlement() throws { onAcquire() }
}

/// In-memory stand-in for RuntimeConfigWriter — critically, does NOT touch
/// the real filesystem or ~/.mihomo-cli/runtime, so `start`/`restart`/
/// `setTunElevation` tests stay isolated from the real environment now
/// that performStart actually calls a config writer (previously it never
/// did, which was itself the bug being fixed here).
private final class FakeLifecycleConfigWriter: RuntimeConfigWriting {
    func write(
        version: String,
        credentials: ControlAPICredentials,
        mixedPort: Int,
        subscriptionYAML: String?,
        modeOverride: String?
    ) throws -> RuntimeConfig {
        RuntimeConfig(
            configURL: URL(fileURLWithPath: "/tmp/fake-config-\(version).yaml"),
            workDirectory: URL(fileURLWithPath: "/tmp")
        )
    }
}

private final class FakeLifecycleKernelClient: KernelClient {
    let result: LivenessResult

    init(result: LivenessResult) {
        self.result = result
    }

    func version() async throws -> VersionInfo {
        VersionInfo(version: "1.19.10", meta: true)
    }

    func getConfigs() async throws -> Configs {
        Configs(mode: "rule", mixedPort: 7890)
    }

    func patchConfigs(_ patch: ConfigsPatch) async throws {}
    func getProxies() async throws -> ProxyGroups { ProxyGroups(groups: [:]) }
    func selectProxy(group: String, node: String) async throws {}
    func getConnections() async throws -> ConnectionsSnapshot { ConnectionsSnapshot(downloadTotal: 0, uploadTotal: 0, connections: []) }
    func closeConnections() async throws {}

    func livenessCheck(expectedVersion: String?, expectedConfigPatch: ConfigsPatch?) async throws -> LivenessResult {
        result
    }
}
