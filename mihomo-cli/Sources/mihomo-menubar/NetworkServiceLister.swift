import Foundation

/// Read-only helper for the "which network service?" picker shown when
/// `net system-proxy on` fails because more than one service is active
/// (see StatusItemController.presentInterfacePicker). Deliberately calls
/// `networksetup` directly rather than adding a new `mihomo-cli` command:
/// this only *enumerates* service names for display, it makes no judgment
/// about which one is "active" or safe to use — that determination still
/// happens exactly once, inside `mihomo-cli net system-proxy on`, when the
/// chosen `--interface` is actually applied. So this doesn't duplicate any
/// business logic, just a system listing call, the same class of read-only
/// system introspection `PortInspector` already does independently.
enum NetworkServiceLister {
    static func listAllServiceNames() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallnetworkservices"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output
            .split(separator: "\n")
            .map { String($0) }
            .filter { !$0.hasPrefix("An asterisk") } // header line
            .map { $0.hasPrefix("*") ? String($0.dropFirst()) : $0 } // "*" = disabled service, still listable
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
