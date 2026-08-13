import Foundation

/// Persisted record for one installed kernel binary — backs `mihomo kernel list`
/// (mihomo_kernel_command_spec.md §list) and the fields defined in the design
/// doc §1.1.1.
struct KernelRecord: Codable, Equatable {
    var version: String
    var binaryPath: String
    var addedAt: Date
    var lastUsedAt: Date?
    var isActive: Bool

    /// Default sort per design doc §1.1.1: Active > Last Used > Version > Added Time.
    static func defaultSort(_ a: KernelRecord, _ b: KernelRecord) -> Bool {
        if a.isActive != b.isActive { return a.isActive }
        switch (a.lastUsedAt, b.lastUsedAt) {
        case let (l?, r?) where l != r: return l > r
        case (.some, .none): return true
        case (.none, .some): return false
        default: break
        }
        if a.version != b.version { return a.version > b.version }
        return a.addedAt > b.addedAt
    }
}

/// Persisted record for one subscription — backs `mihomo sub list`
/// (mihomo_sub_command_spec.md §list) and the fields defined in the design
/// doc §1.2.1.
struct SubscriptionRecord: Codable, Equatable {
    enum Source: Codable, Equatable {
        case local(path: String)
        case remote(url: String, intervalMinutes: Int)
    }

    var name: String
    var source: Source
    var addedAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var isActive: Bool
    /// Set by `sub edit` (design doc / sub spec §edit) when a post-edit
    /// re-validation fails — surfaced in `sub list` as "⚠ invalid" rather
    /// than silently reverting the user's file.
    var isFlaggedInvalid: Bool = false

    var isLocal: Bool {
        if case .local = source { return true }
        return false
    }

    /// Default sort per design doc §1.2.1: Active > Last Used > Updated Time > Added Time.
    static func defaultSort(_ a: SubscriptionRecord, _ b: SubscriptionRecord) -> Bool {
        if a.isActive != b.isActive { return a.isActive }
        switch (a.lastUsedAt, b.lastUsedAt) {
        case let (l?, r?) where l != r: return l > r
        case (.some, .none): return true
        case (.none, .some): return false
        default: break
        }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.addedAt > b.addedAt
    }
}

/// Per-kernel-instance control-API connection info, generated fresh on every
/// `kernel use` / `start` per mihomo_control_api_integration_spec.md §2.
/// Never sourced from the user's subscription file.
struct ControlAPICredentials: Codable, Equatable {
    var port: Int
    var secret: String
}

/// State for the launchd supervision agent (design doc §2.3, §4.1.2).
struct DaemonState: Codable, Equatable {
    var installed: Bool = false
    var restartCount: Int = 0
    var lastRestartAt: Date?
    var lastRestartReason: String?
    /// Set by `mihomo stop` before signaling the kernel, so the daemon
    /// (if installed) can distinguish an intentional stop from a crash
    /// and skip auto-restart accordingly — see LifecycleCommands.swift.
    var lastStopWasUserInitiated: Bool = false
}

/// Runtime process state for the currently manager-launched kernel.
/// Stored separately from "active kernel" because `start --version` can run
/// a one-off version without changing the active pointer.
struct RunningKernelState: Codable, Equatable {
    var version: String
    var pid: Int32
    var startedAt: Date
    var controlPort: Int
    var mixedPort: Int
    var configPath: String
    var stdoutPath: String
    var stderrPath: String
}

/// Active network mode per design doc §2.1 and §6.3.
enum ActiveNetworkMode: Codable, Equatable {
    case none
    case systemProxy(service: String, host: String, port: Int, since: Date)
    case tun(interface: String, since: Date)
    case proxyMode(port: Int, since: Date)
}

/// Last applied macOS system proxy settings, tracked to detect external modification.
struct SystemProxySettings: Codable, Equatable {
    var service: String
    var host: String
    var port: Int
    var appliedAt: Date
}

/// Top-level container persisted as a single JSON document. Combining
/// related records into one file (rather than one file per kernel/
/// subscription) follows the storage guidance to batch data that's read
/// or updated together, and keeps the atomic-write guarantee (design doc
/// §4.1.4) simple: one temp-write + rename covers the whole store.
struct MetadataDocument: Codable {
    var kernels: [KernelRecord] = []
    var subscriptions: [SubscriptionRecord] = []
    var controlAPI: ControlAPICredentials?
    var daemon: DaemonState = DaemonState()
    var runningKernel: RunningKernelState?
    var networkMode: ActiveNetworkMode = .none
    var lastAppliedSystemProxy: SystemProxySettings?

    init(
        kernels: [KernelRecord] = [],
        subscriptions: [SubscriptionRecord] = [],
        controlAPI: ControlAPICredentials? = nil,
        daemon: DaemonState = DaemonState(),
        runningKernel: RunningKernelState? = nil,
        networkMode: ActiveNetworkMode = .none,
        lastAppliedSystemProxy: SystemProxySettings? = nil
    ) {
        self.kernels = kernels
        self.subscriptions = subscriptions
        self.controlAPI = controlAPI
        self.daemon = daemon
        self.runningKernel = runningKernel
        self.networkMode = networkMode
        self.lastAppliedSystemProxy = lastAppliedSystemProxy
    }

    enum CodingKeys: CodingKey {
        case kernels
        case subscriptions
        case controlAPI
        case daemon
        case runningKernel
        case networkMode
        case lastAppliedSystemProxy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kernels = try container.decodeIfPresent([KernelRecord].self, forKey: .kernels) ?? []
        self.subscriptions = try container.decodeIfPresent([SubscriptionRecord].self, forKey: .subscriptions) ?? []
        self.controlAPI = try container.decodeIfPresent(ControlAPICredentials.self, forKey: .controlAPI)
        self.daemon = try container.decodeIfPresent(DaemonState.self, forKey: .daemon) ?? DaemonState()
        self.runningKernel = try container.decodeIfPresent(RunningKernelState.self, forKey: .runningKernel)
        self.networkMode = try container.decodeIfPresent(ActiveNetworkMode.self, forKey: .networkMode) ?? .none
        self.lastAppliedSystemProxy = try container.decodeIfPresent(SystemProxySettings.self, forKey: .lastAppliedSystemProxy)
    }
}
