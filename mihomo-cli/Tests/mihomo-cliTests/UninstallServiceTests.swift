import XCTest
@testable import mihomo_cli

final class UninstallServiceTests: XCTestCase {

    private var tempHome: URL!

    override func setUp() {
        super.setUp()
        tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempHome.appendingPathComponent(".mihomo-cli"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempHome)
        super.tearDown()
    }

    func testUninstall_declinedPrompt_throwsExit2() async throws {
        let service = UninstallService(
            confirmationPrompt: { _, _ in .declined }
        )

        do {
            try await service.uninstall(purgeData: false, yes: false)
            XCTFail("Expected permissionDenied exit 2 on declined uninstall")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .permissionDenied)
        }
    }

    func testUninstall_successWithPurgeData() async throws {
        var printed: [String] = []

        let service = UninstallService(
            lifecycleService: LifecycleService(runningKernel: { nil }),
            daemonService: DaemonService(daemonState: { DaemonState(installed: false) }),
            netService: NetService(networkMode: { .none }),
            confirmationPrompt: { _, _ in .confirmed },
            printLine: { printed.append($0) },
            homeDirectoryURL: tempHome
        )

        try await service.uninstall(purgeData: true, yes: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempHome.appendingPathComponent(".mihomo-cli").path))
        XCTAssertTrue(printed.contains(where: { $0.contains("Uninstall completed successfully. All data purged.") }))
    }
}
