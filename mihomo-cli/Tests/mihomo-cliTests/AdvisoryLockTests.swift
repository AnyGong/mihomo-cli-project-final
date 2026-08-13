import XCTest
@testable import mihomo_cli

final class AdvisoryLockTests: XCTestCase {
    var tempPath: String!

    override func setUp() {
        super.setUp()
        tempPath = NSTemporaryDirectory() + "mihomo-cli-lock-tests-\(UUID().uuidString)/lock"
    }

    override func tearDown() {
        let dir = (tempPath as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    func testAcquireAndReleaseSucceeds() throws {
        let lock = AdvisoryLock(lockFilePath: tempPath)
        XCTAssertNoThrow(try lock.acquire())
        lock.release()
    }

    func testSecondAcquireFromDifferentInstanceConflicts() throws {
        let first = AdvisoryLock(lockFilePath: tempPath)
        try first.acquire()
        defer { first.release() }

        let second = AdvisoryLock(lockFilePath: tempPath)
        XCTAssertThrowsError(try second.acquire()) { error in
            guard let cliError = error as? CLIError else {
                return XCTFail("expected CLIError, got \(error)")
            }
            XCTAssertEqual(cliError.exitCode, .conflict)
        }
    }

    func testLockIsReleasedAfterFirstInstanceReleases() throws {
        let first = AdvisoryLock(lockFilePath: tempPath)
        try first.acquire()
        first.release()

        let second = AdvisoryLock(lockFilePath: tempPath)
        XCTAssertNoThrow(try second.acquire())
        second.release()
    }

    func testWithLockReleasesEvenOnThrow() async throws {
        struct Boom: Error {}
        let lock = AdvisoryLock(lockFilePath: tempPath)

        await XCTAssertThrowsErrorAsync(try await lock.withLock {
            throw Boom()
        })

        // If withLock released properly, a fresh instance can acquire immediately.
        let second = AdvisoryLock(lockFilePath: tempPath)
        XCTAssertNoThrow(try second.acquire())
        second.release()
    }
}

// Small async-throwing assertion helper, since XCTAssertThrowsError doesn't
// have a first-class async form in older XCTest versions.
func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error to be thrown", file: file, line: line)
    } catch {
        // expected
    }
}
