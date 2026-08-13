import Foundation
import Darwin

/// Result of a confirmation prompt.
enum PromptResult {
    case confirmed
    case declined
}

/// Shared confirmation-prompt helper, per AI.md §3.12 (non-interactive/non-TTY
/// output policy). Every command with a `[y/N]`-style prompt must call this
/// rather than duplicating TTY-detection logic ad hoc.
///
/// Behaviour:
/// - `yes == true`: returns `.confirmed` immediately (no I/O).
/// - Non-interactive context (stdin is not a TTY): throws a `CLIError` with
///   exit code `.validationFailure`, explaining that `--yes` is required.
///   Never blocks waiting for input that will never arrive.
/// - Interactive TTY: prints `question` followed by ` [y/N] `, reads one line,
///   returns `.confirmed` on "y"/"Y", `.declined` on anything else (including
///   empty — the default is No).
func confirm(_ question: String, yes: Bool) throws -> PromptResult {
    if yes {
        return .confirmed
    }

    guard isatty(STDIN_FILENO) != 0 else {
        throw CLIError(
            what: "operation requires confirmation",
            cause: "stdin is not a terminal and --yes was not passed",
            fix: "re-run the command with --yes to confirm non-interactively",
            exitCode: .validationFailure
        )
    }

    print("\(question) [y/N] ", terminator: "")
    let response = readLine(strippingNewline: true) ?? ""
    return (response == "y" || response == "Y") ? .confirmed : .declined
}
