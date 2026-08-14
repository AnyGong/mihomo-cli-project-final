import Foundation

struct CLIResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

enum CLIBridgeError: Error, CustomStringConvertible {
    case binaryNotFound

    var description: String {
        switch self {
        case .binaryNotFound:
            return "could not locate the mihomo-cli executable (set MIHOMO_CLI_PATH, or build it alongside mihomo-menubar)"
        }
    }
}

/// Runs `mihomo-cli` subcommands out-of-process and reports back what
/// happened, without interpreting or duplicating any of the CLI's own
/// business logic (locking, atomic switch, rollback, liveness checks all
/// still happen exactly once, inside the CLI process — see Package.swift).
final class CLIBridge {
    private let cliPath: String?

    init(cliPath: String? = CLILocator.resolve()) {
        self.cliPath = cliPath
    }

    var isAvailable: Bool { cliPath != nil }

    /// Runs `mihomo-cli <arguments>` and returns its exit code + captured
    /// output. Never throws for a non-zero exit — callers inspect
    /// `CLIResult.succeeded` and `stderr` themselves, mirroring how the CLI's
    /// own error format (`error: <what> — <why> (<fix>)`) is meant to be
    /// read directly by a human, or in this case shown in a menu-bar alert.
    @discardableResult
    func run(_ arguments: [String]) async throws -> CLIResult {
        guard let cliPath else { throw CLIBridgeError.binaryNotFound }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = arguments

            // Deliberately detached from any real terminal: without this,
            // the child inherits whatever stdin this app itself happens to
            // have (a real TTY if launched from a Terminal session running
            // `swift run`/the built binary directly), which makes
            // `isatty(STDIN_FILENO)` true inside mihomo-cli and routes it
            // into an *interactive* confirmation prompt (e.g. "multiple
            // active network services found" in `net system-proxy on`) that
            // then reads from a stdin nobody is typing into — producing a
            // spurious `error: invalid selection — selected index out of
            // range` instead of the clean non-interactive failure message
            // (AI.md §3 convention #12 expects exactly that fail-closed
            // path, not this). Pinning stdin to /dev/null makes every
            // invocation deterministically non-interactive, matching how
            // this app always passes `--yes`/`--force` itself rather than
            // ever answering a prompt.
            process.standardInput = FileHandle.nullDevice

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            process.terminationHandler = { proc in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let result = CLIResult(
                    exitCode: proc.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                )
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Convenience for read commands that support `--json`: runs the
    /// command and parses stdout as a JSON value. Returns `nil` (rather than
    /// throwing) on any failure — status polling should degrade to "unknown"
    /// in the menu rather than surface an alert every few seconds.
    func runJSON(_ arguments: [String]) async -> Any? {
        guard let result = try? await run(arguments), result.succeeded else { return nil }
        guard let data = result.stdout.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
