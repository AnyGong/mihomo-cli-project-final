import XCTest
@testable import mihomo_cli

final class LifecycleServiceTests: XCTestCase {

    private var tempDir: URL!
    private var dummyBinary: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dummyBinary = tempDir.appendingPathComponent("mihomo")
        try? "binary-content".data(using: .utf8)?.write(to: dummyBinary)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testStart_alreadyRunning_throwsExit2() async throws {
        let running = RunningKernelState(version: "1.19.10", pid: 4000, startedAt: Date(), controlPort: 9090, mixedPort: 7890, configPath: "", stdoutPath: "", stderrPath: "")
        let service = LifecycleService(
            runningKernel: { running }
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
            activeKernel: { nil }
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
            activeKernel: { record }
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
            clientFactory: { _ in FakeLifecycleKernelClient(result: .healthy) },
            processSpawner: { _, _, _, _ in 5555 },
            printLine: { printed.append($0) }
        )

        try await service.start(version: nil)

        XCTAssertNotNil(savedRunning)
        XCTAssertEqual(savedRunning?.pid, 5555)
        XCTAssertEqual(savedRunning?.version, "1.19.10")
        XCTAssertTrue(startObserved)
        XCTAssertTrue(printed.contains(where: { $0.contains("Started mihomo v1.19.10 (pid 5555)") }))
    }

    func testStop_notRunning_throwsExit2() async throws {
        let service = LifecycleService(
            runningKernel: { nil }
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
            processKiller: { pid, sig in
                signaledSignals.append(sig)
                return sig == 0 ? -1 : 0 // return non-zero on sig 0 so it considers process dead
            },
            printLine: { printed.append($0) }
        )

        try await service.stop()

        XCTAssertTrue(stopExpected)
        XCTAssertNil(running)
        XCTAssertTrue(signaledSignals.contains(SIGTERM))
        XCTAssertTrue(printed.contains(where: { $0.contains("Stopped mihomo (pid 4102)") }))
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
