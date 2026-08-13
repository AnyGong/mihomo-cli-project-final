import XCTest
@testable import mihomo_cli

final class ModeServiceTests: XCTestCase {

    private func fakeRunning(pid: Int32 = 1234) -> RunningKernelState {
        RunningKernelState(
            version: "v1.19.29",
            pid: pid,
            startedAt: Date(),
            controlPort: 9090,
            mixedPort: 7890,
            configPath: "/tmp/config.yaml",
            stdoutPath: "/tmp/stdout.log",
            stderrPath: "/tmp/stderr.log"
        )
    }

    private func fakeCreds() -> ControlAPICredentials {
        ControlAPICredentials(port: 9090, secret: "test-secret")
    }

    private func fakeSubscription(name: String, embeddedMode: String = "rule") -> (SubscriptionRecord, String) {
        let rec = SubscriptionRecord(
            name: name,
            source: .local(path: "/tmp/\(name).yaml"),
            addedAt: Date(),
            updatedAt: Date(),
            isActive: true
        )
        let yaml = """
        mode: \(embeddedMode)
        proxies:
          - name: "Node-1"
            type: ss
            server: 1.1.1.1
            port: 8388
        proxy-groups:
          - name: "PROXY"
            type: select
            proxies:
              - "Node-1"
        rules:
          - MATCH,PROXY
        """
        return (rec, yaml)
    }

    // MARK: - Status Tests

    func testStatus_noRunningKernel() async throws {
        var printed: [String] = []

        let service = ModeService(
            runningKernel: { nil },
            controlAPICredentials: { nil },
            activeSubscription: { nil },
            printLine: { printed.append($0) }
        )

        try await service.status(json: false)

        XCTAssertTrue(printed.contains(where: { $0.contains("kernel is not running") }))
    }

    func testStatus_matchingMode_humanOutput() async throws {
        let (sub, yaml) = fakeSubscription(name: "home-sub", embeddedMode: "rule")
        let mockClient = MockModeKernelClient(modeToReturn: "rule")
        var printed: [String] = []

        let service = ModeService(
            runningKernel: { self.fakeRunning() },
            controlAPICredentials: { self.fakeCreds() },
            clientFactory: { _ in mockClient },
            activeSubscription: { sub },
            loadSubscriptionYAML: { _ in yaml },
            isProcessRunning: { _ in true },
            printLine: { printed.append($0) }
        )

        try await service.status(json: false)

        XCTAssertTrue(printed.contains(where: { $0.contains("Effective mode:") && $0.contains("rule") }))
        XCTAssertTrue(printed.contains(where: { $0.contains("Subscription default:") && $0.contains("(matches)") }))
    }

    func testStatus_overriddenMode_humanOutput() async throws {
        let (sub, yaml) = fakeSubscription(name: "work-vpn", embeddedMode: "rule")
        let mockClient = MockModeKernelClient(modeToReturn: "global")
        var printed: [String] = []

        let service = ModeService(
            runningKernel: { self.fakeRunning() },
            controlAPICredentials: { self.fakeCreds() },
            clientFactory: { _ in mockClient },
            activeSubscription: { sub },
            loadSubscriptionYAML: { _ in yaml },
            isProcessRunning: { _ in true },
            printLine: { printed.append($0) }
        )

        try await service.status(json: false)

        XCTAssertTrue(printed.contains(where: { $0.contains("Effective mode:") && $0.contains("global") }))
        XCTAssertTrue(printed.contains(where: { $0.contains("Subscription default:") && $0.contains("(CLI override in effect)") }))
        XCTAssertTrue(printed.contains(where: { $0.contains("Note: this override was applied via 'mihomo mode global'") }))
    }

    func testStatus_noActiveSubscription() async throws {
        let mockClient = MockModeKernelClient(modeToReturn: "rule")
        var printed: [String] = []

        let service = ModeService(
            runningKernel: { self.fakeRunning() },
            controlAPICredentials: { self.fakeCreds() },
            clientFactory: { _ in mockClient },
            activeSubscription: { nil },
            isProcessRunning: { _ in true },
            printLine: { printed.append($0) }
        )

        try await service.status(json: false)

        XCTAssertTrue(printed.contains(where: { $0.contains("Effective mode:") && $0.contains("rule") }))
        XCTAssertTrue(printed.contains(where: { $0.contains("No active subscription — mode is a kernel-level setting only.") }))
    }

    func testStatus_jsonOutput() async throws {
        let (sub, yaml) = fakeSubscription(name: "work-vpn", embeddedMode: "rule")
        let mockClient = MockModeKernelClient(modeToReturn: "direct")
        var printed: [String] = []

        let service = ModeService(
            runningKernel: { self.fakeRunning() },
            controlAPICredentials: { self.fakeCreds() },
            clientFactory: { _ in mockClient },
            activeSubscription: { sub },
            loadSubscriptionYAML: { _ in yaml },
            isProcessRunning: { _ in true },
            printLine: { printed.append($0) }
        )

        try await service.status(json: true)

        let json = printed.joined(separator: "\n")
        XCTAssertTrue(json.contains("\"effectiveMode\" : \"direct\""))
        XCTAssertTrue(json.contains("\"isOverridden\" : true"))
        XCTAssertTrue(json.contains("\"hasActiveSubscription\" : true"))
        XCTAssertTrue(json.contains("\"isKernelRunning\" : true"))
    }

    // MARK: - Mode Switching Tests

    func testSwitchMode_noRunningKernel_throwsExit2() async throws {
        let service = ModeService(
            runningKernel: { nil },
            controlAPICredentials: { nil }
        )

        do {
            try await service.switchMode(to: "rule", yes: true)
            XCTFail("Expected permissionDenied exit code 2 when no kernel is running")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .permissionDenied)
            XCTAssertTrue(err.what.contains("no kernel running"))
        }
    }

    func testSwitchMode_rule_success() async throws {
        let mockClient = MockModeKernelClient(modeToReturn: "rule")
        var printed: [String] = []

        let service = ModeService(
            runningKernel: { self.fakeRunning() },
            controlAPICredentials: { self.fakeCreds() },
            clientFactory: { _ in mockClient },
            isProcessRunning: { _ in true },
            printLine: { printed.append($0) }
        )

        try await service.switchMode(to: "rule", yes: true)

        XCTAssertEqual(mockClient.lastPatchedMode, "rule")
        XCTAssertTrue(printed.contains(where: { $0.contains("Rule mode active.") }))
    }

    func testSwitchMode_global_yesFlag_skipsPromptAndPatches() async throws {
        let mockClient = MockModeKernelClient(modeToReturn: "global")
        var promptCalled = false
        var printed: [String] = []

        let service = ModeService(
            runningKernel: { self.fakeRunning() },
            controlAPICredentials: { self.fakeCreds() },
            clientFactory: { _ in mockClient },
            confirmationPrompt: { _, yes in
                if !yes { promptCalled = true }
                return .confirmed
            },
            isProcessRunning: { _ in true },
            printLine: { printed.append($0) }
        )

        try await service.switchMode(to: "global", yes: true)

        XCTAssertFalse(promptCalled, "--yes must skip the prompt")
        XCTAssertEqual(mockClient.lastPatchedMode, "global")
        XCTAssertTrue(printed.contains(where: { $0.contains("Global mode active.") }))
    }

    func testSwitchMode_global_declined_throwsExit2AndNeverPatches() async throws {
        let mockClient = MockModeKernelClient(modeToReturn: "rule")

        let service = ModeService(
            runningKernel: { self.fakeRunning() },
            controlAPICredentials: { self.fakeCreds() },
            clientFactory: { _ in mockClient },
            confirmationPrompt: { _, _ in .declined },
            isProcessRunning: { _ in true }
        )

        do {
            try await service.switchMode(to: "global", yes: false)
            XCTFail("Expected permissionDenied exit code 2 when declined")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .permissionDenied)
            XCTAssertNil(mockClient.lastPatchedMode, "patchConfigs must NEVER be invoked if confirmation was declined")
        }
    }

    func testSwitchMode_direct_declined_throwsExit2AndNeverPatches() async throws {
        let mockClient = MockModeKernelClient(modeToReturn: "rule")

        let service = ModeService(
            runningKernel: { self.fakeRunning() },
            controlAPICredentials: { self.fakeCreds() },
            clientFactory: { _ in mockClient },
            confirmationPrompt: { _, _ in .declined },
            isProcessRunning: { _ in true }
        )

        do {
            try await service.switchMode(to: "direct", yes: false)
            XCTFail("Expected permissionDenied exit code 2 when declined")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .permissionDenied)
            XCTAssertNil(mockClient.lastPatchedMode, "patchConfigs must NEVER be invoked if confirmation was declined")
        }
    }

    func testSwitchMode_livenessFailure_surfacesError() async throws {
        let mockClient = MockModeKernelClient(modeToReturn: "rule")
        mockClient.livenessResultToReturn = .configMismatch(field: "mode", expected: "global", actual: "rule")

        let service = ModeService(
            runningKernel: { self.fakeRunning() },
            controlAPICredentials: { self.fakeCreds() },
            clientFactory: { _ in mockClient },
            confirmationPrompt: { _, _ in .confirmed },
            isProcessRunning: { _ in true }
        )

        do {
            try await service.switchMode(to: "global", yes: true)
            XCTFail("Expected liveness check failure")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .validationFailure)
            XCTAssertTrue(err.what.contains("mode switch aborted at 'liveness check'"))
        }
    }
}

// MARK: - MockModeKernelClient

private final class MockModeKernelClient: KernelClient {
    var modeToReturn: String
    var lastPatchedMode: String?
    var livenessResultToReturn: LivenessResult = .healthy

    init(modeToReturn: String) {
        self.modeToReturn = modeToReturn
    }

    func version() async throws -> VersionInfo { VersionInfo(version: "v1.19.29", meta: true) }
    func getConfigs() async throws -> Configs { Configs(mode: modeToReturn, mixedPort: 7890) }
    func patchConfigs(_ patch: ConfigsPatch) async throws {
        self.lastPatchedMode = patch.mode
        if let m = patch.mode {
            self.modeToReturn = m
        }
    }
    func getProxies() async throws -> ProxyGroups { ProxyGroups(groups: [:]) }
    func selectProxy(group: String, node: String) async throws {}
    func getConnections() async throws -> ConnectionsSnapshot { ConnectionsSnapshot(downloadTotal: 0, uploadTotal: 0, connections: []) }
    func closeConnections() async throws {}

    func livenessCheck(expectedVersion: String?, expectedConfigPatch: ConfigsPatch?) async throws -> LivenessResult {
        return livenessResultToReturn
    }
}
