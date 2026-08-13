import Foundation

final class UninstallService {

    private let lifecycleService: LifecycleService
    private let daemonService: DaemonService
    private let netService: NetService
    private let confirmationPrompt: (_ question: String, _ yes: Bool) throws -> PromptResult
    private let printLine: (String) -> Void
    private let homeDirectoryURL: URL

    init(
        lifecycleService: LifecycleService = LifecycleService(),
        daemonService: DaemonService = DaemonService(),
        netService: NetService = NetService(),
        confirmationPrompt: @escaping (_ question: String, _ yes: Bool) throws -> PromptResult = confirm,
        printLine: @escaping (String) -> Void = { print($0) },
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.lifecycleService = lifecycleService
        self.daemonService = daemonService
        self.netService = netService
        self.confirmationPrompt = confirmationPrompt
        self.printLine = printLine
        self.homeDirectoryURL = homeDirectoryURL
    }

    func uninstall(purgeData: Bool, yes: Bool) async throws {
        let prompt = "This will remove all system-level state installed by mihomo-cli. Continue?"
        let res = try confirmationPrompt(prompt, yes)
        guard res == .confirmed else {
            throw CLIError(
                what: "uninstall cancelled",
                cause: "user declined confirmation",
                exitCode: .permissionDenied
            )
        }

        printLine("Uninstalling mihomo-cli...")
        var warningCount = 0

        // 1. Stop Kernel
        do {
            try await lifecycleService.stop()
            printLine("  ✅ Kernel stopped")
        } catch let err as CLIError where err.exitCode == .permissionDenied && err.what.contains("not running") {
            // Not running is normal
        } catch {
            warningCount += 1
            printLine("  ⚠  Failed to stop kernel: \(error.localizedDescription)")
        }

        // 2. Remove Launchd Agent
        do {
            try await daemonService.remove(yes: true)
            printLine("  ✅ launchd agent removed")
        } catch {
            warningCount += 1
            printLine("  ⚠  Failed to remove launchd agent: \(error.localizedDescription)")
        }

        // 3. Revert System Proxy & Network Modes
        do {
            try await netService.off()
            printLine("  ✅ Network routing modes reverted")
        } catch {
            warningCount += 1
            printLine("  ⚠  Failed to revert network modes: \(error.localizedDescription)")
        }

        // 4. Purge Data (Optional)
        if purgeData {
            let dataDir = homeDirectoryURL.appendingPathComponent(".mihomo-cli")
            do {
                if FileManager.default.fileExists(atPath: dataDir.path) {
                    try FileManager.default.removeItem(at: dataDir)
                }
                printLine("  ✅ Purged data directory at \(dataDir.path)")
            } catch {
                warningCount += 1
                printLine("  ⚠  Failed to purge data directory: \(error.localizedDescription)")
            }
        }

        if warningCount == 0 {
            if purgeData {
                printLine("Uninstall completed successfully. All data purged.")
            } else {
                printLine("Uninstall completed. Config and logs were preserved (use --purge-data to remove them too).")
            }
        } else {
            printLine("Uninstall completed with \(warningCount) warning(s).")
        }
    }
}
