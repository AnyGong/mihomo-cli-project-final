import XCTest
@testable import mihomo_cli

final class CLIErrorTests: XCTestCase {
    func testMessageFormatWithFix() {
        let err = CLIError(what: "thing failed", cause: "root cause", fix: "do this", exitCode: .validationFailure)
        XCTAssertEqual(err.description, "error: thing failed — root cause (fix: do this)")
    }

    func testMessageFormatWithoutFix() {
        let err = CLIError(what: "thing failed", cause: "root cause", exitCode: .validationFailure)
        XCTAssertEqual(err.description, "error: thing failed — root cause")
    }

    func testNoKernelRunningConvenience() {
        XCTAssertEqual(CLIError.noKernelRunning.exitCode, .permissionDenied)
    }

    func testWritesExactMessageWithoutArgumentParserPrefix() throws {
        let err = CLIError(what: "thing failed", cause: "root cause", fix: "do this", exitCode: .validationFailure)
        XCTAssertEqual(err.description, "error: thing failed — root cause (fix: do this)")
    }
}
