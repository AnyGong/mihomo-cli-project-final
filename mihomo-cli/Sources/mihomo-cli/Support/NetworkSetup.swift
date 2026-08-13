import Foundation

/// Representation of macOS web proxy status returned by `networksetup -getwebproxy`.
struct WebProxyInfo: Equatable {
    var enabled: Bool
    var server: String
    var port: Int
}

protocol NetworkSetupManaging {
    func listAllServices() throws -> [String]
    func getActiveServices() throws -> [String]
    func getWebProxy(service: String) throws -> WebProxyInfo
    func getSecureWebProxy(service: String) throws -> WebProxyInfo
    func setWebProxy(service: String, host: String, port: Int) throws
    func setWebProxyState(service: String, enabled: Bool) throws
    func setSecureWebProxy(service: String, host: String, port: Int) throws
    func setSecureWebProxyState(service: String, enabled: Bool) throws
}

final class NetworkSetup: NetworkSetupManaging {
    private let executablePath: String

    init(executablePath: String = "/usr/sbin/networksetup") {
        self.executablePath = executablePath
    }

    func listAllServices() throws -> [String] {
        let output = try run(["-listallnetworkservices"])
        return NetworkSetup.parseServiceList(output)
    }

    func getActiveServices() throws -> [String] {
        let all = try listAllServices()
        var active: [String] = []

        for service in all {
            if let info = try? run(["-getinfo", service]) {
                if NetworkSetup.isServiceActive(infoOutput: info) {
                    active.append(service)
                }
            }
        }

        return active.isEmpty ? all : active
    }

    func getWebProxy(service: String) throws -> WebProxyInfo {
        let output = try run(["-getwebproxy", service])
        return NetworkSetup.parseWebProxyOutput(output)
    }

    func getSecureWebProxy(service: String) throws -> WebProxyInfo {
        let output = try run(["-getsecurewebproxy", service])
        return NetworkSetup.parseWebProxyOutput(output)
    }

    func setWebProxy(service: String, host: String, port: Int) throws {
        _ = try run(["-setwebproxy", service, host, "\(port)"])
    }

    func setWebProxyState(service: String, enabled: Bool) throws {
        _ = try run(["-setwebproxystate", service, enabled ? "on" : "off"])
    }

    func setSecureWebProxy(service: String, host: String, port: Int) throws {
        _ = try run(["-setsecurewebproxy", service, host, "\(port)"])
    }

    func setSecureWebProxyState(service: String, enabled: Bool) throws {
        _ = try run(["-setsecurewebproxystate", service, enabled ? "on" : "off"])
    }

    // MARK: - Parsing Helpers (Static & Testable)

    static func parseServiceList(_ output: String) -> [String] {
        output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty &&
                !line.lowercased().hasPrefix("an asterisk") &&
                !line.hasPrefix("*")
            }
    }

    static func isServiceActive(infoOutput: String) -> Bool {
        let lines = infoOutput.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("ip address:") {
                let parts = trimmed.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if parts.count >= 2 {
                    let ip = parts[1]
                    if !ip.isEmpty && ip.lowercased() != "none" && ip != "0.0.0.0" {
                        return true
                    }
                }
            }
        }
        return false
    }

    static func parseWebProxyOutput(_ output: String) -> WebProxyInfo {
        var enabled = false
        var server = ""
        var port = 0

        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()

            if lower.hasPrefix("enabled:") {
                let val = trimmed.dropFirst("enabled:".count).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                enabled = (val == "yes" || val == "1")
            } else if lower.hasPrefix("server:") {
                server = String(trimmed.dropFirst("server:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if lower.hasPrefix("port:") {
                let val = trimmed.dropFirst("port:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                port = Int(val) ?? 0
            }
        }

        return WebProxyInfo(enabled: enabled, server: server, port: port)
    }

    // MARK: - Execution

    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CLIError(
                what: "networksetup failed",
                cause: error.localizedDescription,
                exitCode: .permissionDenied
            )
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let cause = errStr.isEmpty ? "exit status \(process.terminationStatus)" : errStr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(
                what: "networksetup command failed",
                cause: cause,
                fix: "check network service name and administrator permissions",
                exitCode: .permissionDenied
            )
        }

        return output
    }
}
