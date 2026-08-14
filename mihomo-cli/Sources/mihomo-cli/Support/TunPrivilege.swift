import Foundation

/// Manages the one-time privileged setup required for Tun mode.
///
/// The hardware spike (`scripts/tun_privilege_spike.sh`,
/// `docs/mihomo_tun_privilege_spike_guide.md`) confirmed that unprivileged
/// `utun` creation fails with "Operation not permitted" and that a
/// `sudo`-elevated launch of the mihomo binary succeeds. This type is
/// responsible for:
///
///  1. Detecting whether entitlement is currently usable — either because
///     the optional scoped `sudoers.d` NOPASSWD rule from the spike guide is
///     installed, or because a prior `acquireEntitlement()` call in this
///     terminal session already warmed sudo's timestamp cache.
///  2. If not, running an interactive `sudo -v` connected directly to this
///     CLI's own stdin/stdout/stderr, so the password prompt goes to the
///     real terminal rather than being lost to redirected process I/O.
///
/// `hasEntitlement()` uses `sudo -n true` rather than reading `/etc/sudoers.d`
/// directly, so it correctly reports "usable" in both cases above without
/// needing to parse sudoers syntax or care which mechanism is in effect.
protocol TunPrivilegeManaging {
    func hasEntitlement() -> Bool
    func acquireEntitlement() throws
}

final class TunPrivilege: TunPrivilegeManaging {
    private let sudoPath: String
    private let truePath: String

    init(sudoPath: String = "/usr/bin/sudo", truePath: String = "/usr/bin/true") {
        self.sudoPath = sudoPath
        self.truePath = truePath
    }

    /// True if `sudo -n true` succeeds non-interactively. This is the only
    /// reliable way to answer "would an elevated launch work right now
    /// without prompting" — it's true whether the NOPASSWD sudoers.d rule
    /// is present, or whether `acquireEntitlement()` already ran recently
    /// enough that sudo's own timestamp cache is still valid.
    func hasEntitlement() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sudoPath)
        process.arguments = ["-n", truePath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Runs `sudo -v` wired directly to this process's own terminal file
    /// descriptors so the password prompt is visible and readable, priming
    /// sudo's timestamp cache. Subsequent elevated launches (which redirect
    /// their own stdout/stderr to log files) can then authenticate against
    /// that cached ticket without needing tty access themselves.
    ///
    /// Fails closed (per the non-interactive policy in AI.md §3.12) if
    /// stdin isn't a TTY and no NOPASSWD rule is already in effect — there
    /// is nowhere to prompt.
    func acquireEntitlement() throws {
        if hasEntitlement() {
            return
        }

        guard isatty(STDIN_FILENO) != 0 else {
            throw CLIError(
                what: "Tun mode unavailable",
                cause: "privileged setup requires an interactive terminal, and no NOPASSWD sudoers rule is installed",
                fix: "run 'mihomo net tun on' from an interactive terminal once, or install the scoped rule from docs/mihomo_tun_privilege_spike_guide.md",
                exitCode: .privilegeError
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sudoPath)
        process.arguments = ["-v"]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CLIError(
                what: "Tun mode unavailable",
                cause: "could not invoke sudo: \(error.localizedDescription)",
                exitCode: .privilegeError
            )
        }

        guard process.terminationStatus == 0 else {
            throw CLIError(
                what: "Tun mode unavailable",
                cause: "sudo authentication failed or was declined",
                exitCode: .privilegeError
            )
        }
    }
}
