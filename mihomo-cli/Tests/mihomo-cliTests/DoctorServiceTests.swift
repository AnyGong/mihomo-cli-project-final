import XCTest
@testable import mihomo_cli

final class DoctorServiceTests: XCTestCase {

    private var tempDir: URL!
    private var validBinary: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        validBinary = tempDir.appendingPathComponent("mihomo")
        try? "binary".data(using: .utf8)?.write(to: validBinary)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testDoctor_allChecksPassed_humanOutput() async throws {
        var printed: [String] = []
        let activeK = KernelRecord(version: "1.19.10", binaryPath: validBinary.path, addedAt: Date(), isActive: true)
        let activeS = SubscriptionRecord(name: "work-vpn", source: .local(path: "/tmp/sub.yaml"), addedAt: Date(), updatedAt: Date(), isActive: true)

        let service = DoctorService(
            activeKernel: { activeK },
            activeSubscription: { activeS },
            networkMode: { .none },
            daemonState: { DaemonState(installed: false) },
            runningKernel: { nil },
            networkSetup: FakeDoctorNetworkSetup(proxies: [:]),
            portInspector: FakeDoctorPortInspector(portBusy: false),
            launchdManager: FakeDoctorLaunchd(installed: false),
            printLine: { printed.append($0) }
        )

        try await service.run(json: false)

        XCTAssertTrue(printed.contains(where: { $0.contains("Kernel binary present") && $0.contains("passed (v1.19.10)") }))
        XCTAssertTrue(printed.contains(where: { $0.contains("Subscription validity") && $0.contains("passed (work-vpn)") }))
        XCTAssertTrue(printed.contains(where: { $0.contains("Port 7890 availability") && $0.contains("free") }))
        XCTAssertTrue(printed.contains(where: { $0.contains("All 7 diagnostic checks passed with 0 warnings.") }))
    }

    func testDoctor_warningsDetected_reportsSummaryWithoutFailing() async throws {
        var printed: [String] = []
        let activeK = KernelRecord(version: "1.19.10", binaryPath: validBinary.path, addedAt: Date(), isActive: true)
        let activeS = SubscriptionRecord(name: "bad-sub", source: .local(path: "/tmp/sub.yaml"), addedAt: Date(), updatedAt: Date(), isActive: true, isFlaggedInvalid: true)

        let service = DoctorService(
            activeKernel: { activeK },
            activeSubscription: { activeS },
            networkMode: { .none },
            daemonState: { DaemonState(installed: false) },
            runningKernel: { nil },
            networkSetup: FakeDoctorNetworkSetup(proxies: [:]),
            portInspector: FakeDoctorPortInspector(portBusy: true),
            launchdManager: FakeDoctorLaunchd(installed: false),
            printLine: { printed.append($0) }
        )

        try await service.run(json: false)

        XCTAssertTrue(printed.contains(where: { $0.contains("Subscription validity") && $0.contains("flagged invalid") }))
        XCTAssertTrue(printed.contains(where: { $0.contains("Port 7890 availability") && $0.contains("in use by pid 9999") }))
        XCTAssertTrue(printed.contains(where: { $0.contains("2 warnings found:") }))
    }

    func testDoctor_jsonOutput() async throws {
        var printed: [String] = []
        let activeK = KernelRecord(version: "1.19.10", binaryPath: validBinary.path, addedAt: Date(), isActive: true)

        let service = DoctorService(
            activeKernel: { activeK },
            activeSubscription: { nil },
            networkMode: { .none },
            daemonState: { DaemonState(installed: false) },
            runningKernel: { nil },
            networkSetup: FakeDoctorNetworkSetup(proxies: [:]),
            portInspector: FakeDoctorPortInspector(portBusy: false),
            launchdManager: FakeDoctorLaunchd(installed: false),
            printLine: { printed.append($0) }
        )

        try await service.run(json: true)

        let json = printed.joined(separator: "\n")
        XCTAssertTrue(json.contains("\"name\" : \"Kernel binary present\""))
        XCTAssertTrue(json.contains("\"warningCount\" : 1"))
    }

    func testDoctor_missingBinary_throwsExit8() async throws {
        let activeK = KernelRecord(version: "1.19.10", binaryPath: "/nonexistent/binary", addedAt: Date(), isActive: true)

        let service = DoctorService(
            activeKernel: { activeK }
        )

        do {
            try await service.run(json: false)
            XCTFail("Expected sourceVerificationFailure exit 8 when active binary missing")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .sourceVerificationFailure)
        }
    }
}

private final class FakeDoctorNetworkSetup: NetworkSetupManaging {
    let proxies: [String: WebProxyInfo]
    init(proxies: [String: WebProxyInfo]) { self.proxies = proxies }
    func listAllServices() throws -> [String] { ["Wi-Fi"] }
    func getActiveServices() throws -> [String] { ["Wi-Fi"] }
    func getWebProxy(service: String) throws -> WebProxyInfo { proxies[service] ?? WebProxyInfo(enabled: false, server: "", port: 0) }
    func getSecureWebProxy(service: String) throws -> WebProxyInfo { proxies[service] ?? WebProxyInfo(enabled: false, server: "", port: 0) }
    func setWebProxy(service: String, host: String, port: Int) throws {}
    func setWebProxyState(service: String, enabled: Bool) throws {}
    func setSecureWebProxy(service: String, host: String, port: Int) throws {}
    func setSecureWebProxyState(service: String, enabled: Bool) throws {}
}

private final class FakeDoctorPortInspector: PortInspecting {
    let portBusy: Bool
    init(portBusy: Bool) { self.portBusy = portBusy }
    func findProcessUsingPort(_ port: Int) throws -> ProcessPortInfo? {
        portBusy ? ProcessPortInfo(pid: 9999, command: "foreign-process") : nil
    }
    func isUtunInterfacePresent() -> Bool { false }
}

private final class FakeDoctorLaunchd: LaunchdManaging {
    var plistURL: URL = URL(fileURLWithPath: "/tmp/fake.plist")
    let installed: Bool
    init(installed: Bool) { self.installed = installed }
    func isPlistPresent() -> Bool { installed }
    func writePlist(_ content: String) throws {}
    func removePlist() throws {}
    func bootstrap() throws {}
    func bootout() throws {}
}
