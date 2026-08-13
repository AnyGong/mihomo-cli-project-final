import Foundation

/// Implements the message format mandated across all command specs:
///   "error: <what failed> — <root cause> (<suggested fix>)"
///
/// `what`/`cause` are required; `fix` is optional since some errors
/// (e.g. an aborted-and-rolled-back atomic switch) print their own
/// multi-line follow-up instead of a single parenthetical.
struct CLIError: Error, CustomStringConvertible {
    let what: String
    let cause: String
    let fix: String?
    let exitCode: MihomoExitCode

    init(what: String, cause: String, fix: String? = nil, exitCode: MihomoExitCode) {
        self.what = what
        self.cause = cause
        self.fix = fix
        self.exitCode = exitCode
    }

    var description: String {
        if let fix {
            return "error: \(what) — \(cause) (fix: \(fix))"
        }
        return "error: \(what) — \(cause)"
    }

    func writeToStandardError() {
        let stderr = FileHandle.standardError
        stderr.write(Data((description + "\n").utf8))
    }
}

/// Convenience for the extremely common "no kernel running" guard used by
/// net, mode, kernel status/use, daemon status, and doctor.
extension CLIError {
    static let noKernelRunning = CLIError(
        what: "no kernel running",
        cause: "operation requires an active kernel",
        fix: "run 'mihomo start' first",
        exitCode: .permissionDenied
    )
}
