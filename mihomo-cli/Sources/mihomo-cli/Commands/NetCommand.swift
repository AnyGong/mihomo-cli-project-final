import ArgumentParser
import Foundation

/// `mihomo net ...` — see mihomo_net_command_spec.md for full behavior.
/// The three modes (system-proxy, tun, proxy-mode) are mutually exclusive;
/// activating one deactivates whichever was previously active.
struct NetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "net",
        abstract: "Switch network runtime mode (system proxy / Tun / port-based).",
        subcommands: [Status.self, SystemProxy.self, Tun.self, ProxyMode.self, Off.self]
    )

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status", abstract: "Show current network mode.")

        @Flag(help: "Emit machine-readable JSON instead of formatted text.")
        var json = false

        func run() async throws {
            throw stub("net status") // TODO: mode, interface/port, since-timestamp, daemon supervision
        }
    }

    struct SystemProxy: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "system-proxy",
            abstract: "Toggle macOS system proxy.",
            subcommands: [On.self, Off.self]
        )

        struct On: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "on")

            @Option(help: "Network service name to target (e.g. 'Wi-Fi'). Prompted if ambiguous and omitted.")
            var interface: String?

            @Flag(help: "Auto-confirm overwriting a conflicting proxy set by another app.")
            var yes = false

            func run() async throws {
                // TODO: enumerate `networksetup -listallnetworkservices`, filter to
                // active-link services, single-match auto-target or prompt on
                // multiple (exit 1 non-interactively without --interface).
                // Conflicting-proxy detection via `networksetup -getwebproxy`
                // before overwrite. Liveness check via a real request through
                // the new proxy before persisting (design doc §4.1.1).
                throw stub("net system-proxy on")
            }
        }

        struct Off: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "off")

            func run() async throws {
                // TODO: revert only settings this tool applied (tracked from `on`);
                // warn if current OS state doesn't match what was last set.
                throw stub("net system-proxy off")
            }
        }
    }

    struct Tun: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "tun",
            abstract: "Toggle Tun mode (virtual interface, hijacks all system traffic).",
            subcommands: [On.self, Off.self]
        )

        struct On: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "on")

            @Flag(help: "Auto-confirm the one-time privileged entitlement setup prompt.")
            var yes = false

            func run() async throws {
                // TODO: check entitlement status (§2.3); if absent, one-time
                // authenticated setup step (exit .privilegeError if declined).
                // Pre-detect utun conflicts / port conflicts (§4.1.3).
                // Rollback on liveness failure must tear down any partially
                // created interface — no orphaned utun devices.
                throw stub("net tun on")
            }
        }

        struct Off: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "off")

            func run() async throws {
                // TODO: idempotent — exit 0 "nothing to do" if not active.
                throw stub("net tun off")
            }
        }
    }

    struct ProxyMode: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "proxy-mode",
            abstract: "Toggle port-based proxy forwarding.",
            subcommands: [On.self, Off.self]
        )

        struct On: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "on")

            @Option(help: "Port to bind (defaults to the kernel's configured mixed-port for this session only).")
            var port: Int?

            func run() async throws {
                // TODO: port pre-check with process attribution via `lsof -i :<port>`
                // where permissions allow (exit .portUnavailable on conflict).
                throw stub("net proxy-mode on")
            }
        }

        struct Off: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "off")

            func run() async throws {
                throw stub("net proxy-mode off")
            }
        }
    }

    struct Off: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "off", abstract: "Deactivate whichever network mode is currently active.")

        func run() async throws {
            // TODO: idempotent convenience wrapper — no-op with exit 0 if none active.
            throw stub("net off")
        }
    }
}

private func stub(_ command: String) -> CLIError {
    CLIError(what: "not implemented", cause: "'\(command)' is a scaffold stub", exitCode: .permissionDenied)
}
