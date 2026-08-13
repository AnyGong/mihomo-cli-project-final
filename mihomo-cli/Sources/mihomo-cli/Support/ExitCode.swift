import Foundation

/// Mirrors the exit-code table defined in every command-group spec
/// (see mihomo_sub_command_spec.md §Global conventions, extended by
/// mihomo_net_command_spec.md and mihomo_kernel_command_spec.md).
///
/// Every command handler should exit through `CLIError` below rather than
/// calling `exit()` directly, so the mapping stays centralized in one place.
enum MihomoExitCode: Int32 {
    case success = 0
    case validationFailure = 1
    case permissionDenied = 2
    case notFound = 3
    case conflict = 4
    case networkError = 5
    case privilegeError = 6      // net group: Tun entitlement / sudo declined
    case portUnavailable = 7     // net group: port or interface unavailable
    case sourceVerificationFailure = 8 // kernel group: download didn't resolve to an official
                                        // release asset, or the on-disk binary is missing/zero-length.
                                        // No SHA256 verification is performed — the official
                                        // upstream repository over HTTPS is the trust boundary.
    case interrupted = 130       // Ctrl-C
}
