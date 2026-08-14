import Foundation
import XCTest
@testable import mihomo_cli

final class KernelUseServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mihomo-use-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testAlreadyActiveFastPathDoesNotStartProcess() async throws {
        let process = FakeProcessController()
        let target = try makeKernel(version: "v1")
        let service = makeService(activeResponses: [target], process: process)

        let result = try await service.use(version: "v1")

        XCTAssertEqual(result, KernelUseResult(outcome: .alreadyActive, version: "v1"))
        XCTAssertTrue(process.starts.isEmpty)
    }

    func testPostLockAlreadyActiveCheckWinsAfterStateChanges() async throws {
        let process = FakeProcessController()
        let target = try makeKernel(version: "v1")
        let service = makeService(activeResponses: [nil, target], process: process)

        let result = try await service.use(version: "v1")

        XCTAssertEqual(result, KernelUseResult(outcome: .alreadyActive, version: "v1"))
        XCTAssertTrue(process.starts.isEmpty)
    }

    func testSuccessfulSwitchUsesSameFreshCredentialsForConfigAndClient() async throws {
        let process = FakeProcessController()
        let writer = FakeConfigWriter(configURL: tempDir.appendingPathComponent("config.yaml"), workDirectory: tempDir)
        let target = try makeKernel(version: "v2")
        let clients = ClientSpyBox()
        let marker = MarkerBox()
        let service = makeService(
            target: target,
            activeResponses: [nil, nil],
            writer: writer,
            process: process,
            markStartObserved: { marker.count += 1 },
            clientFactory: { creds in
                clients.credentials.append(creds)
                return FakeKernelClient(result: .healthy)
            }
        )

        let result = try await service.use(version: "v2")

        XCTAssertEqual(result, KernelUseResult(outcome: .switched, version: "v2"))
        XCTAssertEqual(writer.credentials?.secret, "secret-9090")
        XCTAssertEqual(clients.credentials.first?.secret, "secret-9090")
        XCTAssertEqual(process.starts.count, 1)
        XCTAssertEqual(marker.count, 1)
    }

    func testLaunchLoadsActiveSubscriptionContentIntoRuntimeConfig() async throws {
        // Regression test: `launch()` previously never called
        // `activeSubscriptionContent` at all, so the runtime config was
        // always written with `subscriptionYAML: nil` regardless of what
        // subscription was active — silently dropping proxy-providers,
        // proxy-groups, and rules from the real subscription file.
        let process = FakeProcessController()
        let writer = FakeConfigWriter(configURL: tempDir.appendingPathComponent("config.yaml"), workDirectory: tempDir)
        let target = try makeKernel(version: "v2")
        let subscriptionYAML = "proxy-providers:\n  p1:\n    type: http\n    url: https://example.com\n"

        let service = makeService(
            target: target,
            activeResponses: [nil, nil],
            writer: writer,
            process: process,
            activeSubscriptionContent: { subscriptionYAML },
            clientFactory: { _ in FakeKernelClient(result: .healthy) }
        )

        _ = try await service.use(version: "v2")

        XCTAssertEqual(writer.subscriptionYAMLCalls, [subscriptionYAML])
    }

    func testLaunchWithNoActiveSubscriptionPassesNil() async throws {
        let process = FakeProcessController()
        let writer = FakeConfigWriter(configURL: tempDir.appendingPathComponent("config.yaml"), workDirectory: tempDir)
        let target = try makeKernel(version: "v2")

        let service = makeService(
            target: target,
            activeResponses: [nil, nil],
            writer: writer,
            process: process,
            activeSubscriptionContent: { nil },
            clientFactory: { _ in FakeKernelClient(result: .healthy) }
        )

        _ = try await service.use(version: "v2")

        XCTAssertEqual(writer.subscriptionYAMLCalls, [nil])
    }

    func testPreviousRunningKernelIsMarkedExpectedStoppedAndPortsWaitedBeforeStart() async throws {
        let process = FakeProcessController(runningPIDs: [11])
        let ports = FakePortChecker()
        let marker = MarkerBox()
        let previousRunning = RunningKernelState(
            version: "v1",
            pid: 11,
            startedAt: Date(timeIntervalSince1970: 0),
            controlPort: 9090,
            mixedPort: 7890,
            configPath: "/tmp/config.yaml",
            stdoutPath: "/tmp/stdout.log",
            stderrPath: "/tmp/stderr.log"
        )
        let target = try makeKernel(version: "v2")
        let service = makeService(
            target: target,
            activeResponses: [nil, nil],
            running: previousRunning,
            process: process,
            ports: ports,
            markStopExpected: { marker.count += 1 },
            clientFactory: { _ in FakeKernelClient(result: .healthy) }
        )

        _ = try await service.use(version: "v2")

        XCTAssertEqual(marker.count, 1)
        XCTAssertEqual(process.stoppedPIDs, [11])
        XCTAssertEqual(ports.waitedPorts, [9090, 7890])
        XCTAssertEqual(process.starts.count, 1)
    }

    func testMissingBinaryFailsBeforeStartingProcess() async throws {
        let process = FakeProcessController()
        let target = KernelRecord(version: "v2", binaryPath: tempDir.appendingPathComponent("missing").path, addedAt: Date(), lastUsedAt: nil, isActive: false)
        let service = makeService(target: target, activeResponses: [nil, nil], process: process)

        do {
            _ = try await service.use(version: "v2")
            XCTFail("expected missing binary failure")
        } catch let error as CLIError {
            XCTAssertEqual(error.exitCode, .sourceVerificationFailure)
        }

        XCTAssertTrue(process.starts.isEmpty)
    }

    func testRollbackFailureHasDistinctMessageAndDoesNotClaimSuccess() async throws {
        let process = FakeProcessController(runningPIDs: [101])
        let target = try makeKernel(version: "v2")
        let previous = try makeKernel(version: "v1")
        let clients = ClientSpyBox()
        let service = makeService(
            target: target,
            activeResponses: [nil, nil, previous],
            running: nil,
            process: process,
            clientFactory: { creds in
                clients.credentials.append(creds)
                return clients.credentials.count == 1
                    ? FakeKernelClient(result: .versionMismatch(expected: "v2", actual: "wrong"))
                    : FakeKernelClient(result: .unresponsive("rollback dead"))
            }
        )

        do {
            _ = try await service.use(version: "v2")
            XCTFail("expected rollback failure")
        } catch let error as CLIError {
            XCTAssertEqual(error.what, "kernel switch failed and automatic rollback also failed")
            XCTAssertFalse(error.description.contains("Rolled back to"))
        }
    }

    private func makeService(
        target: KernelRecord? = nil,
        activeResponses: [KernelRecord?],
        running: RunningKernelState? = nil,
        writer: RuntimeConfigWriting? = nil,
        process: FakeProcessController = FakeProcessController(),
        ports: FakePortChecker = FakePortChecker(),
        markStopExpected: @escaping () async throws -> Void = {},
        markStartObserved: @escaping () async throws -> Void = {},
        activeSubscriptionContent: @escaping () async throws -> String? = { nil },
        clientFactory: @escaping (ControlAPICredentials) -> KernelClient = { _ in FakeKernelClient(result: .healthy) }
    ) -> KernelUseService {
        let active = ActiveKernelBox(activeResponses)
        let runningBox = RunningKernelBox(running)
        return KernelUseService(
            kernel: { version in
                target?.version == version ? target : nil
            },
            activeKernel: {
                active.next()
            },
            runningKernel: {
                runningBox.state
            },
            setActiveKernel: { version in
                active.setVersion = version
            },
            setRunningKernel: { state in
                runningBox.state = state
            },
            regenerateCredentials: { port in
                ControlAPICredentials(port: port, secret: "secret-\(port)")
            },
            markStopExpected: markStopExpected,
            markStartObserved: markStartObserved,
            activeSubscriptionContent: activeSubscriptionContent,
            configWriter: writer ?? FakeConfigWriter(configURL: tempDir.appendingPathComponent("config.yaml"), workDirectory: tempDir),
            processController: process,
            portChecker: ports,
            clientFactory: clientFactory,
            now: { Date(timeIntervalSince1970: 1) },
            logDirectory: tempDir,
            livenessTimeout: 0.01
        )
    }

    private func makeKernel(version: String) throws -> KernelRecord {
        let url = tempDir.appendingPathComponent("mihomo-\(version)")
        try "binary".data(using: .utf8)!.write(to: url)
        return KernelRecord(version: version, binaryPath: url.path, addedAt: Date(), lastUsedAt: nil, isActive: false)
    }
}

private final class ActiveKernelBox {
    private var responses: [KernelRecord?]
    var setVersion: String?

    init(_ responses: [KernelRecord?]) {
        self.responses = responses
    }

    func next() -> KernelRecord? {
        responses.isEmpty ? responses.last ?? nil : responses.removeFirst()
    }
}

private final class RunningKernelBox {
    var state: RunningKernelState?

    init(_ state: RunningKernelState?) {
        self.state = state
    }
}

private final class MarkerBox {
    var count = 0
}

private final class ClientSpyBox {
    var credentials: [ControlAPICredentials] = []
}

private final class FakeConfigWriter: RuntimeConfigWriting {
    let configURL: URL
    let workDirectory: URL
    private(set) var credentials: ControlAPICredentials?
    /// Every `subscriptionYAML` this writer was called with, in order —
    /// regression guard for the bug where `launch()` never loaded the
    /// active subscription at all and always passed `nil`.
    private(set) var subscriptionYAMLCalls: [String?] = []

    init(configURL: URL, workDirectory: URL) {
        self.configURL = configURL
        self.workDirectory = workDirectory
    }

    func write(
        version: String,
        credentials: ControlAPICredentials,
        mixedPort: Int,
        subscriptionYAML: String? = nil,
        modeOverride: String? = nil
    ) throws -> RuntimeConfig {
        self.credentials = credentials
        subscriptionYAMLCalls.append(subscriptionYAML)
        return RuntimeConfig(configURL: configURL, workDirectory: workDirectory)
    }
}

private final class FakeProcessController: KernelProcessControlling {
    private var runningPIDs: Set<Int32>
    private var nextPID: Int32 = 100
    private(set) var starts: [KernelLaunchRequest] = []
    private(set) var stoppedPIDs: [Int32] = []

    init(runningPIDs: Set<Int32> = []) {
        self.runningPIDs = runningPIDs
    }

    func start(_ request: KernelLaunchRequest) throws -> KernelLaunchResult {
        starts.append(request)
        nextPID += 1
        runningPIDs.insert(nextPID)
        return KernelLaunchResult(pid: nextPID)
    }

    func stop(pid: Int32, timeout: TimeInterval) async throws {
        stoppedPIDs.append(pid)
        runningPIDs.remove(pid)
    }

    func isRunning(pid: Int32) -> Bool {
        runningPIDs.contains(pid)
    }
}

private final class FakePortChecker: PortChecking {
    var waitedPorts: [Int] = []
    var availablePorts: Set<Int> = [9090, 7890]

    func isPortAvailable(_ port: Int) -> Bool {
        availablePorts.contains(port)
    }

    func waitUntilAvailable(_ port: Int, timeout: TimeInterval) async -> Bool {
        waitedPorts.append(port)
        return availablePorts.contains(port)
    }
}

private final class FakeKernelClient: KernelClient {
    let result: LivenessResult

    init(result: LivenessResult) {
        self.result = result
    }

    func version() async throws -> VersionInfo {
        VersionInfo(version: "v-test", meta: true)
    }

    func getConfigs() async throws -> Configs {
        Configs(mode: "rule", mixedPort: 7890)
    }

    func patchConfigs(_ patch: ConfigsPatch) async throws {}

    func getProxies() async throws -> ProxyGroups {
        ProxyGroups(groups: [:])
    }

    func selectProxy(group: String, node: String) async throws {}

    func getConnections() async throws -> ConnectionsSnapshot {
        ConnectionsSnapshot(downloadTotal: 0, uploadTotal: 0, connections: [])
    }

    func closeConnections() async throws {}

    func livenessCheck(expectedVersion: String?, expectedConfigPatch: ConfigsPatch?) async throws -> LivenessResult {
        result
    }
}
