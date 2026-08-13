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
            try await NetService().status(json: json)
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
                try await NetService().systemProxyOn(interface: interface, yes: yes)
            }
        }

        struct Off: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "off")

            func run() async throws {
                try await NetService().systemProxyOff()
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
                try await NetService().tunOn(yes: yes)
            }
        }

        struct Off: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "off")

            func run() async throws {
                try await NetService().tunOff()
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
                try await NetService().proxyModeOn(port: port)
            }
        }

        struct Off: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "off")

            func run() async throws {
                try await NetService().proxyModeOff()
            }
        }
    }

    struct Off: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "off", abstract: "Deactivate whichever network mode is currently active.")

        func run() async throws {
            try await NetService().off()
        }
    }
}
