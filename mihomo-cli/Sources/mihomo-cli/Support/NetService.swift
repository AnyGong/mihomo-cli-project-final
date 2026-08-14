import Foundation

/// Testable service encapsulating the `net` command group business logic.
final class NetService {

    // MARK: - Injectable dependencies

    private let networkMode: () async throws -> ActiveNetworkMode
    private let setNetworkMode: (ActiveNetworkMode) async throws -> Void
    private let lastAppliedSystemProxy: () async throws -> SystemProxySettings?
    private let setLastAppliedSystemProxy: (SystemProxySettings?) async throws -> Void
    private let daemonState: () async throws -> DaemonState
    private let runningKernel: () async throws -> RunningKernelState?
    private let controlAPICredentials: () async throws -> ControlAPICredentials?
    private let networkSetup: NetworkSetupManaging
    private let portInspector: PortInspecting
    private let clientFactory: (ControlAPICredentials) -> KernelClient
    private let confirmationPrompt: (_ question: String, _ yes: Bool) throws -> PromptResult
    /// Relaunches the running kernel elevated (`true`) or unelevated
    /// (`false`) via `sudo`, per the hardware-confirmed Tun privilege
    /// mechanism (docs/mihomo_tun_privilege_spike_guide.md). Defaults to
    /// `LifecycleService.setTunElevation`. Injected so `tunOn`/`tunOff`
    /// stay unit-testable without actually invoking `sudo`.
    private let setTunElevation: (Bool) async throws -> Void
    private let printLine: (String) -> Void
    private let now: () -> Date

    init(
        networkMode: @escaping () async throws -> ActiveNetworkMode = { try await MetadataStore.shared.networkMode() },
        setNetworkMode: @escaping (ActiveNetworkMode) async throws -> Void = { try await MetadataStore.shared.setNetworkMode($0) },
        lastAppliedSystemProxy: @escaping () async throws -> SystemProxySettings? = { try await MetadataStore.shared.lastAppliedSystemProxy() },
        setLastAppliedSystemProxy: @escaping (SystemProxySettings?) async throws -> Void = { try await MetadataStore.shared.setLastAppliedSystemProxy($0) },
        daemonState: @escaping () async throws -> DaemonState = { try await MetadataStore.shared.daemonState() },
        runningKernel: @escaping () async throws -> RunningKernelState? = { try await MetadataStore.shared.runningKernel() },
        controlAPICredentials: @escaping () async throws -> ControlAPICredentials? = { try await MetadataStore.shared.controlAPICredentials() },
        networkSetup: NetworkSetupManaging = NetworkSetup(),
        portInspector: PortInspecting = PortInspector(),
        clientFactory: @escaping (ControlAPICredentials) -> KernelClient = { HTTPKernelClient(port: $0.port, secret: $0.secret) },
        confirmationPrompt: @escaping (_ question: String, _ yes: Bool) throws -> PromptResult = confirm,
        setTunElevation: @escaping (Bool) async throws -> Void = { try await LifecycleService().setTunElevation($0) },
        printLine: @escaping (String) -> Void = { print($0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.networkMode = networkMode
        self.setNetworkMode = setNetworkMode
        self.lastAppliedSystemProxy = lastAppliedSystemProxy
        self.setLastAppliedSystemProxy = setLastAppliedSystemProxy
        self.daemonState = daemonState
        self.runningKernel = runningKernel
        self.controlAPICredentials = controlAPICredentials
        self.networkSetup = networkSetup
        self.portInspector = portInspector
        self.clientFactory = clientFactory
        self.confirmationPrompt = confirmationPrompt
        self.setTunElevation = setTunElevation
        self.printLine = printLine
        self.now = now
    }

    // MARK: - Status

    struct NetStatusJSON: Encodable {
        let mode: String
        let interface: String?
        let port: Int?
        let since: Date?
        let supervised: Bool
    }

    func status(json: Bool) async throws {
        let mode = try await networkMode()
        let daemon = try await daemonState()

        if json {
            let modeStr: String
            var iface: String? = nil
            var portNum: Int? = nil
            var sinceDate: Date? = nil

            switch mode {
            case .none:
                modeStr = "none"
            case .systemProxy(let service, _, let p, let since):
                modeStr = "system-proxy"
                iface = service
                portNum = p
                sinceDate = since
            case .tun(let ifName, let since):
                modeStr = "tun"
                iface = ifName
                sinceDate = since
            case .proxyMode(let p, let since):
                modeStr = "proxy-mode"
                portNum = p
                sinceDate = since
            }

            let obj = NetStatusJSON(
                mode: modeStr,
                interface: iface,
                port: portNum,
                since: sinceDate,
                supervised: daemon.installed
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(obj)
            printLine(String(data: data, encoding: .utf8) ?? "{}")
            return
        }

        let supervisedText = daemon.installed ? "yes (launchd agent active)" : "no"

        switch mode {
        case .none:
            printLine("Mode:        none")
            printLine("Note:        traffic is not being proxied. Run 'mihomo net system-proxy on', 'net tun on', or 'net proxy-mode on'.")

        case .systemProxy(let service, _, _, let since):
            printLine("Mode:        System Proxy")
            printLine("Interface:   \(service)")
            printLine("Since:       \(formatDateWithElapsed(since))")
            printLine("Supervised:  \(supervisedText)")

        case .tun(let ifName, let since):
            printLine("Mode:        Tun")
            printLine("Interface:   \(ifName)")
            printLine("Since:       \(formatDateWithElapsed(since))")
            printLine("Supervised:  \(supervisedText)")

        case .proxyMode(let port, let since):
            printLine("Mode:        Proxy Mode")
            printLine("Port:        \(port)")
            printLine("Since:       \(formatDateWithElapsed(since))")
            printLine("Supervised:  \(supervisedText)")
        }
    }

    // MARK: - System Proxy On / Off

    func systemProxyOn(interface requestedInterface: String?, yes: Bool) async throws {
        return try await AdvisoryLock().withLock {
            // Deactivate any conflicting active mode (mutual exclusivity §2.1)
            try await deactivateActiveModeExcept(matching: { mode in
                if case .systemProxy = mode { return true }
                return false
            })

            let activeServices = try networkSetup.getActiveServices()
            guard !activeServices.isEmpty else {
                throw CLIError(
                    what: "no active network service found",
                    cause: "no network interface has an active link",
                    exitCode: .portUnavailable
                )
            }

            let targetService: String
            if let requested = requestedInterface {
                let allServices = try networkSetup.listAllServices()
                guard allServices.contains(requested) else {
                    throw CLIError(
                        what: "target interface not found",
                        cause: "network service '\(requested)' does not exist",
                        fix: "run 'networksetup -listallnetworkservices' to view valid services",
                        exitCode: .portUnavailable
                    )
                }
                targetService = requested
            } else if activeServices.count == 1 {
                targetService = activeServices[0]
            } else {
                // Multiple active services, none specified
                guard isatty(STDIN_FILENO) != 0 else {
                    throw CLIError(
                        what: "multiple active network services found",
                        cause: "cannot select interactively in non-interactive context",
                        fix: "specify target service with --interface",
                        exitCode: .validationFailure
                    )
                }

                printLine("Multiple active network services found:")
                for (idx, s) in activeServices.enumerated() {
                    printLine("  \(idx + 1)) \(s)")
                }
                print("Which should carry the proxy? [1-\(activeServices.count)]: ", terminator: "")
                guard let input = readLine(strippingNewline: true),
                      let choice = Int(input),
                      (1...activeServices.count).contains(choice) else {
                    throw CLIError(
                        what: "invalid selection",
                        cause: "selected index out of range",
                        exitCode: .validationFailure
                    )
                }
                targetService = activeServices[choice - 1]
            }

            // Conflict detection: check existing proxy on target service (§2.1)
            let existingProxy = try? networkSetup.getWebProxy(service: targetService)
            let lastApplied = try await lastAppliedSystemProxy()

            let host = "127.0.0.1"
            let running = try await runningKernel()
            let port = running?.mixedPort ?? 7890

            if let existing = existingProxy, existing.enabled {
                let isOurProxy = (existing.server == host && existing.port == port) ||
                                 (lastApplied?.service == targetService && lastApplied?.port == existing.port)
                if !isOurProxy {
                    let prompt = "warning: a system proxy is already configured on '\(targetService)' (\(existing.server):\(existing.port)), possibly set by another application.\nOverwrite it?"
                    let res = try confirmationPrompt(prompt, yes)
                    guard res == .confirmed else {
                        throw CLIError(
                            what: "system proxy setup cancelled",
                            cause: "user declined overwriting existing proxy",
                            exitCode: .permissionDenied
                        )
                    }
                }
            }

            // Apply system proxy settings
            try networkSetup.setWebProxy(service: targetService, host: host, port: port)
            try networkSetup.setWebProxyState(service: targetService, enabled: true)
            try networkSetup.setSecureWebProxy(service: targetService, host: host, port: port)
            try networkSetup.setSecureWebProxyState(service: targetService, enabled: true)

            let settings = SystemProxySettings(service: targetService, host: host, port: port, appliedAt: now())
            try await setLastAppliedSystemProxy(settings)
            try await setNetworkMode(.systemProxy(service: targetService, host: host, port: port, since: now()))

            printLine("✅ System Proxy enabled on '\(targetService)' (\(host):\(port)).")
        }
    }

    func systemProxyOff(yes: Bool = false) async throws {
        return try await AdvisoryLock().withLock {
            try await performSystemProxyOff(yes: yes)
        }
    }

    private func performSystemProxyOff(yes: Bool) async throws {
        let mode = try await networkMode()
        guard case .systemProxy(let service, let configuredHost, let configuredPort, _) = mode else {
            printLine("System Proxy is not active — nothing to do.")
            return
        }

        let currentProxy = try? networkSetup.getWebProxy(service: service)
        if let current = currentProxy, current.enabled {
            if current.server != configuredHost || current.port != configuredPort {
                let prompt = "warning: current system proxy on '\(service)' doesn't match what this tool configured — it may have been changed externally.\nClear it anyway?"
                let res = try confirmationPrompt(prompt, yes)
                guard res == .confirmed else {
                    return
                }
            }
        }

        try? networkSetup.setWebProxyState(service: service, enabled: false)
        try? networkSetup.setSecureWebProxyState(service: service, enabled: false)

        try await setLastAppliedSystemProxy(nil)
        try await setNetworkMode(.none)
        printLine("✅ System Proxy disabled on '\(service)'.")
    }

    // MARK: - Tun Mode On / Off

    func tunOn(yes: Bool) async throws {
        // NOTE ON LOCKING: this can't be a single AdvisoryLock().withLock
        // wrapping the whole method the way the other net/mode commands
        // are, because setTunElevation() (LifecycleService) takes its own
        // AdvisoryLock — and AdvisoryLock is a real flock(2) held per file
        // descriptor, so a nested acquire from the same process on the same
        // lock file self-conflicts (immediate exit-4 "operation already in
        // progress"), it doesn't recursively succeed. Splitting into two
        // lock windows around the elevated relaunch avoids that; it leaves
        // a narrow window where a second `net tun on`/`net tun off` could
        // interleave between phases. Given this tool's single-user,
        // single-machine scope, that's an accepted trade rather than a
        // reason to make AdvisoryLock itself reentrant.
        try await AdvisoryLock().withLock {
            // Deactivate any conflicting active mode (mutual exclusivity)
            try await deactivateActiveModeExcept(matching: { mode in
                if case .tun = mode { return true }
                return false
            })

            // Check for utun collision (§4.1.3)
            if portInspector.isUtunInterfacePresent() {
                throw CLIError(
                    what: "cannot start Tun mode",
                    cause: "utun interface already claimed, likely by another VPN client",
                    fix: "disconnect the other VPN and retry, or run 'mihomo net status' on it if it's a mihomo-managed instance",
                    exitCode: .portUnavailable
                )
            }

            // Privilege entitlement check / one-time prompt (§2.3)
            let prompt = """
            Tun mode requires a one-time privileged setup step to grant network capability to the mihomo binary.
            This will prompt for your macOS password. Continue?
            """
            let res = try confirmationPrompt(prompt, yes)
            guard res == .confirmed else {
                throw CLIError(
                    what: "Tun mode unavailable",
                    cause: "entitlement setup declined",
                    exitCode: .privilegeError
                )
            }
        }

        // Actually relaunch the kernel under sudo — the hardware spike
        // confirmed unprivileged utun creation fails, and confirming the
        // prompt above without this would leave Tun mode "on" in the
        // metadata store while doing nothing on the wire. Outside the lock
        // above for the reason in the NOTE.
        try await setTunElevation(true)

        try await AdvisoryLock().withLock {
            try await setNetworkMode(.tun(interface: "utun", since: now()))
            printLine("✅ Tun mode active.")
        }
    }

    func tunOff() async throws {
        let wasActive = try await AdvisoryLock().withLock { () -> Bool in
            let mode = try await networkMode()
            guard case .tun = mode else { return false }
            return true
        }

        guard wasActive else {
            printLine("Tun mode is not active — nothing to do.")
            return
        }

        // Best-effort, outside the lock (see tunOn's NOTE ON LOCKING) — drop
        // the kernel back to unprivileged. If no kernel happens to be
        // running at all, there's nothing to de-elevate; that's not a
        // reason to fail turning Tun mode off.
        try? await setTunElevation(false)

        try await AdvisoryLock().withLock {
            try await setNetworkMode(.none)
            printLine("✅ Tun mode disabled.")
        }
    }

    /// Lock-free variant used by `off()` and `deactivateActiveModeExcept`,
    /// which already hold the AdvisoryLock themselves — see tunOn's NOTE ON
    /// LOCKING for why `setTunElevation` can never be called while this
    /// process already holds that lock.
    private func performTunOffMetadataOnly() async throws {
        let mode = try await networkMode()
        guard case .tun = mode else {
            printLine("Tun mode is not active — nothing to do.")
            return
        }
        try await setNetworkMode(.none)
        printLine("✅ Tun mode disabled.")
    }

    // MARK: - Proxy Mode On / Off

    func proxyModeOn(port requestedPort: Int?) async throws {
        return try await AdvisoryLock().withLock {
            // Deactivate any conflicting active mode (mutual exclusivity)
            try await deactivateActiveModeExcept(matching: { mode in
                if case .proxyMode = mode { return true }
                return false
            })

            let running = try await runningKernel()
            let targetPort = requestedPort ?? running?.mixedPort ?? 7890

            // Port availability check (§4.1.3)
            if let conflict = try? portInspector.findProcessUsingPort(targetPort) {
                if running == nil || conflict.pid != running?.pid {
                    throw CLIError(
                        what: "cannot bind port \(targetPort)",
                        cause: "already in use by another process (pid \(conflict.pid), '\(conflict.command)')",
                        exitCode: .portUnavailable
                    )
                }
            }

            // If an explicit --port was requested and differs from the
            // kernel's currently configured mixed-port, actually apply it
            // as a runtime overlay via PATCH /configs — never by editing
            // the subscription file (§2.4). Without this the command
            // previously "succeeded" while leaving the kernel listening on
            // whatever port it already had.
            if let requestedPort, requestedPort != running?.mixedPort {
                guard let running, let creds = try await controlAPICredentials() else {
                    throw CLIError(
                        what: "cannot bind port \(requestedPort)",
                        cause: "no kernel is currently running to reconfigure",
                        fix: "run 'mihomo kernel use <version>' or 'mihomo start' first",
                        exitCode: .permissionDenied
                    )
                }
                let client = clientFactory(creds)
                let patch = ConfigsPatch(mixedPort: requestedPort)
                try await client.patchConfigs(patch)
                let liveness = try await client.livenessCheck(expectedVersion: running.version, expectedConfigPatch: patch)
                let livenessDetail: String
                switch liveness {
                case .healthy:
                    livenessDetail = ""
                case .unresponsive(let reason):
                    livenessDetail = reason
                case .versionMismatch(let expected, let actual):
                    livenessDetail = "expected version \(expected), got \(actual)"
                case .configMismatch(let field, let expected, let actual):
                    livenessDetail = "\(field) expected \(expected), got \(actual)"
                }
                guard case .healthy = liveness else {
                    throw CLIError(
                        what: "cannot bind port \(requestedPort)",
                        cause: "kernel did not confirm the mixed-port change (\(livenessDetail))",
                        fix: "run 'mihomo log --level error' for the kernel's stderr output",
                        exitCode: .portUnavailable
                    )
                }
            }

            try await setNetworkMode(.proxyMode(port: targetPort, since: now()))
            printLine("✅ Proxy mode active on port \(targetPort).")
        }
    }

    func proxyModeOff() async throws {
        return try await AdvisoryLock().withLock {
            try await performProxyModeOff()
        }
    }

    private func performProxyModeOff() async throws {
        let mode = try await networkMode()
        guard case .proxyMode = mode else {
            printLine("Proxy mode is not active — nothing to do.")
            return
        }

        try await setNetworkMode(.none)
        printLine("✅ Proxy mode disabled.")
    }

    // MARK: - Deactivate All / Off Convenience

    func off() async throws {
        let mode = try await AdvisoryLock().withLock {
            try await networkMode()
        }

        switch mode {
        case .none:
            printLine("No network mode is currently active — nothing to do.")
        case .systemProxy:
            try await AdvisoryLock().withLock {
                try await performSystemProxyOff(yes: true)
            }
        case .tun:
            // Outside any lock — see tunOn's NOTE ON LOCKING.
            try? await setTunElevation(false)
            try await AdvisoryLock().withLock {
                try await performTunOffMetadataOnly()
            }
        case .proxyMode:
            try await AdvisoryLock().withLock {
                try await performProxyModeOff()
            }
        }
    }

    // MARK: - Private Helpers

    /// Deactivates whichever mode is currently active, if it isn't already
    /// the mode being switched to. Note: for the `.tun` case this only
    /// clears local metadata — it does NOT call `setTunElevation(false)` to
    /// drop the kernel back to unprivileged, because every caller of this
    /// method (`tunOn`, `systemProxyOn`, `proxyModeOn`) already holds the
    /// AdvisoryLock, and `setTunElevation` cannot be called while that lock
    /// is held (see tunOn's NOTE ON LOCKING). Practical effect: switching
    /// directly from Tun mode to System Proxy or Proxy Mode (without an
    /// explicit `net tun off` first) leaves the kernel process running
    /// elevated even though Tun mode is no longer the active mode. That's
    /// not a functional break — the kernel still serves the newly-active
    /// mode correctly — but it's an unnecessary elevated process. Calling
    /// `net tun off` explicitly before switching modes avoids it. Fully
    /// closing this gap would mean restructuring every one of this
    /// function's callers into the same two-phase lock pattern `tunOn`/
    /// `tunOff` use; tracked as a follow-up rather than done here.
    private func deactivateActiveModeExcept(matching isSameMode: (ActiveNetworkMode) -> Bool) async throws {
        let current = try await networkMode()
        if current != .none && !isSameMode(current) {
            switch current {
            case .systemProxy(let service, _, _, _):
                try? networkSetup.setWebProxyState(service: service, enabled: false)
                try? networkSetup.setSecureWebProxyState(service: service, enabled: false)
                try? await setLastAppliedSystemProxy(nil)
            case .tun, .proxyMode, .none:
                break
            }
            try await setNetworkMode(.none)
        }
    }

    private func formatDateWithElapsed(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let dateStr = formatter.string(from: date)

        let elapsedSeconds = Int(now().timeIntervalSince(date))
        let minutes = max(0, elapsedSeconds / 60)
        let elapsedStr = minutes < 60 ? "\(minutes)m ago" : "\(minutes / 60)h \(minutes % 60)m ago"

        return "\(dateStr) (\(elapsedStr))"
    }
}
