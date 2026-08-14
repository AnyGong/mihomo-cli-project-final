import Foundation

final class DoctorService {

    private let activeKernel: () async throws -> KernelRecord?
    private let activeSubscription: () async throws -> SubscriptionRecord?
    private let networkMode: () async throws -> ActiveNetworkMode
    private let daemonState: () async throws -> DaemonState
    private let runningKernel: () async throws -> RunningKernelState?
    private let networkSetup: NetworkSetupManaging
    private let portInspector: PortInspecting
    private let launchdManager: LaunchdManaging
    private let tunPrivilege: TunPrivilegeManaging
    private let logDirectory: URL
    private let minimumFreeBytes: Int64
    private let printLine: (String) -> Void

    init(
        activeKernel: @escaping () async throws -> KernelRecord? = { try await MetadataStore.shared.activeKernel() },
        activeSubscription: @escaping () async throws -> SubscriptionRecord? = { try await MetadataStore.shared.activeSubscription() },
        networkMode: @escaping () async throws -> ActiveNetworkMode = { try await MetadataStore.shared.networkMode() },
        daemonState: @escaping () async throws -> DaemonState = { try await MetadataStore.shared.daemonState() },
        runningKernel: @escaping () async throws -> RunningKernelState? = { try await MetadataStore.shared.runningKernel() },
        networkSetup: NetworkSetupManaging = NetworkSetup(),
        portInspector: PortInspecting = PortInspector(),
        launchdManager: LaunchdManaging = DefaultLaunchdManager(),
        tunPrivilege: TunPrivilegeManaging = TunPrivilege(),
        logDirectory: URL = URL(fileURLWithPath: "\(NSHomeDirectory())/.mihomo-cli/logs"),
        minimumFreeBytes: Int64 = 200 * 1024 * 1024, // 200MB floor, matches log rotation headroom (5 files x 5MB + slack)
        printLine: @escaping (String) -> Void = { print($0) }
    ) {
        self.activeKernel = activeKernel
        self.activeSubscription = activeSubscription
        self.networkMode = networkMode
        self.daemonState = daemonState
        self.runningKernel = runningKernel
        self.networkSetup = networkSetup
        self.portInspector = portInspector
        self.launchdManager = launchdManager
        self.tunPrivilege = tunPrivilege
        self.logDirectory = logDirectory
        self.minimumFreeBytes = minimumFreeBytes
        self.printLine = printLine
    }

    struct CheckResult: Codable {
        let name: String
        let status: String // "passed", "warning", "failed"
        let detail: String
    }

    struct DoctorReportJSON: Codable {
        let checks: [CheckResult]
        let warningCount: Int
        let passed: Bool
    }

    func run(json: Bool) async throws {
        var checks: [CheckResult] = []
        var warnings: [String] = []

        // 1. Kernel binary presence
        let activeK = try await activeKernel()
        if let k = activeK {
            if FileManager.default.fileExists(atPath: k.binaryPath) {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: k.binaryPath),
                   let size = attrs[.size] as? Int64, size > 0 {
                    checks.append(CheckResult(name: "Kernel binary present", status: "passed", detail: "passed (v\(k.version))"))
                } else {
                    throw CLIError(
                        what: "kernel binary corrupted",
                        cause: "active kernel binary at \(k.binaryPath) is zero length",
                        exitCode: .sourceVerificationFailure
                    )
                }
            } else {
                throw CLIError(
                    what: "kernel binary missing",
                    cause: "active kernel binary not found at \(k.binaryPath)",
                    exitCode: .sourceVerificationFailure
                )
            }
        } else {
            checks.append(CheckResult(name: "Kernel binary present", status: "warning", detail: "no active kernel configured"))
            warnings.append("No active kernel configured. Run 'mihomo kernel use <version>'.")
        }

        // 2. Subscription validity
        let activeSub = try await activeSubscription()
        if let s = activeSub {
            if s.isFlaggedInvalid {
                checks.append(CheckResult(name: "Subscription validity", status: "warning", detail: "flagged invalid (\(s.name))"))
                warnings.append("Active subscription '\(s.name)' is flagged invalid. Run 'mihomo sub validate \(s.name)' or 'sub edit'.")
            } else {
                checks.append(CheckResult(name: "Subscription validity", status: "passed", detail: "passed (\(s.name))"))
            }
        } else {
            checks.append(CheckResult(name: "Subscription validity", status: "warning", detail: "no active subscription"))
            warnings.append("No active subscription configured. Run 'mihomo sub use <name>'.")
        }

        // 3. Port availability
        let runningK = try await runningKernel()
        let portToCheck = runningK?.mixedPort ?? 7890
        if let conflict = try? portInspector.findProcessUsingPort(portToCheck) {
            if runningK == nil || conflict.pid != runningK?.pid {
                checks.append(CheckResult(name: "Port \(portToCheck) availability", status: "warning", detail: "in use by pid \(conflict.pid) (\(conflict.command))"))
                warnings.append("Port \(portToCheck) is occupied by another process (\(conflict.command), pid \(conflict.pid)).")
            } else {
                checks.append(CheckResult(name: "Port \(portToCheck) availability", status: "passed", detail: "bound to running kernel (pid \(conflict.pid))"))
            }
        } else {
            checks.append(CheckResult(name: "Port \(portToCheck) availability", status: "passed", detail: "free"))
        }

        // 4. System proxy consistency
        let currentMode = try await networkMode()
        var proxyConsistent = true
        var proxyDetail = "in sync"

        if case .systemProxy(let svc, let host, let port, _) = currentMode {
            if let webInfo = try? networkSetup.getWebProxy(service: svc) {
                if !webInfo.enabled || webInfo.server != host || webInfo.port != port {
                    proxyConsistent = false
                    proxyDetail = "mismatch — tool expects \(host):\(port) on '\(svc)', OS reports \(webInfo.enabled ? "\(webInfo.server):\(webInfo.port)" : "disabled")"
                } else {
                    proxyDetail = "in sync (\(svc) -> \(host):\(port))"
                }
            }
        } else {
            // No system proxy active in tool: check if any active service has web proxy turned on
            let activeServices = (try? networkSetup.getActiveServices()) ?? []
            for svc in activeServices {
                if let info = try? networkSetup.getWebProxy(service: svc), info.enabled {
                    proxyConsistent = false
                    proxyDetail = "mismatch — OS reports active proxy on '\(svc)' (\(info.server):\(info.port)), tool expects none"
                    break
                }
            }
            if proxyConsistent {
                proxyDetail = "in sync (none active)"
            }
        }

        if proxyConsistent {
            checks.append(CheckResult(name: "System proxy consistency", status: "passed", detail: proxyDetail))
        } else {
            checks.append(CheckResult(name: "System proxy consistency", status: "warning", detail: proxyDetail))
            warnings.append("System proxy settings mismatch detected. Run 'mihomo net system-proxy off' then re-enable to resync.")
        }

        // 5. Tun entitlement — real check: does an elevated launch currently
        // work without a fresh interactive prompt? (NOPASSWD rule installed,
        // or sudo's timestamp cache is warm from a recent `net tun on`.)
        // This intentionally does NOT report "granted" just because Tun mode
        // is marked active in the metadata store — that flag only reflects
        // intent, not whether privilege is currently usable.
        if tunPrivilege.hasEntitlement() {
            checks.append(CheckResult(name: "Tun entitlement", status: "passed", detail: "granted (sudo usable without prompt)"))
        } else {
            checks.append(CheckResult(name: "Tun entitlement", status: "warning", detail: "not currently usable — sudo would prompt"))
            warnings.append("Tun mode privilege is not currently usable without a password prompt. Run 'mihomo net tun on' interactively once, or install the NOPASSWD sudoers.d rule from docs/mihomo_tun_privilege_spike_guide.md.")
        }

        // 6. Daemon health
        let daemon = try await daemonState()
        let plistPresent = launchdManager.isPlistPresent()
        if daemon.installed && plistPresent {
            checks.append(CheckResult(name: "Daemon health", status: "passed", detail: "running, \(daemon.restartCount) unexpected restarts"))
        } else if !daemon.installed && !plistPresent {
            checks.append(CheckResult(name: "Daemon health", status: "passed", detail: "not installed"))
        } else {
            checks.append(CheckResult(name: "Daemon health", status: "warning", detail: "plist state inconsistent (installed=\(daemon.installed), plist=\(plistPresent))"))
            warnings.append("Daemon plist state is inconsistent. Run 'mihomo daemon install' or 'daemon remove'.")
        }

        // 7. Disk / log headroom — real check: free space on the volume
        // backing the log directory, via statfs. Below `minimumFreeBytes`
        // is a warning, since log rotation (Support/Logger.swift) needs
        // headroom to write new segments and the kernel needs somewhere to
        // write its own stdout/stderr.
        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: logDirectory.path)
            if let free = attrs[.systemFreeSize] as? NSNumber {
                let freeBytes = free.int64Value
                let freeMB = freeBytes / (1024 * 1024)
                if freeBytes < minimumFreeBytes {
                    checks.append(CheckResult(name: "Disk / log headroom", status: "warning", detail: "low — \(freeMB)MB free at \(logDirectory.path)"))
                    warnings.append("Low disk space (\(freeMB)MB free) on the volume backing \(logDirectory.path). Log rotation and kernel output may fail to write.")
                } else {
                    checks.append(CheckResult(name: "Disk / log headroom", status: "passed", detail: "ok — \(freeMB)MB free"))
                }
            } else {
                checks.append(CheckResult(name: "Disk / log headroom", status: "warning", detail: "could not determine free space"))
                warnings.append("Could not determine free disk space at \(logDirectory.path).")
            }
        } catch {
            checks.append(CheckResult(name: "Disk / log headroom", status: "warning", detail: "could not access \(logDirectory.path)"))
            warnings.append("Could not access log directory \(logDirectory.path): \(error.localizedDescription)")
        }

        if json {
            let report = DoctorReportJSON(checks: checks, warningCount: warnings.count, passed: warnings.isEmpty)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            printLine(String(data: data, encoding: .utf8) ?? "{}")
            return
        }

        for check in checks {
            let paddedName = check.name.padding(toLength: 26, withPad: ".", startingAt: 0)
            let icon = check.status == "passed" ? "✅" : "⚠ "
            printLine("\(paddedName) \(icon) \(check.detail)")
        }

        printLine("")
        if warnings.isEmpty {
            printLine("All \(checks.count) diagnostic checks passed with 0 warnings.")
        } else {
            let noun = warnings.count == 1 ? "warning" : "warnings"
            printLine("\(warnings.count) \(noun) found:")
            for w in warnings {
                printLine("  • \(w)")
            }
        }
    }
}
