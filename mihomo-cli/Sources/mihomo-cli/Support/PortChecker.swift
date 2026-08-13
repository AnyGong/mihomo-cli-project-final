import Foundation
import Darwin

protocol PortChecking {
    func isPortAvailable(_ port: Int) -> Bool
    func waitUntilAvailable(_ port: Int, timeout: TimeInterval) async -> Bool
}

final class LoopbackPortChecker: PortChecking {
    func isPortAvailable(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result != 0
    }

    func waitUntilAvailable(_ port: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isPortAvailable(port) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return isPortAvailable(port)
    }
}
