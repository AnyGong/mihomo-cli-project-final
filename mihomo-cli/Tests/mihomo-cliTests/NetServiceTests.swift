import XCTest
@testable import mihomo_cli

final class NetServiceTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1786500000)

    // MARK: - Status Tests

    func testStatus_none_humanOutput() async throws {
        var printed: [String] = []
        let service = NetService(
            networkMode: { .none },
            daemonState: { DaemonState(installed: false) },
            printLine: { printed.append($0) }
        )

        try await service.status(json: false)

        XCTAssertTrue(printed.contains(where: { $0.contains("Mode:") && $0.contains("none") }))
        XCTAssertTrue(printed.contains(where: { $0.contains("traffic is not being proxied") }))
    }

    func testStatus_systemProxy_humanOutput() async throws {
        var printed: [String] = []
        let service = NetService(
            networkMode: { .systemProxy(service: "Wi-Fi", host: "127.0.0.1", port: 7890, since: self.fixedDate) },
            daemonState: { DaemonState(installed: true) },
            printLine: { printed.append($0) },
            now: { self.fixedDate.addingTimeInterval(120) }
        )

        try await service.status(json: false)

        XCTAssertTrue(printed.contains(where: { $0.contains("Mode:") && $0.contains("System Proxy") }))
        XCTAssertTrue(printed.contains(where: { $0.contains("Interface:") && $0.contains("Wi-Fi") }))
        XCTAssertTrue(printed.contains(where: { $0.contains("Supervised:") && $0.contains("yes (launchd agent active)") }))
    }

    func testStatus_tun_humanOutput() async throws {
        var printed: [String] = []
        let service = NetService(
            networkMode: { .tun(interface: "utun0", since: self.fixedDate) },
            daemonState: { DaemonState(installed: false) },
            printLine: { printed.append($0) },
            now: { self.fixedDate.addingTimeInterval(300) }
        )

        try await service.status(json: false)

        XCTAssertTrue(printed.contains(where: { $0.contains("Mode:") && $0.contains("Tun") }))
        XCTAssertTrue(printed.contains(where: { $0.contains("Interface:") && $0.contains("utun0") }))
    }

    func testStatus_proxyMode_humanOutput() async throws {
        var printed: [String] = []
        let service = NetService(
            networkMode: { .proxyMode(port: 7890, since: self.fixedDate) },
            daemonState: { DaemonState(installed: false) },
            printLine: { printed.append($0) },
            now: { self.fixedDate.addingTimeInterval(60) }
        )

        try await service.status(json: false)

        XCTAssertTrue(printed.contains(where: { $0.contains("Mode:") && $0.contains("Proxy Mode") }))
        XCTAssertTrue(printed.contains(where: { $0.contains("Port:") && $0.contains("7890") }))
    }

    func testStatus_jsonOutput() async throws {
        var printed: [String] = []
        let service = NetService(
            networkMode: { .systemProxy(service: "Wi-Fi", host: "127.0.0.1", port: 7890, since: self.fixedDate) },
            daemonState: { DaemonState(installed: true) },
            printLine: { printed.append($0) }
        )

        try await service.status(json: true)

        let json = printed.joined(separator: "\n")
        XCTAssertTrue(json.contains("\"mode\" : \"system-proxy\""))
        XCTAssertTrue(json.contains("\"interface\" : \"Wi-Fi\""))
        XCTAssertTrue(json.contains("\"port\" : 7890"))
        XCTAssertTrue(json.contains("\"supervised\" : true"))
    }

    // MARK: - System Proxy Tests

    func testSystemProxyOn_singleActiveService_autoSelectsAndConfigures() async throws {
        let fakeSetup = FakeNetworkSetup(
            allServices: ["Wi-Fi", "Thunderbolt Bridge"],
            activeServices: ["Wi-Fi"],
            proxies: [:]
        )
        var appliedMode: ActiveNetworkMode = .none
        var appliedSettings: SystemProxySettings? = nil
        var printed: [String] = []

        let service = NetService(
            networkMode: { appliedMode },
            setNetworkMode: { appliedMode = $0 },
            lastAppliedSystemProxy: { appliedSettings },
            setLastAppliedSystemProxy: { appliedSettings = $0 },
            runningKernel: { nil },
            networkSetup: fakeSetup,
            printLine: { printed.append($0) }
        )

        try await service.systemProxyOn(interface: nil, yes: true)

        XCTAssertEqual(fakeSetup.setWebProxyCalls.count, 1)
        XCTAssertEqual(fakeSetup.setWebProxyCalls.first?.service, "Wi-Fi")
        XCTAssertEqual(fakeSetup.setWebProxyCalls.first?.host, "127.0.0.1")
        XCTAssertEqual(fakeSetup.setWebProxyCalls.first?.port, 7890)
        XCTAssertEqual(fakeSetup.webProxyStates["Wi-Fi"], true)
        XCTAssertEqual(fakeSetup.secureWebProxyStates["Wi-Fi"], true)

        if case .systemProxy(let svc, _, _, _) = appliedMode {
            XCTAssertEqual(svc, "Wi-Fi")
        } else {
            XCTFail("Expected systemProxy mode")
        }

        XCTAssertTrue(printed.contains(where: { $0.contains("System Proxy enabled on 'Wi-Fi'") }))
    }

    func testSystemProxyOn_explicitInterface_targetsSpecifiedService() async throws {
        let fakeSetup = FakeNetworkSetup(
            allServices: ["Wi-Fi", "USB Ethernet"],
            activeServices: ["Wi-Fi", "USB Ethernet"],
            proxies: [:]
        )
        var appliedMode: ActiveNetworkMode = .none

        let service = NetService(
            networkMode: { appliedMode },
            setNetworkMode: { appliedMode = $0 },
            networkSetup: fakeSetup
        )

        try await service.systemProxyOn(interface: "USB Ethernet", yes: true)

        XCTAssertEqual(fakeSetup.setWebProxyCalls.first?.service, "USB Ethernet")
    }

    func testSystemProxyOn_unknownInterface_throwsExit7() async throws {
        let fakeSetup = FakeNetworkSetup(
            allServices: ["Wi-Fi"],
            activeServices: ["Wi-Fi"],
            proxies: [:]
        )
        let service = NetService(networkSetup: fakeSetup)

        do {
            try await service.systemProxyOn(interface: "Invalid-Interface", yes: true)
            XCTFail("Expected portUnavailable exit 7")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .portUnavailable)
        }
    }

    func testSystemProxyOn_conflictingForeignProxy_declined_throwsExit2AndNeverApplies() async throws {
        let fakeSetup = FakeNetworkSetup(
            allServices: ["Wi-Fi"],
            activeServices: ["Wi-Fi"],
            proxies: ["Wi-Fi": WebProxyInfo(enabled: true, server: "10.0.0.1", port: 8118)]
        )

        let service = NetService(
            networkMode: { .none },
            setNetworkMode: { _ in },
            lastAppliedSystemProxy: { nil },
            networkSetup: fakeSetup,
            confirmationPrompt: { _, _ in .declined }
        )

        do {
            try await service.systemProxyOn(interface: "Wi-Fi", yes: false)
            XCTFail("Expected permissionDenied exit 2 on declined conflict")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .permissionDenied)
            XCTAssertEqual(fakeSetup.setWebProxyCalls.count, 0, "Must NEVER apply proxy if user declined overwrite")
        }
    }

    func testSystemProxyOff_whenActive_cleansUp() async throws {
        let fakeSetup = FakeNetworkSetup(
            allServices: ["Wi-Fi"],
            activeServices: ["Wi-Fi"],
            proxies: ["Wi-Fi": WebProxyInfo(enabled: true, server: "127.0.0.1", port: 7890)]
        )
        var appliedMode: ActiveNetworkMode = .systemProxy(service: "Wi-Fi", host: "127.0.0.1", port: 7890, since: Date())
        var printed: [String] = []

        let service = NetService(
            networkMode: { appliedMode },
            setNetworkMode: { appliedMode = $0 },
            networkSetup: fakeSetup,
            printLine: { printed.append($0) }
        )

        try await service.systemProxyOff(yes: true)

        XCTAssertEqual(fakeSetup.webProxyStates["Wi-Fi"], false)
        XCTAssertEqual(appliedMode, .none)
        XCTAssertTrue(printed.contains(where: { $0.contains("System Proxy disabled on 'Wi-Fi'") }))
    }

    // MARK: - Tun Mode Tests

    func testTunOn_utunConflict_throwsExit7() async throws {
        let fakeInspector = FakePortInspector(utunPresent: true, listeningProcesses: [:])
        let service = NetService(
            networkMode: { .none },
            portInspector: fakeInspector
        )

        do {
            try await service.tunOn(yes: true)
            XCTFail("Expected portUnavailable exit 7 when utun exists")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .portUnavailable)
            XCTAssertTrue(err.what.contains("cannot start Tun mode"))
        }
    }

    func testTunOn_entitlementDeclined_throwsExit6() async throws {
        let fakeInspector = FakePortInspector(utunPresent: false, listeningProcesses: [:])
        let service = NetService(
            networkMode: { .none },
            portInspector: fakeInspector,
            confirmationPrompt: { _, _ in .declined }
        )

        do {
            try await service.tunOn(yes: false)
            XCTFail("Expected privilegeError exit 6 when entitlement declined")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .privilegeError)
            XCTAssertTrue(err.what.contains("Tun mode unavailable"))
        }
    }

    func testTunOn_success() async throws {
        let fakeInspector = FakePortInspector(utunPresent: false, listeningProcesses: [:])
        var appliedMode: ActiveNetworkMode = .none
        var printed: [String] = []

        let service = NetService(
            networkMode: { appliedMode },
            setNetworkMode: { appliedMode = $0 },
            portInspector: fakeInspector,
            printLine: { printed.append($0) }
        )

        try await service.tunOn(yes: true)

        if case .tun = appliedMode {
            // expected
        } else {
            XCTFail("Expected Tun mode")
        }
        XCTAssertTrue(printed.contains(where: { $0.contains("Tun mode active.") }))
    }

    func testTunOff_idempotent() async throws {
        var printed: [String] = []
        let service = NetService(
            networkMode: { .none },
            printLine: { printed.append($0) }
        )

        try await service.tunOff()
        XCTAssertTrue(printed.contains(where: { $0.contains("Tun mode is not active — nothing to do.") }))
    }

    // MARK: - Proxy Mode Tests

    func testProxyModeOn_portConflict_throwsExit7() async throws {
        let fakeInspector = FakePortInspector(
            utunPresent: false,
            listeningProcesses: [7890: ProcessPortInfo(pid: 4021, command: "docker")]
        )
        let service = NetService(
            networkMode: { .none },
            runningKernel: { nil },
            portInspector: fakeInspector
        )

        do {
            try await service.proxyModeOn(port: 7890)
            XCTFail("Expected portUnavailable exit 7 on port collision")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .portUnavailable)
            XCTAssertTrue(err.cause.contains("docker"))
        }
    }

    func testProxyModeOn_success() async throws {
        let fakeInspector = FakePortInspector(utunPresent: false, listeningProcesses: [:])
        var appliedMode: ActiveNetworkMode = .none
        var printed: [String] = []

        let service = NetService(
            networkMode: { appliedMode },
            setNetworkMode: { appliedMode = $0 },
            portInspector: fakeInspector,
            printLine: { printed.append($0) },
            now: { self.fixedDate }
        )

        try await service.proxyModeOn(port: 8080)

        XCTAssertEqual(appliedMode, .proxyMode(port: 8080, since: self.fixedDate))
        XCTAssertTrue(printed.contains(where: { $0.contains("Proxy mode active on port 8080.") }))
    }

    // MARK: - Mutual Exclusivity Tests

    func testMutualExclusivity_switchingToTunDisablesSystemProxy() async throws {
        let fakeSetup = FakeNetworkSetup(
            allServices: ["Wi-Fi"],
            activeServices: ["Wi-Fi"],
            proxies: ["Wi-Fi": WebProxyInfo(enabled: true, server: "127.0.0.1", port: 7890)]
        )
        let fakeInspector = FakePortInspector(utunPresent: false, listeningProcesses: [:])

        var currentMode: ActiveNetworkMode = .systemProxy(service: "Wi-Fi", host: "127.0.0.1", port: 7890, since: Date())

        let service = NetService(
            networkMode: { currentMode },
            setNetworkMode: { currentMode = $0 },
            networkSetup: fakeSetup,
            portInspector: fakeInspector
        )

        try await service.tunOn(yes: true)

        XCTAssertEqual(fakeSetup.webProxyStates["Wi-Fi"], false, "Activating Tun mode must deactivate pre-existing System Proxy")
        if case .tun = currentMode {
            // expected
        } else {
            XCTFail("Expected Tun mode")
        }
    }

    func testOff_deactivatesWhicheverIsActive() async throws {
        var currentMode: ActiveNetworkMode = .proxyMode(port: 7890, since: Date())
        var printed: [String] = []

        let service = NetService(
            networkMode: { currentMode },
            setNetworkMode: { currentMode = $0 },
            printLine: { printed.append($0) }
        )

        try await service.off()

        XCTAssertEqual(currentMode, .none)
        XCTAssertTrue(printed.contains(where: { $0.contains("Proxy mode disabled.") }))
    }
}

// MARK: - Fakes for Testing

private final class FakeNetworkSetup: NetworkSetupManaging {
    let allServices: [String]
    let activeServices: [String]
    var proxies: [String: WebProxyInfo]
    var webProxyStates: [String: Bool] = [:]
    var secureWebProxyStates: [String: Bool] = [:]
    var setWebProxyCalls: [(service: String, host: String, port: Int)] = []

    init(allServices: [String], activeServices: [String], proxies: [String: WebProxyInfo]) {
        self.allServices = allServices
        self.activeServices = activeServices
        self.proxies = proxies
    }

    func listAllServices() throws -> [String] { allServices }
    func getActiveServices() throws -> [String] { activeServices }
    func getWebProxy(service: String) throws -> WebProxyInfo {
        proxies[service] ?? WebProxyInfo(enabled: false, server: "", port: 0)
    }
    func getSecureWebProxy(service: String) throws -> WebProxyInfo {
        proxies[service] ?? WebProxyInfo(enabled: false, server: "", port: 0)
    }
    func setWebProxy(service: String, host: String, port: Int) throws {
        setWebProxyCalls.append((service, host, port))
    }
    func setWebProxyState(service: String, enabled: Bool) throws {
        webProxyStates[service] = enabled
    }
    func setSecureWebProxy(service: String, host: String, port: Int) throws {}
    func setSecureWebProxyState(service: String, enabled: Bool) throws {
        secureWebProxyStates[service] = enabled
    }
}

private final class FakePortInspector: PortInspecting {
    let utunPresent: Bool
    let listeningProcesses: [Int: ProcessPortInfo]

    init(utunPresent: Bool, listeningProcesses: [Int: ProcessPortInfo]) {
        self.utunPresent = utunPresent
        self.listeningProcesses = listeningProcesses
    }

    func findProcessUsingPort(_ port: Int) throws -> ProcessPortInfo? {
        listeningProcesses[port]
    }

    func isUtunInterfacePresent() -> Bool {
        utunPresent
    }
}
