import Foundation
import Darwin

struct KernelLaunchRequest {
    let binaryPath: String
    let configURL: URL
    let workDirectory: URL
    let stdoutURL: URL
    let stderrURL: URL
}

struct KernelLaunchResult: Equatable {
    let pid: Int32
}

protocol KernelProcessControlling {
    func start(_ request: KernelLaunchRequest) throws -> KernelLaunchResult
    func stop(pid: Int32, timeout: TimeInterval) async throws
    func isRunning(pid: Int32) -> Bool
}

final class ProcessController: KernelProcessControlling {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func start(_ request: KernelLaunchRequest) throws -> KernelLaunchResult {
        let logDirectory = request.stdoutURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !fileManager.fileExists(atPath: request.stdoutURL.path) {
            fileManager.createFile(atPath: request.stdoutURL.path, contents: nil)
        }
        if !fileManager.fileExists(atPath: request.stderrURL.path) {
            fileManager.createFile(atPath: request.stderrURL.path, contents: nil)
        }

        guard let stdout = FileHandle(forWritingAtPath: request.stdoutURL.path),
              let stderr = FileHandle(forWritingAtPath: request.stderrURL.path) else {
            throw CLIError(
                what: "could not prepare kernel log files",
                cause: "stdout/stderr files under \(logDirectory.path) could not be opened",
                fix: "check permissions on \(logDirectory.path)",
                exitCode: .permissionDenied
            )
        }
        try stdout.seekToEnd()
        try stderr.seekToEnd()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.binaryPath)
        process.arguments = ["-f", request.configURL.path, "-d", request.workDirectory.path]
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            try? stdout.close()
            try? stderr.close()
            throw CLIError(
                what: "could not start kernel process",
                cause: error.localizedDescription,
                fix: "check the kernel binary path and permissions",
                exitCode: .sourceVerificationFailure
            )
        }

        try? stdout.close()
        try? stderr.close()
        return KernelLaunchResult(pid: process.processIdentifier)
    }

    func stop(pid: Int32, timeout: TimeInterval = 5.0) async throws {
        guard isRunning(pid: pid) else { return }
        Darwin.kill(pid, SIGTERM)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning(pid: pid) { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        Darwin.kill(pid, SIGKILL)
    }

    func isRunning(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return Darwin.kill(pid, 0) == 0 || errno == EPERM
    }
}
