import Foundation
import Darwin

/// Testable service for `kernel status` output.
/// Queries the running kernel's state from MetadataStore and then attempts
/// a live control-API call to confirm responsiveness.
final class KernelStatusService {

    // MARK: - Injectable dependencies

    private let activeKernel: () async throws -> KernelRecord?
    private let runningKernel: () async throws -> RunningKernelState?
    private let daemonState: () async throws -> DaemonState
    private let controlAPICredentials: () async throws -> ControlAPICredentials?
    private let clientFactory: (ControlAPICredentials) -> KernelClient
    private let isProcessRunning: (Int32) -> Bool
    private let now: () -> Date

    init(
        activeKernel: @escaping () async throws -> KernelRecord? = {
            try await MetadataStore.shared.activeKernel()
        },
        runningKernel: @escaping () async throws -> RunningKernelState? = {
            try await MetadataStore.shared.runningKernel()
        },
        daemonState: @escaping () async throws -> DaemonState = {
            try await MetadataStore.shared.daemonState()
        },
        controlAPICredentials: @escaping () async throws -> ControlAPICredentials? = {
            try await MetadataStore.shared.controlAPICredentials()
        },
        clientFactory: @escaping (ControlAPICredentials) -> KernelClient = {
            HTTPKernelClient(port: $0.port, secret: $0.secret)
        },
        isProcessRunning: @escaping (Int32) -> Bool = { pid in
            pid > 0 && (Darwin.kill(pid, 0) == 0 || errno == EPERM)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.activeKernel = activeKernel
        self.runningKernel = runningKernel
        self.daemonState = daemonState
        self.controlAPICredentials = controlAPICredentials
        self.clientFactory = clientFactory
        self.isProcessRunning = isProcessRunning
        self.now = now
    }

    // MARK: - Output models

    struct StatusReport {
        enum APIHealth {
            case responsive(host: String, port: Int)
            case unresponsive(host: String, port: Int)
        }

        let version: String?
        let pid: Int32?
        let isProcessRunning: Bool
        let startedAt: Date?
        let apiHealth: APIHealth?
        let supervised: Bool
        let activeKernelVersion: String?
    }

    // MARK: - Public API

    /// Collects status information and returns a `StatusReport`.
    func report() async throws -> StatusReport {
        let running = try await runningKernel()
        let daemon = try await daemonState()
        let active = try await activeKernel()

        guard let running else {
            return StatusReport(
                version: nil,
                pid: nil,
                isProcessRunning: false,
                startedAt: nil,
                apiHealth: nil,
                supervised: daemon.installed,
                activeKernelVersion: active?.version
            )
        }

        let processRunning = isProcessRunning(running.pid)

        // Attempt a live control-API call to check responsiveness.
        var apiHealth: StatusReport.APIHealth?
        if let creds = try await controlAPICredentials() {
            let client = clientFactory(creds)
            let host = "127.0.0.1"
            let port = creds.port
            do {
                _ = try await client.version()
                apiHealth = .responsive(host: host, port: port)
            } catch {
                apiHealth = .unresponsive(host: host, port: port)
            }
        }

        return StatusReport(
            version: running.version,
            pid: running.pid,
            isProcessRunning: processRunning,
            startedAt: running.startedAt,
            apiHealth: apiHealth,
            supervised: daemon.installed,
            activeKernelVersion: active?.version
        )
    }

    // MARK: - Formatting helpers

    /// Human-readable table output matching the spec's format.
    static func humanOutput(from report: StatusReport) -> String {
        var lines: [String] = []

        guard let version = report.version, let pid = report.pid else {
            lines.append("Status:        not running")
            lines.append("Note:          run 'mihomo start' or 'mihomo kernel use <version>' to launch one.")
            return lines.joined(separator: "\n")
        }

        let processStatus = report.isProcessRunning
            ? "running (pid \(pid))"
            : "not responding (was running as pid \(pid))"

        lines.append("Version:       \(version)")
        lines.append("Status:        \(processStatus)")

        if let startedAt = report.startedAt {
            let elapsed = Date().timeIntervalSince(startedAt)
            lines.append("Uptime:        \(formatUptime(elapsed))")
        }

        switch report.apiHealth {
        case .responsive(let host, let port):
            lines.append("Control API:   responsive (\(host):\(port))")
        case .unresponsive(let host, let port):
            lines.append("Control API:   unreachable (\(host):\(port))")
        case nil:
            lines.append("Control API:   unknown (no credentials stored)")
        }

        let supervisedText = report.supervised ? "yes (launchd agent active)" : "no"
        lines.append("Supervised:    \(supervisedText)")

        return lines.joined(separator: "\n")
    }

    /// JSON-encodable representation for `--json` output.
    struct StatusJSON: Encodable {
        let version: String?
        let status: String
        let pid: Int32?
        let uptimeSeconds: Double?
        let controlAPIResponsive: Bool?
        let controlAPIAddress: String?
        let supervised: Bool
    }

    static func jsonOutput(from report: StatusReport) throws -> String {
        let status: String
        let uptime: Double?

        if let startedAt = report.startedAt {
            uptime = Date().timeIntervalSince(startedAt)
        } else {
            uptime = nil
        }

        if report.version == nil {
            status = "not_running"
        } else if report.isProcessRunning {
            status = "running"
        } else {
            status = "not_responding"
        }

        var apiResponsive: Bool?
        var apiAddress: String?
        switch report.apiHealth {
        case .responsive(let host, let port):
            apiResponsive = true
            apiAddress = "\(host):\(port)"
        case .unresponsive(let host, let port):
            apiResponsive = false
            apiAddress = "\(host):\(port)"
        case nil:
            break
        }

        let obj = StatusJSON(
            version: report.version,
            status: status,
            pid: report.pid,
            uptimeSeconds: uptime,
            controlAPIResponsive: apiResponsive,
            controlAPIAddress: apiAddress,
            supervised: report.supervised
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(obj)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Private helpers

    private static func formatUptime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "\(total)s"
        }
    }
}
