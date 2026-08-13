import XCTest
@testable import mihomo_cli

/// Unit tests for KernelCheckService.
/// All network calls and store access are replaced with test fakes via closure injection.
final class KernelCheckServiceTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a minimal fake stable GitHubRelease.
    private func fakeRelease(tag: String, stable: Bool = true) -> GitHubRelease {
        GitHubRelease(
            tagName: tag,
            prerelease: !stable,
            draft: false,
            publishedAt: Date(timeIntervalSinceReferenceDate: 0),
            assets: []
        )
    }

    /// Fake KernelReleaseProviding that returns a fixed list.
    private final class FakeReleaseProvider: KernelReleaseProviding {
        let releases: [GitHubRelease]
        init(_ releases: [GitHubRelease]) { self.releases = releases }

        func latestReleases(limit: Int) async throws -> [GitHubRelease] { releases }
        func release(tag: String) async throws -> GitHubRelease {
            guard let r = releases.first(where: { $0.tagName == tag }) else {
                throw CLIError(what: "not found", cause: "tag \(tag)", exitCode: .notFound)
            }
            return r
        }
    }

    // MARK: - Tests

    func testAlreadyLatest() async throws {
        let version = "v1.19.29"
        var printed: [String] = []
        var fetchCalled = false
        var useCalled = false

        let service = KernelCheckService(
            releaseProvider: FakeReleaseProvider([fakeRelease(tag: version)]),
            activeKernel: { KernelRecord(version: version, binaryPath: "/fake", addedAt: Date(), lastUsedAt: nil, isActive: true) },
            fetchKernel: { _ in fetchCalled = true },
            useKernel: { v in useCalled = true; return KernelUseResult(outcome: .switched, version: v) },
            confirmationPrompt: { _, _ in XCTFail("Should not prompt"); return .declined },
            printLine: { printed.append($0) }
        )

        try await service.check(yes: false)

        XCTAssertFalse(fetchCalled, "Should not fetch when already at latest")
        XCTAssertFalse(useCalled, "Should not switch when already at latest")
        XCTAssertEqual(printed.count, 1)
        XCTAssert(printed[0].contains("already the latest stable release"))
    }

    func testNewerAvailable_yesFlag_fetchesAndSwitches() async throws {
        let oldVersion = "v1.19.28"
        let newVersion = "v1.19.29"
        var printed: [String] = []
        var fetchedVersion: String?
        var usedVersion: String?

        let service = KernelCheckService(
            releaseProvider: FakeReleaseProvider([fakeRelease(tag: newVersion)]),
            activeKernel: { KernelRecord(version: oldVersion, binaryPath: "/fake", addedAt: Date(), lastUsedAt: nil, isActive: true) },
            fetchKernel: { v in fetchedVersion = v },
            useKernel: { v in usedVersion = v; return KernelUseResult(outcome: .switched, version: v) },
            confirmationPrompt: { _, yes in yes ? .confirmed : .declined },
            printLine: { printed.append($0) }
        )

        try await service.check(yes: true)

        XCTAssertEqual(fetchedVersion, newVersion, "Should have fetched new version")
        XCTAssertEqual(usedVersion, newVersion, "Should have switched to new version")
        XCTAssert(printed.contains(where: { $0.contains("is now active") }))
    }

    func testNewerAvailable_declined_noFetchNoSwitch() async throws {
        let oldVersion = "v1.19.28"
        let newVersion = "v1.19.29"
        var printed: [String] = []
        var fetchCalled = false
        var useCalled = false

        let service = KernelCheckService(
            releaseProvider: FakeReleaseProvider([fakeRelease(tag: newVersion)]),
            activeKernel: { KernelRecord(version: oldVersion, binaryPath: "/fake", addedAt: Date(), lastUsedAt: nil, isActive: true) },
            fetchKernel: { _ in fetchCalled = true },
            useKernel: { v in useCalled = true; return KernelUseResult(outcome: .switched, version: v) },
            confirmationPrompt: { _, _ in .declined },
            printLine: { printed.append($0) }
        )

        try await service.check(yes: false)

        XCTAssertFalse(fetchCalled, "Should not fetch when declined")
        XCTAssertFalse(useCalled, "Should not switch when declined")
        XCTAssert(printed.contains(where: { $0.contains("not applied") }))
    }

    func testNonTTY_withoutYes_throwsValidationFailure() async throws {
        let service = KernelCheckService(
            releaseProvider: FakeReleaseProvider([fakeRelease(tag: "v1.19.29")]),
            activeKernel: { KernelRecord(version: "v1.19.28", binaryPath: "/fake", addedAt: Date(), lastUsedAt: nil, isActive: true) },
            fetchKernel: { _ in },
            useKernel: { v in KernelUseResult(outcome: .switched, version: v) },
            confirmationPrompt: { _, yes in
                // Simulate the non-interactive throw that ConfirmationPrompt.confirm() would produce.
                if !yes {
                    throw CLIError(
                        what: "operation requires confirmation",
                        cause: "stdin is not a terminal and --yes was not passed",
                        fix: "re-run the command with --yes to confirm non-interactively",
                        exitCode: .validationFailure
                    )
                }
                return .confirmed
            },
            printLine: { _ in }
        )

        do {
            try await service.check(yes: false)
            XCTFail("Expected CLIError to be thrown")
        } catch let e as CLIError {
            XCTAssertEqual(e.exitCode, .validationFailure)
        }
    }

    func testNoActiveKernel_reportsLatestWithoutComparisonLine() async throws {
        var printed: [String] = []

        let service = KernelCheckService(
            releaseProvider: FakeReleaseProvider([fakeRelease(tag: "v1.19.29")]),
            activeKernel: { nil },
            fetchKernel: { _ in },
            useKernel: { v in KernelUseResult(outcome: .switched, version: v) },
            confirmationPrompt: { _, _ in .declined },
            printLine: { printed.append($0) }
        )

        try await service.check(yes: false)

        XCTAssert(printed.contains(where: { $0.contains("A newer stable release is available") }))
        XCTAssert(printed.contains(where: { $0.contains("No kernel is currently active") }))
    }

    func testNoStableReleaseAvailable_throwsNetworkError() async throws {
        let service = KernelCheckService(
            releaseProvider: FakeReleaseProvider([fakeRelease(tag: "v1.19.29-alpha", stable: false)]),
            activeKernel: { nil },
            fetchKernel: { _ in },
            useKernel: { v in KernelUseResult(outcome: .switched, version: v) },
            confirmationPrompt: { _, _ in .declined },
            printLine: { _ in }
        )

        do {
            try await service.check(yes: false)
            XCTFail("Expected CLIError")
        } catch let e as CLIError {
            XCTAssertEqual(e.exitCode, .networkError)
        }
    }

    func testNewerAvailable_fetchFails_propagatesError() async throws {
        let oldVersion = "v1.19.28"
        let newVersion = "v1.19.29"
        var useCalled = false
        let expectedError = CLIError(
            what: "network error",
            cause: "connection reset",
            exitCode: .networkError
        )

        let service = KernelCheckService(
            releaseProvider: FakeReleaseProvider([fakeRelease(tag: newVersion)]),
            activeKernel: { KernelRecord(version: oldVersion, binaryPath: "/fake", addedAt: Date(), lastUsedAt: nil, isActive: true) },
            fetchKernel: { _ in throw expectedError },
            useKernel: { v in useCalled = true; return KernelUseResult(outcome: .switched, version: v) },
            confirmationPrompt: { _, _ in .confirmed },
            printLine: { _ in }
        )

        do {
            try await service.check(yes: true)
            XCTFail("Expected error to propagate")
        } catch let e as CLIError {
            XCTAssertEqual(e.exitCode, .networkError)
            XCTAssertFalse(useCalled, "Should not call use when fetch fails")
        }
    }
}
