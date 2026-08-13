import Foundation

/// Information about a process listening on a port.
struct ProcessPortInfo: Equatable {
    let pid: Int32
    let command: String
}

protocol PortInspecting {
    func findProcessUsingPort(_ port: Int) throws -> ProcessPortInfo?
    func isUtunInterfacePresent() -> Bool
}

final class PortInspector: PortInspecting {

    func findProcessUsingPort(_ port: Int) throws -> ProcessPortInfo? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-i", ":\(port)", "-sTCP:LISTEN", "-n", "-P"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return PortInspector.parseLsofOutput(output)
    }

    func isUtunInterfacePresent() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = ["-l"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let interfaces = output.components(separatedBy: .whitespacesAndNewlines)
        return interfaces.contains(where: { $0.lowercased().hasPrefix("utun") })
    }

    // MARK: - Parsing Helpers (Static & Testable)

    static func parseLsofOutput(_ output: String) -> ProcessPortInfo? {
        let lines = output.components(separatedBy: .newlines)
        guard lines.count > 1 else { return nil }

        for line in lines.dropFirst() {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if tokens.count >= 2 {
                let command = tokens[0]
                if let pid = Int32(tokens[1]) {
                    return ProcessPortInfo(pid: pid, command: command)
                }
            }
        }
        return nil
    }
}
