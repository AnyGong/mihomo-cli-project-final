import XCTest
@testable import mihomo_cli

final class LaunchdAgentTests: XCTestCase {

    func testGeneratePlist() {
        let plist = DaemonService.generatePlist(executablePath: "/usr/local/bin/mihomo", logDir: "/Users/test/.mihomo-cli/logs")
        XCTAssertTrue(plist.contains("<string>com.mihomo-cli.agent</string>"))
        XCTAssertTrue(plist.contains("<string>/usr/local/bin/mihomo</string>"))
        XCTAssertTrue(plist.contains("<string>start</string>"))
        XCTAssertTrue(plist.contains("<string>/Users/test/.mihomo-cli/logs/daemon.stdout.log</string>"))
        XCTAssertTrue(plist.contains("<key>RunAtLoad</key>"))
    }

    func testDaemonInstall_success() async throws {
        let fakeLaunchd = FakeLaunchdManager()
        var daemon = DaemonState(installed: false)
        var printed: [String] = []

        let service = DaemonService(
            launchdManager: fakeLaunchd,
            daemonState: { daemon },
            updateDaemonState: { update in update(&daemon) },
            printLine: { printed.append($0) },
            cliExecutablePath: { "/tmp/mihomo" }
        )

        try await service.install(yes: true)

        XCTAssertTrue(daemon.installed)
        XCTAssertTrue(fakeLaunchd.writtenPlistContent?.contains("com.mihomo-cli.agent") ?? false)
        XCTAssertTrue(fakeLaunchd.bootstrapCalled)
        XCTAssertTrue(printed.contains(where: { $0.contains("Daemon installed") }))
    }

    func testDaemonInstall_alreadyInstalled_isIdempotent() async throws {
        let fakeLaunchd = FakeLaunchdManager()
        fakeLaunchd.plistExists = true
        let daemon = DaemonState(installed: true)
        var printed: [String] = []

        let service = DaemonService(
            launchdManager: fakeLaunchd,
            daemonState: { daemon },
            updateDaemonState: { _ in },
            printLine: { printed.append($0) }
        )

        try await service.install(yes: true)

        XCTAssertFalse(fakeLaunchd.bootstrapCalled)
        XCTAssertTrue(printed.contains(where: { $0.contains("already installed") }))
    }

    func testDaemonRemove_success() async throws {
        let fakeLaunchd = FakeLaunchdManager()
        fakeLaunchd.plistExists = true
        var daemon = DaemonState(installed: true)
        var printed: [String] = []

        let service = DaemonService(
            launchdManager: fakeLaunchd,
            daemonState: { daemon },
            updateDaemonState: { update in update(&daemon) },
            runningKernel: { RunningKernelState(version: "1.19.10", pid: 4102, startedAt: Date(), controlPort: 9090, mixedPort: 7890, configPath: "", stdoutPath: "", stderrPath: "") },
            printLine: { printed.append($0) }
        )

        try await service.remove(yes: true)

        XCTAssertFalse(daemon.installed)
        XCTAssertTrue(fakeLaunchd.bootoutCalled)
        XCTAssertTrue(fakeLaunchd.removePlistCalled)
        XCTAssertTrue(printed.contains(where: { $0.contains("Daemon removed") && $0.contains("pid 4102") }))
    }

    func testDaemonStatus_installed_and_notInstalled() async throws {
        var printed: [String] = []
        let fakeLaunchd = FakeLaunchdManager()

        let serviceNotInstalled = DaemonService(
            launchdManager: fakeLaunchd,
            daemonState: { DaemonState(installed: false) },
            printLine: { printed.append($0) }
        )
        try await serviceNotInstalled.status(json: false)
        XCTAssertTrue(printed.contains(where: { $0.contains("Installed: no") }))

        printed.removeAll()
        fakeLaunchd.plistExists = true
        let serviceInstalled = DaemonService(
            launchdManager: fakeLaunchd,
            daemonState: { DaemonState(installed: true, restartCount: 2, lastRestartAt: Date(timeIntervalSince1970: 1786500000), lastRestartReason: "kernel crashed") },
            printLine: { printed.append($0) }
        )
        try await serviceInstalled.status(json: false)
        XCTAssertTrue(printed.contains(where: { $0.contains("Installed:      yes") }))
        XCTAssertTrue(printed.contains(where: { $0.contains("Restart count:  2") }))
    }
}

private final class FakeLaunchdManager: LaunchdManaging {
    var plistURL: URL = URL(fileURLWithPath: "/tmp/com.mihomo-cli.agent.plist")
    var plistExists: Bool = false
    var writtenPlistContent: String?
    var bootstrapCalled = false
    var bootoutCalled = false
    var removePlistCalled = false

    func isPlistPresent() -> Bool { plistExists }
    func writePlist(_ content: String) throws {
        writtenPlistContent = content
        plistExists = true
    }
    func removePlist() throws {
        removePlistCalled = true
        plistExists = false
    }
    func bootstrap() throws { bootstrapCalled = true }
    func bootout() throws { bootoutCalled = true }
}
