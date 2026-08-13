import XCTest
@testable import mihomo_cli

final class SubscriptionServiceTests: XCTestCase {

    private var tempDir: URL!
    private var subDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sub-tests-\(UUID().uuidString)")
        subDir = tempDir.appendingPathComponent("subscriptions")
        try? FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func createTestFile(named name: String, content: String) throws -> URL {
        let fileURL = tempDir.appendingPathComponent(name)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private var minimalValidYAML: String {
        """
        mode: rule
        proxies:
          - name: "Node-1"
            type: ss
            server: 1.2.3.4
            port: 8388
        proxy-groups:
          - name: "PROXY"
            type: select
            proxies:
              - "Node-1"
        rules:
          - MATCH,PROXY
        """
    }

    private var invalidYAML: String {
        """
        mode: rule
        proxies:
          - name: "Node-1"
            type: unknown_type
        """
    }

    // MARK: - Add Local Tests

    func testAddLocal_success() async throws {
        let file = try createTestFile(named: "my-config.yaml", content: minimalValidYAML)
        var stored: [SubscriptionRecord] = []
        var printed: [String] = []

        let service = SubscriptionService(
            subscriptionsDirectory: subDir,
            subscription: { name in stored.first { $0.name == name } },
            upsertSubscription: { record in stored.append(record); return record },
            printLine: { printed.append($0) }
        )

        try await service.addLocal(path: file.path, preferredName: "custom-name", yes: true)

        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].name, "custom-name")
        XCTAssertEqual(stored[0].source, .local(path: file.path))
        XCTAssertTrue(printed.contains(where: { $0.contains("Imported local subscription 'custom-name'") }))
    }

    func testAddLocal_validationFailure_rejectsImmediately() async throws {
        let file = try createTestFile(named: "broken.yaml", content: invalidYAML)
        var stored: [SubscriptionRecord] = []

        let service = SubscriptionService(
            subscriptionsDirectory: subDir,
            subscription: { name in stored.first { $0.name == name } },
            upsertSubscription: { record in stored.append(record); return record }
        )

        do {
            try await service.addLocal(path: file.path, preferredName: nil, yes: true)
            XCTFail("Expected validation error")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .validationFailure)
            XCTAssertTrue(stored.isEmpty, "Nothing should be persisted on validation failure")
        }
    }

    func testAddLocal_nameCollision_appendsSuffixWhenDeclined() async throws {
        let file = try createTestFile(named: "my-config.yaml", content: minimalValidYAML)
        var stored: [SubscriptionRecord] = [
            SubscriptionRecord(name: "my-config", source: .local(path: "/other"), addedAt: Date(), updatedAt: Date(), isActive: false)
        ]

        let service = SubscriptionService(
            subscriptionsDirectory: subDir,
            subscription: { name in stored.first { $0.name == name } },
            upsertSubscription: { record in stored.append(record); return record },
            uniqueSubscriptionName: { _ in "my-config-2" },
            confirmationPrompt: { _, _ in .declined }
        )

        try await service.addLocal(path: file.path, preferredName: "my-config", yes: false)

        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored.last?.name, "my-config-2")
    }

    // MARK: - Add Remote Tests

    func testAddRemote_success() async throws {
        var stored: [SubscriptionRecord] = []
        let mockDownloader = MockDownloader(contentToReturn: minimalValidYAML)

        let service = SubscriptionService(
            subscriptionsDirectory: subDir,
            subscription: { name in stored.first { $0.name == name } },
            upsertSubscription: { record in stored.append(record); return record },
            downloader: mockDownloader
        )

        try await service.addRemote(url: "https://example.com/sub.yaml", interval: 120, preferredName: "remote-1", yes: true)

        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].name, "remote-1")
        XCTAssertEqual(stored[0].source, .remote(url: "https://example.com/sub.yaml", intervalMinutes: 120))

        let downloadedFile = subDir.appendingPathComponent("remote-1.yaml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadedFile.path))
    }

    func testAddRemote_invalidInterval_throwsValidationFailure() async throws {
        let service = SubscriptionService(subscriptionsDirectory: subDir)

        do {
            try await service.addRemote(url: "https://example.com/sub.yaml", interval: 0, preferredName: nil, yes: true)
            XCTFail("Expected validation failure for interval 0")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .validationFailure)
        }
    }

    // MARK: - Use Tests & Mode Precedence

    func testUse_alreadyActive_printsNoOp() async throws {
        let activeRec = SubscriptionRecord(name: "active-sub", source: .local(path: "/dummy"), addedAt: Date(), updatedAt: Date(), isActive: true)
        var printed: [String] = []

        let service = SubscriptionService(
            subscriptionsDirectory: subDir,
            subscription: { _ in activeRec },
            printLine: { printed.append($0) }
        )

        try await service.use(name: "active-sub", force: false)
        XCTAssertTrue(printed.contains(where: { $0.contains("already the active subscription") }))
    }

    func testUse_modePrecedence_printsNoteWhenDiffering() async throws {
        let globalYAML = """
        mode: global
        proxies:
          - name: "P1"
            type: ss
            server: 1.1.1.1
            port: 1000
        proxy-groups:
          - name: "G1"
            type: select
            proxies:
              - "P1"
        rules:
          - MATCH,G1
        """
        let file = try createTestFile(named: "global.yaml", content: globalYAML)
        let subRec = SubscriptionRecord(name: "work-vpn", source: .local(path: file.path), addedAt: Date(), updatedAt: Date(), isActive: false)
        var activeName: String?
        var printed: [String] = []

        let service = SubscriptionService(
            subscriptionsDirectory: subDir,
            subscription: { _ in subRec },
            activeSubscription: { nil },
            setActiveSubscription: { activeName = $0 },
            runningKernel: { nil },
            controlAPICredentials: { nil },
            printLine: { printed.append($0) }
        )

        try await service.use(name: "work-vpn", force: false)

        XCTAssertEqual(activeName, "work-vpn")
        XCTAssertTrue(printed.contains(where: { $0.contains("Switched to 'work-vpn'.") }))
        XCTAssertTrue(printed.contains(where: { $0.contains("subscription default mode is 'global', but 'rule' is currently in effect") }))
    }

    // MARK: - Edit Tests

    func testEdit_activeSubscription_blockedWithExit2() async throws {
        let activeRec = SubscriptionRecord(name: "active-sub", source: .local(path: "/dummy"), addedAt: Date(), updatedAt: Date(), isActive: true)

        let service = SubscriptionService(
            subscriptionsDirectory: subDir,
            subscription: { _ in activeRec }
        )

        do {
            try await service.edit(name: "active-sub", customEditor: nil)
            XCTFail("Expected permissionDenied exit code 2")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .permissionDenied)
            XCTAssertTrue(err.what.contains("cannot edit 'active-sub'"))
        }
    }

    // MARK: - Remove Tests

    func testRemove_activeSubscription_blockedWithExit2() async throws {
        let activeRec = SubscriptionRecord(name: "active-sub", source: .local(path: "/dummy"), addedAt: Date(), updatedAt: Date(), isActive: true)

        let service = SubscriptionService(
            subscriptionsDirectory: subDir,
            subscription: { _ in activeRec }
        )

        do {
            try await service.remove(name: "active-sub", yes: true)
            XCTFail("Expected permissionDenied exit code 2")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .permissionDenied)
            XCTAssertTrue(err.what.contains("cannot remove 'active-sub'"))
        }
    }

    func testRemove_inactiveSubscription_success() async throws {
        let rec = SubscriptionRecord(name: "old-sub", source: .local(path: "/dummy"), addedAt: Date(), updatedAt: Date(), isActive: false)
        var removedName: String?
        var printed: [String] = []

        let service = SubscriptionService(
            subscriptionsDirectory: subDir,
            subscription: { _ in rec },
            removeSubscriptionRecord: { removedName = $0 },
            confirmationPrompt: { _, _ in .confirmed },
            printLine: { printed.append($0) }
        )

        try await service.remove(name: "old-sub", yes: false)

        XCTAssertEqual(removedName, "old-sub")
        XCTAssertTrue(printed.contains(where: { $0.contains("Removed subscription 'old-sub'.") }))
    }

    // MARK: - Refresh Tests

    func testRefresh_localSubscription_errorsWithExit2() async throws {
        let localRec = SubscriptionRecord(name: "local-sub", source: .local(path: "/dummy"), addedAt: Date(), updatedAt: Date(), isActive: false)

        let service = SubscriptionService(
            subscriptionsDirectory: subDir,
            subscription: { _ in localRec }
        )

        do {
            try await service.refresh(name: "local-sub")
            XCTFail("Expected permissionDenied exit code 2")
        } catch let err as CLIError {
            XCTAssertEqual(err.exitCode, .permissionDenied)
            XCTAssertTrue(err.what.contains("local subscription"))
        }
    }

    func testRefresh_remoteSubscription_success() async throws {
        let remoteRec = SubscriptionRecord(name: "remote-sub", source: .remote(url: "https://example.com/sub.yaml", intervalMinutes: 60), addedAt: Date(), updatedAt: Date(), isActive: false)
        let mockDownloader = MockDownloader(contentToReturn: minimalValidYAML)
        var updatedRec: SubscriptionRecord?
        var printed: [String] = []

        let service = SubscriptionService(
            subscriptionsDirectory: subDir,
            subscription: { _ in remoteRec },
            upsertSubscription: { updatedRec = $0; return $0 },
            downloader: mockDownloader,
            printLine: { printed.append($0) }
        )

        try await service.refresh(name: "remote-sub")

        XCTAssertNotNil(updatedRec)
        XCTAssertTrue(printed.contains(where: { $0.contains("Refreshed remote subscription 'remote-sub'.") }))
    }

    // MARK: - Import Safety Test (§1.2.2)

    func testImportSafety_userSourceFileNeverMutated() async throws {
        let file = try createTestFile(named: "original.yaml", content: minimalValidYAML)
        let originalBytes = try Data(contentsOf: file)

        let subRec = SubscriptionRecord(name: "safe-sub", source: .local(path: file.path), addedAt: Date(), updatedAt: Date(), isActive: false)

        let service = SubscriptionService(
            subscriptionsDirectory: subDir,
            subscription: { _ in subRec },
            activeSubscription: { nil },
            setActiveSubscription: { _ in },
            runningKernel: { nil },
            controlAPICredentials: { nil }
        )

        try await service.use(name: "safe-sub", force: false)

        let currentBytes = try Data(contentsOf: file)
        XCTAssertEqual(originalBytes, currentBytes, "User's original subscription file on disk must be byte-for-byte unchanged")
    }
}

// MARK: - Mock Downloader

private final class MockDownloader: Downloading {
    let contentToReturn: String
    var errorToThrow: Error?

    init(contentToReturn: String, errorToThrow: Error? = nil) {
        self.contentToReturn = contentToReturn
        self.errorToThrow = errorToThrow
    }

    func download(from url: URL, to destination: URL) async throws {
        if let err = errorToThrow {
            throw err
        }
        try contentToReturn.write(to: destination, atomically: true, encoding: .utf8)
    }
}
