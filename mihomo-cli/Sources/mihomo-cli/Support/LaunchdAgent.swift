import Foundation

protocol LaunchdManaging {
    var plistURL: URL { get }
    func isPlistPresent() -> Bool
    func writePlist(_ content: String) throws
    func removePlist() throws
    func bootstrap() throws
    func bootout() throws
}

final class DefaultLaunchdManager: LaunchdManaging {
    var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.mihomo-cli.agent.plist")
    }

    func isPlistPresent() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    func writePlist(_ content: String) throws {
        let dir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: plistURL, atomically: true, encoding: .utf8)
    }

    func removePlist() throws {
        if isPlistPresent() {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    func bootstrap() throws {
        let uid = getuid()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootstrap", "gui/\(uid)", plistURL.path]
        try? process.run()
        process.waitUntilExit()
    }

    func bootout() throws {
        let uid = getuid()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(uid)", plistURL.path]
        try? process.run()
        process.waitUntilExit()
    }
}

final class DaemonService {

    private let launchdManager: LaunchdManaging
    private let daemonState: () async throws -> DaemonState
    private let updateDaemonState: ((inout DaemonState) -> Void) async throws -> Void
    private let runningKernel: () async throws -> RunningKernelState?
    private let confirmationPrompt: (_ question: String, _ yes: Bool) throws -> PromptResult
    private let printLine: (String) -> Void
    private let cliExecutablePath: () -> String

    init(
        launchdManager: LaunchdManaging = DefaultLaunchdManager(),
        daemonState: @escaping () async throws -> DaemonState = { try await MetadataStore.shared.daemonState() },
        updateDaemonState: @escaping ((inout DaemonState) -> Void) async throws -> Void = { try await MetadataStore.shared.updateDaemonState($0) },
        runningKernel: @escaping () async throws -> RunningKernelState? = { try await MetadataStore.shared.runningKernel() },
        confirmationPrompt: @escaping (_ question: String, _ yes: Bool) throws -> PromptResult = confirm,
        printLine: @escaping (String) -> Void = { print($0) },
        cliExecutablePath: @escaping () -> String = { CommandLine.arguments.first ?? "/usr/local/bin/mihomo" }
    ) {
        self.launchdManager = launchdManager
        self.daemonState = daemonState
        self.updateDaemonState = updateDaemonState
        self.runningKernel = runningKernel
        self.confirmationPrompt = confirmationPrompt
        self.printLine = printLine
        self.cliExecutablePath = cliExecutablePath
    }

    // MARK: - Plist Generation

    static func generatePlist(executablePath: String, logDir: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.mihomo-cli.agent</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
                <string>start</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>StandardOutPath</key>
            <string>\(logDir)/daemon.stdout.log</string>
            <key>StandardErrorPath</key>
            <string>\(logDir)/daemon.stderr.log</string>
        </dict>
        </plist>
        """
    }

    // MARK: - Install

    func install(yes: Bool) async throws {
        return try await AdvisoryLock().withLock {
            let current = try await daemonState()
            if current.installed && launchdManager.isPlistPresent() {
                printLine("launchd agent is already installed at \(launchdManager.plistURL.path).")
                return
            }

            let logDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".mihomo-cli/logs").path
            let plistContent = DaemonService.generatePlist(
                executablePath: cliExecutablePath(),
                logDir: logDir
            )

            printLine("Installing launchd agent at \(launchdManager.plistURL.path)")
            do {
                try launchdManager.writePlist(plistContent)
                try launchdManager.bootstrap()
            } catch {
                throw CLIError(
                    what: "failed to install launchd agent",
                    cause: error.localizedDescription,
                    fix: "check ~/Library/LaunchAgents permissions",
                    exitCode: .privilegeError
                )
            }

            try await updateDaemonState { state in
                state.installed = true
            }

            printLine("✅ Daemon installed. mihomo will now auto-restart on crash and persist after this terminal closes.")
        }
    }

    // MARK: - Remove

    func remove(yes: Bool) async throws {
        return try await AdvisoryLock().withLock {
            let current = try await daemonState()
            if !current.installed && !launchdManager.isPlistPresent() {
                printLine("launchd agent is not installed — nothing to do.")
                return
            }

            try? launchdManager.bootout()
            try? launchdManager.removePlist()

            try await updateDaemonState { state in
                state.installed = false
            }

            let running = try await runningKernel()
            if let r = running {
                printLine("✅ Daemon removed. The kernel is still running (pid \(r.pid)) but will no longer auto-restart if it crashes, and won't persist after you close this terminal.")
                printLine("Run 'mihomo stop' if you also want to stop it now.")
            } else {
                printLine("✅ Daemon removed.")
            }
        }
    }

    // MARK: - Status

    struct DaemonStatusJSON: Encodable {
        let installed: Bool
        let agentState: String
        let restartCount: Int
        let lastRestartAt: Date?
        let lastRestartReason: String?
    }

    func status(json: Bool) async throws {
        let current = try await daemonState()
        let isPresent = launchdManager.isPlistPresent() && current.installed

        if json {
            let obj = DaemonStatusJSON(
                installed: isPresent,
                agentState: isPresent ? "running" : "not installed",
                restartCount: current.restartCount,
                lastRestartAt: current.lastRestartAt,
                lastRestartReason: current.lastRestartReason
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(obj)
            printLine(String(data: data, encoding: .utf8) ?? "{}")
            return
        }

        if !isPresent {
            printLine("Installed: no")
            printLine("Note: run 'mihomo daemon install' to enable auto-restart and persistence.")
            return
        }

        printLine("Installed:      yes")
        printLine("Agent state:    running")
        printLine("Restart count:  \(current.restartCount) (since install)")

        if let lastAt = current.lastRestartAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            let dateStr = formatter.string(from: lastAt)
            let reasonStr = current.lastRestartReason ?? "unknown"
            printLine("Last restart:   \(dateStr) — reason: \(reasonStr)")
        } else {
            printLine("Last restart:   never")
        }
    }
}
