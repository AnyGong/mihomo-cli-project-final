import Foundation
import Darwin

/// Testable service encapsulating all business logic for the `sub` command group.
final class SubscriptionService {

    // MARK: - Injectable dependencies

    private let subscriptionsDirectory: URL
    private let listSubscriptions: () async throws -> [SubscriptionRecord]
    private let subscription: (String) async throws -> SubscriptionRecord?
    private let activeSubscription: () async throws -> SubscriptionRecord?
    private let upsertSubscription: (SubscriptionRecord) async throws -> SubscriptionRecord
    private let setActiveSubscription: (String) async throws -> Void
    private let removeSubscriptionRecord: (String) async throws -> Void
    private let uniqueSubscriptionName: (String) async throws -> String
    private let runningKernel: () async throws -> RunningKernelState?
    private let controlAPICredentials: () async throws -> ControlAPICredentials?
    private let downloader: Downloading
    private let configWriter: RuntimeConfigWriting
    private let processController: KernelProcessControlling
    private let clientFactory: (ControlAPICredentials) -> KernelClient
    private let confirmationPrompt: (_ question: String, _ yes: Bool) throws -> PromptResult
    private let printLine: (String) -> Void
    private let fileManager: FileManager
    private let now: () -> Date

    init(
        subscriptionsDirectory: URL = URL(fileURLWithPath: "\(NSHomeDirectory())/.mihomo-cli/subscriptions"),
        listSubscriptions: @escaping () async throws -> [SubscriptionRecord] = { try await MetadataStore.shared.listSubscriptions() },
        subscription: @escaping (String) async throws -> SubscriptionRecord? = { try await MetadataStore.shared.subscription(name: $0) },
        activeSubscription: @escaping () async throws -> SubscriptionRecord? = { try await MetadataStore.shared.activeSubscription() },
        upsertSubscription: @escaping (SubscriptionRecord) async throws -> SubscriptionRecord = { try await MetadataStore.shared.upsertSubscription($0) },
        setActiveSubscription: @escaping (String) async throws -> Void = { try await MetadataStore.shared.setActiveSubscription(name: $0) },
        removeSubscriptionRecord: @escaping (String) async throws -> Void = { try await MetadataStore.shared.removeSubscription(name: $0) },
        uniqueSubscriptionName: @escaping (String) async throws -> String = { try await MetadataStore.shared.uniqueSubscriptionName(preferred: $0) },
        runningKernel: @escaping () async throws -> RunningKernelState? = { try await MetadataStore.shared.runningKernel() },
        controlAPICredentials: @escaping () async throws -> ControlAPICredentials? = { try await MetadataStore.shared.controlAPICredentials() },
        downloader: Downloading = ResumableDownloader(),
        configWriter: RuntimeConfigWriting = RuntimeConfigWriter(),
        processController: KernelProcessControlling = ProcessController(),
        clientFactory: @escaping (ControlAPICredentials) -> KernelClient = { HTTPKernelClient(port: $0.port, secret: $0.secret) },
        confirmationPrompt: @escaping (_ question: String, _ yes: Bool) throws -> PromptResult = confirm,
        printLine: @escaping (String) -> Void = { print($0) },
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.subscriptionsDirectory = subscriptionsDirectory
        self.listSubscriptions = listSubscriptions
        self.subscription = subscription
        self.activeSubscription = activeSubscription
        self.upsertSubscription = upsertSubscription
        self.setActiveSubscription = setActiveSubscription
        self.removeSubscriptionRecord = removeSubscriptionRecord
        self.uniqueSubscriptionName = uniqueSubscriptionName
        self.runningKernel = runningKernel
        self.controlAPICredentials = controlAPICredentials
        self.downloader = downloader
        self.configWriter = configWriter
        self.processController = processController
        self.clientFactory = clientFactory
        self.confirmationPrompt = confirmationPrompt
        self.printLine = printLine
        self.fileManager = fileManager
        self.now = now
    }

    // MARK: - Add Local

    func addLocal(path rawPath: String, preferredName: String?, yes: Bool) async throws {
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expandedPath)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw CLIError(
                what: "file not found",
                cause: "no file exists at '\(expandedPath)'",
                fix: "check the file path and retry",
                exitCode: .notFound
            )
        }

        let content: String
        do {
            content = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw CLIError(
                what: "could not read file",
                cause: error.localizedDescription,
                fix: "check file permissions on '\(expandedPath)'",
                exitCode: .permissionDenied
            )
        }

        // Full pre-flight validation (§1.2.2)
        let validation = SubscriptionValidator.validate(yamlString: content)
        if !validation.isValid {
            let details = SubscriptionValidator.formatErrorOutput(issues: validation.issues)
            printLine(details)
            throw CLIError(
                what: "subscription rejected",
                cause: "\(validation.issues.count) validation error(s)",
                fix: "fix the errors listed above and re-import",
                exitCode: .validationFailure
            )
        }

        // Derive name if not provided
        let derived = preferredName ?? fileURL.deletingPathExtension().lastPathComponent
        let targetName = try await resolveNameCollision(preferred: derived, yes: yes)

        let modDate = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date) ?? now()

        let record = SubscriptionRecord(
            name: targetName,
            source: .local(path: fileURL.path),
            addedAt: now(),
            updatedAt: modDate,
            lastUsedAt: nil,
            isActive: false,
            isFlaggedInvalid: false
        )

        try await upsertSubscription(record)
        printLine("Imported local subscription '\(targetName)'.")
    }

    // MARK: - Add Remote

    func addRemote(url urlString: String, interval: Int, preferredName: String?, yes: Bool) async throws {
        guard let remoteURL = URL(string: urlString), remoteURL.scheme == "http" || remoteURL.scheme == "https" else {
            throw CLIError(
                what: "invalid URL",
                cause: "'\(urlString)' is not a valid HTTP/HTTPS URL",
                exitCode: .validationFailure
            )
        }

        guard (1...1440).contains(interval) else {
            throw CLIError(
                what: "invalid --interval",
                cause: "must be between 1 and 1440 minutes",
                exitCode: .validationFailure
            )
        }

        // Temporary file for download
        try ensureSubscriptionsDirectoryExists()
        let tempURL = subscriptionsDirectory.appendingPathComponent("tmp-\(UUID().uuidString).yaml")
        defer { try? fileManager.removeItem(at: tempURL) }

        do {
            try await downloader.download(from: remoteURL, to: tempURL)
        } catch {
            throw CLIError(
                what: "remote fetch failed",
                cause: error.localizedDescription,
                fix: "check network connectivity and subscription URL",
                exitCode: .networkError
            )
        }

        let content: String
        do {
            content = try String(contentsOf: tempURL, encoding: .utf8)
        } catch {
            throw CLIError(
                what: "could not read downloaded subscription",
                cause: error.localizedDescription,
                exitCode: .validationFailure
            )
        }

        // Validation
        let validation = SubscriptionValidator.validate(yamlString: content)
        if !validation.isValid {
            let details = SubscriptionValidator.formatErrorOutput(issues: validation.issues)
            printLine(details)
            throw CLIError(
                what: "subscription rejected",
                cause: "\(validation.issues.count) validation error(s)",
                fix: "fix the remote subscription content or contact your provider",
                exitCode: .validationFailure
            )
        }

        // Derive name if not provided
        let derived: String
        if let preferred = preferredName, !preferred.isEmpty {
            derived = preferred
        } else {
            let lastComponent = remoteURL.lastPathComponent
                .replacingOccurrences(of: ".yaml", with: "")
                .replacingOccurrences(of: ".yml", with: "")
            derived = lastComponent.isEmpty ? "remote-sub" : lastComponent
        }

        let targetName = try await resolveNameCollision(preferred: derived, yes: yes)
        let destinationURL = destinationURL(for: targetName)

        // Move temp file to destination
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        }

        let record = SubscriptionRecord(
            name: targetName,
            source: .remote(url: urlString, intervalMinutes: interval),
            addedAt: now(),
            updatedAt: now(),
            lastUsedAt: nil,
            isActive: false,
            isFlaggedInvalid: false
        )

        try await upsertSubscription(record)
        printLine("Imported remote subscription '\(targetName)'.")
    }

    // MARK: - Use / Activate

    func use(name: String, force: Bool) async throws {
        _ = force

        return try await AdvisoryLock().withLock {
            guard let targetRecord = try await subscription(name) else {
                throw CLIError(
                    what: "subscription not found",
                    cause: "no configured subscription matches '\(name)'",
                    fix: "run 'mihomo sub list' to see available subscriptions",
                    exitCode: .notFound
                )
            }

            if targetRecord.isActive {
                printLine("'\(name)' is already the active subscription. Nothing to do.")
                return
            }

            // Pre-switch validation (§1.2.2)
            let content = try loadContent(for: targetRecord)
            let validation = SubscriptionValidator.validate(yamlString: content)
            if !validation.isValid {
                let details = SubscriptionValidator.formatErrorOutput(issues: validation.issues)
                printLine(details)
                throw CLIError(
                    what: "cannot activate '\(name)'",
                    cause: "subscription contains validation errors",
                    fix: "run 'mihomo sub validate \(name)' for full details",
                    exitCode: .validationFailure
                )
            }

            let previousActive = try await activeSubscription()
            let running = try await runningKernel()

            if let running, processController.isRunning(pid: running.pid) {
                guard let creds = try await controlAPICredentials() else {
                    throw CLIError(
                        what: "cannot reach kernel",
                        cause: "no control API credentials available",
                        exitCode: .permissionDenied
                    )
                }

                let client = clientFactory(creds)
                let currentMode = (try? await client.getConfigs().mode) ?? "rule"

                // Write new runtime config with subscription content
                do {
                    _ = try configWriter.write(
                        version: running.version,
                        credentials: creds,
                        mixedPort: running.mixedPort,
                        subscriptionYAML: content,
                        modeOverride: currentMode
                    )

                    // Liveness check via control API
                    let liveness = try await client.livenessCheck(expectedVersion: running.version, expectedConfigPatch: nil)
                    switch liveness {
                    case .healthy:
                        break
                    case .unresponsive(let reason), .versionMismatch(_, let reason), .configMismatch(_, _, let reason):
                        throw CLIError(
                            what: "subscription switch aborted at 'liveness check'",
                            cause: "kernel rejected configuration: \(reason)",
                            exitCode: .validationFailure
                        )
                    }
                } catch {
                    // Rollback to previous subscription content if available
                    if let prev = previousActive, let prevContent = try? loadContent(for: prev) {
                        _ = try? configWriter.write(
                            version: running.version,
                            credentials: creds,
                            mixedPort: running.mixedPort,
                            subscriptionYAML: prevContent,
                            modeOverride: currentMode
                        )
                        printLine("Rolled back to '\(prev.name)'. No change was applied.")
                    }
                    throw error
                }
            }

            try await setActiveSubscription(name)
            printLine("Switched to '\(name)'.")

            // Mode precedence note (§2.4)
            if let embedded = validation.embeddedMode {
                let effectiveMode: String
                if let creds = try await controlAPICredentials() {
                    let client = clientFactory(creds)
                    effectiveMode = (try? await client.getConfigs().mode) ?? "rule"
                } else {
                    effectiveMode = "rule"
                }

                if embedded != effectiveMode {
                    printLine("Note: subscription default mode is '\(embedded)', but '\(effectiveMode)' is currently in effect (CLI override). Run 'mihomo mode \(embedded)' to match the subscription default, or leave as-is.")
                }
            }
        }
    }

    // MARK: - Edit

    func edit(name: String, customEditor: String?) async throws {
        guard let record = try await subscription(name) else {
            throw CLIError(
                what: "subscription not found",
                cause: "no subscription matches '\(name)'",
                exitCode: .notFound
            )
        }

        // Hard restriction (§1.2.2, Appendix A §edit) — cannot edit active subscription
        if record.isActive {
            throw CLIError(
                what: "cannot edit '\(name)'",
                cause: "it is the active subscription (root cause: hot edits risk desyncing the running kernel)",
                fix: "switch to another subscription first, or use 'mihomo sub use --force' after editing a copy",
                exitCode: .permissionDenied
            )
        }

        let targetPath: String
        switch record.source {
        case .local(let p):
            targetPath = p
        case .remote:
            targetPath = destinationURL(for: name).path
        }

        guard fileManager.fileExists(atPath: targetPath) else {
            throw CLIError(
                what: "subscription file missing",
                cause: "file does not exist at '\(targetPath)'",
                exitCode: .notFound
            )
        }

        let editor = customEditor ?? ProcessInfo.processInfo.environment["EDITOR"] ?? "/usr/bin/nano"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: editor.starts(with: "/") ? editor : "/usr/bin/which")
        if !editor.starts(with: "/") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [editor, targetPath]
        } else {
            process.arguments = [targetPath]
        }

        // Connect standard I/O for interactive editor terminal
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CLIError(
                what: "could not open editor",
                cause: error.localizedDescription,
                exitCode: .validationFailure
            )
        }

        // Post-edit re-validation (§1.2.2)
        if let newContent = try? String(contentsOfFile: targetPath, encoding: .utf8) {
            let validation = SubscriptionValidator.validate(yamlString: newContent)
            var updated = record
            updated.updatedAt = now()

            if !validation.isValid {
                updated.isFlaggedInvalid = true
                try await upsertSubscription(updated)
                printLine("warning: subscription '\(name)' has validation errors after editing and is flagged invalid (run 'mihomo sub validate \(name)' for details).")
            } else {
                updated.isFlaggedInvalid = false
                try await upsertSubscription(updated)
                printLine("Saved changes to subscription '\(name)'.")
            }
        }
    }

    // MARK: - Remove

    func remove(name: String, yes: Bool) async throws {
        guard let record = try await subscription(name) else {
            throw CLIError(
                what: "subscription not found",
                cause: "no subscription matches '\(name)'",
                exitCode: .notFound
            )
        }

        // Hard restriction: active subscription cannot be removed (§1.2.2)
        if record.isActive {
            throw CLIError(
                what: "cannot remove '\(name)'",
                cause: "it is the currently active subscription",
                fix: "switch to a different subscription first with 'mihomo sub use <other-name>'",
                exitCode: .permissionDenied
            )
        }

        let promptRes = try confirmationPrompt("Remove subscription '\(name)'?", yes)
        guard promptRes == .confirmed else {
            printLine("Removal cancelled.")
            return
        }

        // Only delete file if it was managed locally under subscriptions directory
        if !record.isLocal {
            let managedURL = destinationURL(for: name)
            try? fileManager.removeItem(at: managedURL)
        }

        try await removeSubscriptionRecord(name)
        printLine("Removed subscription '\(name)'.")
    }

    // MARK: - Refresh (Remote only)

    func refresh(name: String) async throws {
        guard let record = try await subscription(name) else {
            throw CLIError(
                what: "subscription not found",
                cause: "no subscription matches '\(name)'",
                exitCode: .notFound
            )
        }

        guard case .remote(let urlStr, _) = record.source, let remoteURL = URL(string: urlStr) else {
            throw CLIError(
                what: "'\(name)' is a local subscription — refresh re-reads it automatically on 'sub use'",
                cause: "no remote source configured",
                fix: "use 'mihomo sub edit' to change the file, or re-import as remote",
                exitCode: .permissionDenied
            )
        }

        try ensureSubscriptionsDirectoryExists()
        let tempURL = subscriptionsDirectory.appendingPathComponent("tmp-refresh-\(UUID().uuidString).yaml")
        defer { try? fileManager.removeItem(at: tempURL) }

        do {
            try await downloader.download(from: remoteURL, to: tempURL)
        } catch {
            throw CLIError(
                what: "refresh failed",
                cause: error.localizedDescription,
                fix: "check network access and retry; cached subscription remains active",
                exitCode: .networkError
            )
        }

        let content: String
        do {
            content = try String(contentsOf: tempURL, encoding: .utf8)
        } catch {
            throw CLIError(
                what: "could not read refreshed content",
                cause: error.localizedDescription,
                exitCode: .validationFailure
            )
        }

        let validation = SubscriptionValidator.validate(yamlString: content)
        if !validation.isValid {
            let details = SubscriptionValidator.formatErrorOutput(issues: validation.issues)
            printLine(details)
            throw CLIError(
                what: "refresh failed — new content is invalid",
                cause: "\(validation.issues.count) validation error(s)",
                fix: "previous cached copy remains in use",
                exitCode: .validationFailure
            )
        }

        let destination = destinationURL(for: name)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: destination)
        }

        var updated = record
        updated.updatedAt = now()
        updated.isFlaggedInvalid = false
        try await upsertSubscription(updated)

        // If currently active and kernel is running, reload
        if record.isActive, let running = try await runningKernel(), processController.isRunning(pid: running.pid) {
            if let creds = try await controlAPICredentials() {
                let client = clientFactory(creds)
                let currentMode = (try? await client.getConfigs().mode) ?? "rule"
                _ = try? configWriter.write(
                    version: running.version,
                    credentials: creds,
                    mixedPort: running.mixedPort,
                    subscriptionYAML: content,
                    modeOverride: currentMode
                )
            }
        }

        printLine("Refreshed remote subscription '\(name)'.")
    }

    // MARK: - Validate

    func validate(name: String) async throws {
        guard let record = try await subscription(name) else {
            throw CLIError(
                what: "subscription not found",
                cause: "no subscription matches '\(name)'",
                exitCode: .notFound
            )
        }

        let content = try loadContent(for: record)
        let validation = SubscriptionValidator.validate(yamlString: content)

        if validation.isValid {
            if record.isFlaggedInvalid {
                var fixed = record
                fixed.isFlaggedInvalid = false
                try await upsertSubscription(fixed)
            }
            printLine("Subscription '\(name)' is valid.")
        } else {
            var flagged = record
            flagged.isFlaggedInvalid = true
            try await upsertSubscription(flagged)

            let details = SubscriptionValidator.formatErrorOutput(issues: validation.issues)
            printLine(details)
            throw CLIError(
                what: "validation failed for '\(name)'",
                cause: "\(validation.issues.count) validation error(s) found",
                exitCode: .validationFailure
            )
        }
    }

    // MARK: - Private Helpers

    private func loadContent(for record: SubscriptionRecord) throws -> String {
        let path: String
        switch record.source {
        case .local(let p):
            path = p
        case .remote:
            path = destinationURL(for: record.name).path
        }

        guard fileManager.fileExists(atPath: path) else {
            throw CLIError(
                what: "subscription file not found",
                cause: "file at '\(path)' does not exist",
                exitCode: .notFound
            )
        }

        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw CLIError(
                what: "could not read subscription file",
                cause: error.localizedDescription,
                exitCode: .permissionDenied
            )
        }
    }

    private func destinationURL(for name: String) -> URL {
        let safeName = name.replacingOccurrences(of: "/", with: "_")
        return subscriptionsDirectory.appendingPathComponent("\(safeName).yaml")
    }

    private func ensureSubscriptionsDirectoryExists() throws {
        if !fileManager.fileExists(atPath: subscriptionsDirectory.path) {
            try fileManager.createDirectory(
                at: subscriptionsDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private func resolveNameCollision(preferred: String, yes: Bool) async throws -> String {
        guard let _ = try await subscription(preferred) else {
            return preferred
        }

        // Ask user if interactive, unless --yes
        if yes {
            return preferred
        }

        let promptResult = (try? confirmationPrompt("Overwrite existing subscription '\(preferred)'?", false)) ?? .declined
        if promptResult == .confirmed {
            return preferred
        }

        return try await uniqueSubscriptionName(preferred)
    }
}
