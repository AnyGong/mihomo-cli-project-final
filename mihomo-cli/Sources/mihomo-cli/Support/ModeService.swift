import Foundation
import Darwin

/// Testable service encapsulating the `mode` command group business logic.
final class ModeService {

    // MARK: - Injectable dependencies

    private let runningKernel: () async throws -> RunningKernelState?
    private let controlAPICredentials: () async throws -> ControlAPICredentials?
    private let clientFactory: (ControlAPICredentials) -> KernelClient
    private let activeSubscription: () async throws -> SubscriptionRecord?
    private let loadSubscriptionYAML: (SubscriptionRecord) throws -> String
    private let confirmationPrompt: (_ question: String, _ yes: Bool) throws -> PromptResult
    private let isProcessRunning: (Int32) -> Bool
    private let printLine: (String) -> Void

    init(
        runningKernel: @escaping () async throws -> RunningKernelState? = { try await MetadataStore.shared.runningKernel() },
        controlAPICredentials: @escaping () async throws -> ControlAPICredentials? = { try await MetadataStore.shared.controlAPICredentials() },
        clientFactory: @escaping (ControlAPICredentials) -> KernelClient = { HTTPKernelClient(port: $0.port, secret: $0.secret) },
        activeSubscription: @escaping () async throws -> SubscriptionRecord? = { try await MetadataStore.shared.activeSubscription() },
        loadSubscriptionYAML: @escaping (SubscriptionRecord) throws -> String = { record in
            let path: String
            switch record.source {
            case .local(let p):
                path = p
            case .remote:
                path = "\(NSHomeDirectory())/.mihomo-cli/subscriptions/\(record.name).yaml"
            }
            return try String(contentsOfFile: path, encoding: .utf8)
        },
        confirmationPrompt: @escaping (_ question: String, _ yes: Bool) throws -> PromptResult = confirm,
        isProcessRunning: @escaping (Int32) -> Bool = { pid in
            pid > 0 && (Darwin.kill(pid, 0) == 0 || errno == EPERM)
        },
        printLine: @escaping (String) -> Void = { print($0) }
    ) {
        self.runningKernel = runningKernel
        self.controlAPICredentials = controlAPICredentials
        self.clientFactory = clientFactory
        self.activeSubscription = activeSubscription
        self.loadSubscriptionYAML = loadSubscriptionYAML
        self.confirmationPrompt = confirmationPrompt
        self.isProcessRunning = isProcessRunning
        self.printLine = printLine
    }

    // MARK: - Status

    struct ModeStatusReport {
        let isKernelRunning: Bool
        let effectiveMode: String?
        let subscriptionDefault: String?
        let hasActiveSubscription: Bool
        let isOverridden: Bool
    }

    struct ModeStatusJSON: Encodable {
        let isKernelRunning: Bool
        let effectiveMode: String?
        let subscriptionDefault: String?
        let isOverridden: Bool
        let hasActiveSubscription: Bool
    }

    func report() async throws -> ModeStatusReport {
        let running = try await runningKernel()
        let kernelRunning = running != nil && isProcessRunning(running!.pid)

        var effectiveMode: String? = nil
        if kernelRunning, let creds = try await controlAPICredentials() {
            let client = clientFactory(creds)
            effectiveMode = try? await client.getConfigs().mode
        }

        let activeSub = try await activeSubscription()
        var subDefault: String? = nil
        if let activeSub {
            if let yaml = try? loadSubscriptionYAML(activeSub) {
                let validation = SubscriptionValidator.validate(yamlString: yaml)
                subDefault = validation.embeddedMode ?? "rule"
            } else {
                subDefault = "rule"
            }
        }

        let isOverridden: Bool
        if let effective = effectiveMode, let subDef = subDefault {
            isOverridden = (effective.lowercased() != subDef.lowercased())
        } else {
            isOverridden = false
        }

        return ModeStatusReport(
            isKernelRunning: kernelRunning,
            effectiveMode: effectiveMode,
            subscriptionDefault: subDefault,
            hasActiveSubscription: activeSub != nil,
            isOverridden: isOverridden
        )
    }

    func status(json: Bool) async throws {
        let rep = try await report()

        if json {
            let jsonObj = ModeStatusJSON(
                isKernelRunning: rep.isKernelRunning,
                effectiveMode: rep.effectiveMode,
                subscriptionDefault: rep.subscriptionDefault,
                isOverridden: rep.isOverridden,
                hasActiveSubscription: rep.hasActiveSubscription
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(jsonObj)
            printLine(String(data: data, encoding: .utf8) ?? "{}")
            return
        }

        guard rep.isKernelRunning, let effective = rep.effectiveMode else {
            printLine("Status:          kernel is not running")
            printLine("Note:            run 'mihomo start' or 'mihomo kernel use <version>' to launch one.")
            return
        }

        printLine("Effective mode:        \(effective)")

        if rep.hasActiveSubscription, let subDef = rep.subscriptionDefault {
            if rep.isOverridden {
                printLine("Subscription default:  \(subDef) (CLI override in effect)")
                printLine("Note: this override was applied via 'mihomo mode \(effective)' and persists until changed or the subscription is switched.")
            } else {
                printLine("Subscription default:  \(subDef) (matches)")
            }
        } else {
            printLine("No active subscription — mode is a kernel-level setting only.")
        }
    }

    // MARK: - Mode Switching (Rule / Global / Direct)

    func switchMode(to targetMode: String, yes: Bool) async throws {
        return try await AdvisoryLock().withLock {
            let running = try await runningKernel()
            guard let running, isProcessRunning(running.pid), let creds = try await controlAPICredentials() else {
                throw CLIError(
                    what: "no kernel running — cannot change rule mode",
                    cause: "kernel process is not running",
                    fix: "run 'mihomo start' first",
                    exitCode: .permissionDenied
                )
            }

            // Confirmation gates for safety-critical modes (§mode global / direct)
            if targetMode.lowercased() == "global" {
                let prompt = """
                Global Mode forces ALL traffic through the proxy, bypassing your subscription's rule list. This can affect LAN access and some captive portals.
                Continue?
                """
                let res = try confirmationPrompt(prompt, yes)
                guard res == .confirmed else {
                    throw CLIError(
                        what: "mode switch cancelled",
                        cause: "user declined confirmation",
                        exitCode: .permissionDenied
                    )
                }
            } else if targetMode.lowercased() == "direct" {
                let prompt = """
                Direct Mode sends ALL traffic locally, bypassing the proxy entirely. Nothing will be routed through mihomo until you switch modes again.
                Continue?
                """
                let res = try confirmationPrompt(prompt, yes)
                guard res == .confirmed else {
                    throw CLIError(
                        what: "mode switch cancelled",
                        cause: "user declined confirmation",
                        exitCode: .permissionDenied
                    )
                }
            }

            let client = clientFactory(creds)
            let patch = ConfigsPatch(mode: targetMode.lowercased())

            // Apply runtime patch
            try await client.patchConfigs(patch)

            // Liveness check via readback
            let liveness = try await client.livenessCheck(expectedVersion: nil, expectedConfigPatch: patch)
            switch liveness {
            case .healthy:
                break
            case .configMismatch(let field, let expected, let actual):
                throw CLIError(
                    what: "mode switch aborted at 'liveness check'",
                    cause: "readback mismatch for field '\(field)' (expected '\(expected)', got '\(actual)')",
                    exitCode: .validationFailure
                )
            case .unresponsive(let reason), .versionMismatch(_, let reason):
                throw CLIError(
                    what: "mode switch aborted at 'liveness check'",
                    cause: reason,
                    exitCode: .validationFailure
                )
            }

            let capitalizedMode = targetMode.prefix(1).uppercased() + targetMode.dropFirst().lowercased()
            printLine("✅ \(capitalizedMode) mode active.")
        }
    }
}
