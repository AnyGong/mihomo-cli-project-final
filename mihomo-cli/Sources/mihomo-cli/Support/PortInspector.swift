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
        // `ifconfig -l` only lists interface *names*, and macOS pre-allocates
        // several idle utun slots at boot for its own frameworks (Continuity,
        // Personal Hotspot, etc.) even with zero VPNs ever configured — so a
        // presence-only check false-positives on nearly every Mac and
        // permanently blocks Tun mode. `-a` gives flags + assigned addresses
        // per interface, which is what's actually needed to tell an idle
        // slot apart from a live tunnel.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = ["-a"]

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
        return PortInspector.hasActiveUtunTunnel(ifconfigOutput: output)
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

    /// Parses `ifconfig -a` output (block-per-interface, continuation lines
    /// indented) and reports whether any `utun*` interface is both `UP` and
    /// carries a real address — the actual signature of a live VPN tunnel.
    ///
    /// Idle, macOS-preallocated utun slots are frequently `UP,RUNNING` too,
    /// but sit with either no address at all or only an auto-assigned
    /// link-local IPv6 (`fe80::...%utunN`), so `UP` alone is not sufficient —
    /// this deliberately requires an address, and excludes link-local IPv6,
    /// to avoid the same false-positive the name-only check had.
    static func hasActiveUtunTunnel(ifconfigOutput: String) -> Bool {
        var currentIsUtun = false
        var currentIsUp = false
        var currentHasRoutableAddress = false
        var foundActive = false

        func flushCurrentInterface() {
            if currentIsUtun && currentIsUp && currentHasRoutableAddress {
                foundActive = true
            }
        }

        for rawLine in ifconfigOutput.components(separatedBy: .newlines) {
            guard !rawLine.isEmpty else { continue }

            let isContinuationLine = rawLine.hasPrefix(" ") || rawLine.hasPrefix("\t")
            if !isContinuationLine {
                // New interface header, e.g. "utun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500"
                flushCurrentInterface()

                let name = rawLine.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
                currentIsUtun = name.lowercased().hasPrefix("utun")
                currentHasRoutableAddress = false

                if let flagsRange = rawLine.range(of: "<"),
                   let flagsEnd = rawLine.range(of: ">", range: flagsRange.upperBound..<rawLine.endIndex) {
                    let flags = rawLine[flagsRange.upperBound..<flagsEnd.lowerBound]
                    currentIsUp = flags.split(separator: ",").contains("UP")
                } else {
                    currentIsUp = false
                }
                continue
            }

            guard currentIsUtun else { continue }
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let kind = tokens.first else { continue }

            if kind == "inet" {
                // Any IPv4 address on a utun interface is a real assigned
                // tunnel endpoint — utun interfaces don't get IPv4 by default.
                currentHasRoutableAddress = true
            } else if kind == "inet6", tokens.count > 1 {
                let address = tokens[1]
                if !address.lowercased().hasPrefix("fe80") {
                    currentHasRoutableAddress = true
                }
            }
        }
        flushCurrentInterface()

        return foundActive
    }
}
