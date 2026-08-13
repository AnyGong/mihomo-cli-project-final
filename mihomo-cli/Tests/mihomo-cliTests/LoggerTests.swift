import XCTest
@testable import mihomo_cli

final class LoggerTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testLogWritingAndLevelFiltering() throws {
        let fixedDate = Date(timeIntervalSince1970: 1786500000)
        let logger = AppLogger(logsDirectory: tempDir, maxFileSize: 1024, maxRotatedFiles: 3, now: { fixedDate })

        logger.info("kernel: switched to v1.19.10")
        logger.warning("net: system proxy overwritten")
        logger.error("kernel: process exited unexpectedly")

        let allLogs = try logger.queryLogs(minLevel: nil, json: false)
        XCTAssertEqual(allLogs.count, 3)

        let warningsAndErrors = try logger.queryLogs(minLevel: .warning, json: false)
        XCTAssertEqual(warningsAndErrors.count, 2)
        XCTAssertFalse(warningsAndErrors.contains(where: { $0.contains("[info]") }))

        let errorsOnly = try logger.queryLogs(minLevel: .error, json: false)
        XCTAssertEqual(errorsOnly.count, 1)
        XCTAssertTrue(errorsOnly.first?.contains("[error]") ?? false)
    }

    func testLogRotation() throws {
        // Max file size: 100 bytes
        let logger = AppLogger(logsDirectory: tempDir, maxFileSize: 100, maxRotatedFiles: 10)

        for i in 1...10 {
            logger.info("This is a moderately long log message #\(i) intended to trigger rotation")
        }

        // Must have rotated into app.log.1
        let rot1 = tempDir.appendingPathComponent("app.log.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rot1.path))

        // queryLogs reads across all rotated files
        let logs = try logger.queryLogs(minLevel: nil, json: false)
        XCTAssertGreaterThan(logs.count, 5)
    }

    func testAuditLogRecordingAndQuerying() throws {
        let fixedDate = Date(timeIntervalSince1970: 1786500000)
        let logger = AppLogger(logsDirectory: tempDir, now: { fixedDate })

        logger.recordAudit(action: "kernel.use", target: "v1.19.10", result: "success")
        logger.recordAudit(action: "sub.switch", target: "work-vpn", result: "rolled-back")
        logger.recordAudit(action: "net.system-proxy", target: "Wi-Fi", result: "success")

        let allAudit = try logger.queryAudit(since: nil, actionFilter: nil, json: false)
        XCTAssertEqual(allAudit.count, 3)

        let kernelAudit = try logger.queryAudit(since: nil, actionFilter: "kernel", json: false)
        XCTAssertEqual(kernelAudit.count, 1)
        XCTAssertTrue(kernelAudit.first?.contains("kernel.use") ?? false)

        let jsonAudit = try logger.queryAudit(since: nil, actionFilter: nil, json: true)
        XCTAssertEqual(jsonAudit.count, 3)
        XCTAssertTrue(jsonAudit.first?.contains("\"action\":\"kernel.use\"") ?? false)
    }

    func testParseSinceRelative() {
        let now = Date(timeIntervalSince1970: 1786500000)
        let d7 = AppLogger.parseSince("7d", now: { now })
        XCTAssertEqual(d7, now.addingTimeInterval(-7 * 86400))

        let h24 = AppLogger.parseSince("24h", now: { now })
        XCTAssertEqual(h24, now.addingTimeInterval(-24 * 3600))
    }
}
