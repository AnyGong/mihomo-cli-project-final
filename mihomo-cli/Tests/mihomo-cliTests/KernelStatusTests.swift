import XCTest
@testable import mihomo_cli

final class KernelStatusTests: XCTestCase {

    // MARK: - Helpers

    private func fakeRunning(version: String = "v1.19.29", pid: Int32 = 1234) -> RunningKernelState {
        RunningKernelState(
            version: version,
            pid: pid,
            startedAt: Date().addingTimeInterval(-7260), // ~2h 1m ago
            controlPort: 9090,
            mixedPort: 7890,
            configPath: "/tmp/config.yaml",
            stdoutPath: "/tmp/stdout.log",
            stderrPath: "/tmp/stderr.log"
        )
    }

    private func fakeCredentials(port: Int = 9090) -> ControlAPICredentials {
        ControlAPICredentials(port: port, secret: "test-secret")
    }

    // MARK: - No running kernel

    func testNoRunningKernel_humanOutput() async throws {
        let service = KernelStatusService(
            activeKernel: { nil },
            runningKernel: { nil },
            daemonState: { DaemonState() },
            controlAPICredentials: { nil },
            clientFactory: { _ in fatalError("should not be called") },
            isProcessRunning: { _ in false }
        )

        let report = try await service.report()
        let output = KernelStatusService.humanOutput(from: report)

        XCTAssert(output.contains("not running"), "Expected 'not running' when no kernel is running")
        XCTAssert(output.contains("mihomo start"), "Expected suggestion to start a kernel")
    }

    func testNoRunningKernel_jsonOutput() async throws {
        let service = KernelStatusService(
            activeKernel: { nil },
            runningKernel: { nil },
            daemonState: { DaemonState() },
            controlAPICredentials: { nil },
            clientFactory: { _ in fatalError("should not be called") },
            isProcessRunning: { _ in false }
        )

        let report = try await service.report()
        let json = try KernelStatusService.jsonOutput(from: report)

        XCTAssert(json.contains("\"status\""), "JSON should contain status field")
        XCTAssert(json.contains("not_running"), "JSON status should be not_running")
    }

    // MARK: - Running kernel, API responsive

    func testRunningKernel_apiResponsive_humanOutput() async throws {
        let running = fakeRunning()
        let creds = fakeCredentials()
        let mockClient = MockKernelClient()
        mockClient.versionToReturn = VersionInfo(version: running.version, meta: true)

        let service = KernelStatusService(
            activeKernel: { KernelRecord(version: running.version, binaryPath: "/fake", addedAt: Date(), lastUsedAt: nil, isActive: true) },
            runningKernel: { running },
            daemonState: { DaemonState(installed: true) },
            controlAPICredentials: { creds },
            clientFactory: { _ in mockClient },
            isProcessRunning: { _ in true }
        )

        let report = try await service.report()
        let output = KernelStatusService.humanOutput(from: report)

        XCTAssert(output.contains("running"), "Should show 'running'")
        XCTAssert(output.contains(running.version), "Should show kernel version")
        XCTAssert(output.contains("responsive"), "Should show API as responsive")
        XCTAssert(output.contains("127.0.0.1:9090"), "Should show control API address")
        XCTAssert(output.contains("yes"), "Should show supervised: yes")
    }

    func testRunningKernel_apiResponsive_showsUptime() async throws {
        let running = fakeRunning()
        let mockClient = MockKernelClient()
        mockClient.versionToReturn = VersionInfo(version: running.version, meta: true)

        let service = KernelStatusService(
            runningKernel: { running },
            daemonState: { DaemonState() },
            controlAPICredentials: { self.fakeCredentials() },
            clientFactory: { _ in mockClient },
            isProcessRunning: { _ in true }
        )

        let report = try await service.report()
        let output = KernelStatusService.humanOutput(from: report)

        // Started ~2h 1m ago, so uptime should contain "2h"
        XCTAssert(output.contains("2h"), "Uptime should show approximately 2 hours")
    }

    // MARK: - Running kernel, API unresponsive

    func testRunningKernel_apiUnresponsive_humanOutput() async throws {
        let running = fakeRunning()
        let mockClient = MockKernelClient()
        mockClient.versionError = CLIError(
            what: "unreachable",
            cause: "connection refused",
            exitCode: .networkError
        )

        let service = KernelStatusService(
            runningKernel: { running },
            daemonState: { DaemonState() },
            controlAPICredentials: { self.fakeCredentials() },
            clientFactory: { _ in mockClient },
            isProcessRunning: { _ in true }
        )

        let report = try await service.report()
        let output = KernelStatusService.humanOutput(from: report)

        XCTAssert(output.contains("unreachable") || output.contains("unresponsive") || output.contains("not responding"),
                  "Should indicate API is unreachable; got: \(output)")
    }

    // MARK: - JSON output shape

    func testRunningKernel_jsonOutputShape() async throws {
        let running = fakeRunning()
        let mockClient = MockKernelClient()
        mockClient.versionToReturn = VersionInfo(version: running.version, meta: true)

        let service = KernelStatusService(
            runningKernel: { running },
            daemonState: { DaemonState(installed: false) },
            controlAPICredentials: { self.fakeCredentials() },
            clientFactory: { _ in mockClient },
            isProcessRunning: { _ in true }
        )

        let report = try await service.report()
        let json = try KernelStatusService.jsonOutput(from: report)

        XCTAssert(json.contains("\"status\""))
        XCTAssert(json.contains("\"version\""))
        XCTAssert(json.contains("\"pid\""))
        XCTAssert(json.contains("\"supervised\""))
        XCTAssert(json.contains("running"))
    }
}

// MARK: - MockKernelClient (minimal stub sufficient for these tests)

private final class MockKernelClient: KernelClient {
    var versionToReturn: VersionInfo?
    var versionError: Error?

    func version() async throws -> VersionInfo {
        if let err = versionError { throw err }
        return versionToReturn!
    }

    func getConfigs() async throws -> Configs { Configs(mode: "rule", mixedPort: 7890) }
    func patchConfigs(_ patch: ConfigsPatch) async throws {}
    func getProxies() async throws -> ProxyGroups { ProxyGroups(groups: [:]) }
    func selectProxy(group: String, node: String) async throws {}
    func getConnections() async throws -> ConnectionsSnapshot { ConnectionsSnapshot(downloadTotal: 0, uploadTotal: 0, connections: []) }
    func closeConnections() async throws {}

    func livenessCheck(expectedVersion: String?, expectedConfigPatch: ConfigsPatch?) async throws -> LivenessResult {
        .healthy
    }
}

// MARK: - DaemonState convenience init for tests

private extension DaemonState {
    init(installed: Bool) {
        self.init()
        self.installed = installed
    }
}
