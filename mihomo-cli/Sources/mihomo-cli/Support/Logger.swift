import Foundation

enum LogLevel: String, Codable, Comparable {
    case info = "info"
    case warning = "warning"
    case error = "error"

    private var priority: Int {
        switch self {
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.priority < rhs.priority
    }
}

struct LogEntry: Codable {
    let timestamp: Date
    let level: LogLevel
    let message: String
}

struct AuditRecord: Codable, Equatable {
    let timestamp: Date
    let action: String
    let target: String
    let result: String
}

final class AppLogger {

    static let shared = AppLogger()

    private let logsDirectory: URL
    private let maxFileSize: Int64
    private let maxRotatedFiles: Int
    private let now: () -> Date
    private let lock = NSLock()

    init(
        logsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mihomo-cli/logs"),
        maxFileSize: Int64 = 5 * 1024 * 1024,
        maxRotatedFiles: Int = 5,
        now: @escaping () -> Date = Date.init
    ) {
        self.logsDirectory = logsDirectory
        self.maxFileSize = maxFileSize
        self.maxRotatedFiles = maxRotatedFiles
        self.now = now
    }

    var appLogURL: URL { logsDirectory.appendingPathComponent("app.log") }
    var auditLogURL: URL { logsDirectory.appendingPathComponent("audit.log") }

    // MARK: - App Logging

    func log(level: LogLevel, message: String) {
        lock.lock()
        defer { lock.unlock() }

        let date = now()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let dateStr = formatter.string(from: date)

        let paddedLevel: String
        switch level {
        case .info: paddedLevel = "[info]   "
        case .warning: paddedLevel = "[warning]"
        case .error: paddedLevel = "[error]  "
        }

        let line = "\(dateStr) \(paddedLevel) \(message)\n"
        ensureDirectoryExists()
        rotateIfNeeded(fileURL: appLogURL)
        appendString(line, to: appLogURL)
    }

    func info(_ message: String) { log(level: .info, message: message) }
    func warning(_ message: String) { log(level: .warning, message: message) }
    func error(_ message: String) { log(level: .error, message: message) }

    // MARK: - Audit Logging

    func recordAudit(action: String, target: String, result: String) {
        lock.lock()
        defer { lock.unlock() }

        let record = AuditRecord(timestamp: now(), action: action, target: target, result: result)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record),
              let jsonLine = String(data: data, encoding: .utf8) else {
            return
        }

        ensureDirectoryExists()
        appendString(jsonLine + "\n", to: auditLogURL)
    }

    // MARK: - Query Logs

    func queryLogs(minLevel: LogLevel?, json: Bool) throws -> [String] {
        var filesToRead: [URL] = []
        for i in stride(from: maxRotatedFiles, through: 1, by: -1) {
            let rot = logsDirectory.appendingPathComponent("app.log.\(i)")
            if FileManager.default.fileExists(atPath: rot.path) {
                filesToRead.append(rot)
            }
        }
        if FileManager.default.fileExists(atPath: appLogURL.path) {
            filesToRead.append(appLogURL)
        }

        var lines: [String] = []
        for file in filesToRead {
            if let content = try? String(contentsOf: file, encoding: .utf8) {
                let fileLines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
                lines.append(contentsOf: fileLines)
            }
        }

        let filtered = lines.filter { line in
            guard let minLvl = minLevel else { return true }
            if line.contains("[error]") { return true }
            if line.contains("[warning]") { return minLvl <= .warning }
            if line.contains("[info]") { return minLvl <= .info }
            return true
        }

        if json {
            return filtered.map { line in
                let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                let dateStr = parts.count > 0 ? String(parts[0]) : ""
                let timeStr = parts.count > 1 ? String(parts[1]) : ""
                let lvlStr = parts.count > 2 ? String(parts[2]).replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "") : "info"
                let msg = parts.count > 3 ? String(parts[3]) : ""
                return "{\"timestamp\":\"\(dateStr) \(timeStr)\",\"level\":\"\(lvlStr)\",\"message\":\"\(msg)\"}"
            }
        }

        return filtered
    }

    // MARK: - Query Audit

    func queryAudit(since: String?, actionFilter: String?, json: Bool) throws -> [String] {
        guard FileManager.default.fileExists(atPath: auditLogURL.path),
              let content = try? String(contentsOf: auditLogURL, encoding: .utf8) else {
            return []
        }

        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601

        var records: [AuditRecord] = []
        let rawLines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        for line in rawLines {
            if let data = line.data(using: .utf8),
               let record = try? jsonDecoder.decode(AuditRecord.self, from: data) {
                records.append(record)
            }
        }

        let cutoffDate = AppLogger.parseSince(since, now: now)

        let filtered = records.filter { record in
            if let cutoff = cutoffDate, record.timestamp < cutoff {
                return false
            }
            if let act = actionFilter, !record.action.lowercased().contains(act.lowercased()) {
                return false
            }
            return true
        }

        if json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            return filtered.compactMap {
                (try? encoder.encode($0)).flatMap { String(data: $0, encoding: .utf8) }
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        return filtered.map { rec in
            let dateStr = formatter.string(from: rec.timestamp)
            let actionPadded = rec.action.padding(toLength: 14, withPad: " ", startingAt: 0)
            let targetPadded = "target=\(rec.target)".padding(toLength: 22, withPad: " ", startingAt: 0)
            return "\(dateStr)  \(actionPadded) \(targetPadded) result=\(rec.result)"
        }
    }

    // MARK: - Helpers

    static func parseSince(_ since: String?, now: () -> Date) -> Date? {
        guard let s = since?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        let lower = s.lowercased()
        if lower.hasSuffix("d"), let days = Double(lower.dropLast()) {
            return now().addingTimeInterval(-days * 86400)
        }
        if lower.hasSuffix("h"), let hours = Double(lower.dropLast()) {
            return now().addingTimeInterval(-hours * 3600)
        }
        if lower.hasSuffix("m"), let minutes = Double(lower.dropLast()) {
            return now().addingTimeInterval(-minutes * 60)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: s)
    }

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }

    private func appendString(_ text: String, to url: URL) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func rotateIfNeeded(fileURL: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int64,
              size >= maxFileSize else {
            return
        }

        // Shift app.log.4 -> app.log.5, etc.
        for i in stride(from: maxRotatedFiles - 1, through: 1, by: -1) {
            let src = logsDirectory.appendingPathComponent("app.log.\(i)")
            let dst = logsDirectory.appendingPathComponent("app.log.\(i + 1)")
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.moveItem(at: src, to: dst)
            }
        }

        let dst1 = logsDirectory.appendingPathComponent("app.log.1")
        try? FileManager.default.removeItem(at: dst1)
        try? FileManager.default.moveItem(at: fileURL, to: dst1)
    }
}
