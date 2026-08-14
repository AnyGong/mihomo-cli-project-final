import Foundation

/// Outbound (rule) mode as shown in the menu bar. Named to match the
/// requirements doc's "Outbound Mode" submenu, distinct from `mihomo-cli`'s
/// internal `mode` terminology only in label, not in meaning.
enum OutboundMode: String {
    case direct
    case global
    case rule
}

enum NetworkMode: String {
    case none
    case systemProxy = "system-proxy"
    case tun
    case proxyMode = "proxy-mode"
}

struct SubscriptionSummary {
    let name: String
    let isActive: Bool
}

/// A single point-in-time read of everything the menu needs to render
/// itself, assembled from three independent `mihomo-cli ... --json` calls.
/// Fields are optional/best-effort: a field that couldn't be read (kernel
/// not running, CLI missing, transient error) renders as unknown rather than
/// blocking the rest of the menu from updating.
struct MenuBarSnapshot {
    var cliAvailable: Bool = false
    var outboundMode: OutboundMode?
    var networkMode: NetworkMode?
    var subscriptions: [SubscriptionSummary] = []
}

final class MenuBarStateFetcher {
    private let bridge: CLIBridge

    init(bridge: CLIBridge) {
        self.bridge = bridge
    }

    func fetch() async -> MenuBarSnapshot {
        var snapshot = MenuBarSnapshot()
        snapshot.cliAvailable = bridge.isAvailable
        guard snapshot.cliAvailable else { return snapshot }

        async let modeJSON = bridge.runJSON(["mode", "status", "--json"])
        async let netJSON = bridge.runJSON(["net", "status", "--json"])
        async let subJSON = bridge.runJSON(["sub", "list", "--json"])

        if let dict = await modeJSON as? [String: Any],
           let effective = dict["effectiveMode"] as? String {
            snapshot.outboundMode = OutboundMode(rawValue: effective.lowercased())
        }

        if let dict = await netJSON as? [String: Any],
           let mode = dict["mode"] as? String {
            snapshot.networkMode = NetworkMode(rawValue: mode)
        }

        if let array = await subJSON as? [[String: Any]] {
            snapshot.subscriptions = array.compactMap { entry in
                guard let name = entry["name"] as? String else { return nil }
                let isActive = entry["isActive"] as? Bool ?? false
                return SubscriptionSummary(name: name, isActive: isActive)
            }
        }

        return snapshot
    }
}
