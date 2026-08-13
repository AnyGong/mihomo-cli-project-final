import ArgumentParser
import Foundation

/// `mihomo kernel ...` — see mihomo_kernel_command_spec.md for full behavior.
struct KernelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kernel",
        abstract: "Manage local mihomo kernel binaries and versions.",
        subcommands: [List.self, Check.self, Fetch.self, Use.self, Remove.self, Status.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List installed kernels.")

        @Flag(help: "Emit machine-readable JSON instead of a table.")
        var json = false

        @Option(help: "Sort key: active | last-used | version | added.")
        var sort: String?

        func run() async throws {
            let kernels = try await MetadataStore.shared.listKernels()
            // NOTE: `sort` currently ignores the --sort override and always
            // uses the design-doc §1.1.1 default from KernelRecord.defaultSort;
            // wiring the override is TODO, tracked separately from the store
            // integration itself.
            _ = sort

            if json {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(kernels)
                print(String(data: data, encoding: .utf8) ?? "[]")
                return
            }

            guard !kernels.isEmpty else {
                print("No kernels installed. Run 'mihomo kernel check' or 'mihomo kernel fetch' to get one.")
                return
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            print("  STATUS  VERSION            LAST USED             ADDED")
            for k in kernels {
                let status = k.isActive ? "✅" : "  "
                let lastUsed = k.lastUsedAt.map(formatter.string) ?? ""
                let added = formatter.string(from: k.addedAt)
                print("  \(status)      \(k.version.padding(toLength: 17, withPad: " ", startingAt: 0))  \(lastUsed.padding(toLength: 21, withPad: " ", startingAt: 0))  \(added)")
            }
        }
    }

    struct Check: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "check", abstract: "Check for a newer stable release.")

        @Flag(help: "Skip the confirmation prompt and apply the update if found.")
        var yes = false

        func run() async throws {
            try await KernelCheckService().check(yes: yes)
        }
    }

    struct Fetch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "fetch", abstract: "Download kernel release(s).")

        @Flag(help: "Fetch the latest 10 releases (stable/alpha/beta/pre-release).")
        var all = false

        @Argument(help: "Specific version tag to fetch directly, bypassing the top-10 window.")
        var version: String?

        func validate() throws {
            if all && version != nil {
                throw ValidationError("--all and <version> are mutually exclusive.")
            }
        }

        func run() async throws {
            let mode: KernelFetchMode
            if all {
                mode = .latest(limit: 10)
                print("Fetching latest 10 releases...")
            } else if let version {
                mode = .tag(version)
            } else {
                mode = .latestStable
            }

            let summary = try await AdvisoryLock().withLock {
                try await KernelFetchService().fetch(mode)
            }

            for outcome in summary.outcomes {
                let status: String
                switch outcome.status {
                case .downloaded: status = "downloaded"
                case .alreadyPresent: status = "already present, skipped"
                }
                print("  \(outcome.version.padding(toLength: 18, withPad: " ", startingAt: 0)) \(status)")
            }

            if all, let latestStable = summary.latestStable {
                print("Latest stable: \(latestStable)")
            }
        }
    }

    struct Use: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "use", abstract: "Switch the active kernel version.")

        @Argument(help: "Target kernel version.")
        var version: String

        @Flag(help: "Bypass the compatibility-warning confirmation (never bypasses integrity checks).")
        var force = false

        func run() async throws {
            _ = force // Compatibility-warning prompt is still pending subscription validation support.
            let result = try await KernelUseService().use(version: version)
            switch result.outcome {
            case .alreadyActive:
                print("'\(result.version)' is already the active kernel. Nothing to do.")
            case .switched:
                print("Kernel '\(result.version)' is now active.")
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete a kernel binary.")

        @Argument(help: "Kernel version to remove.")
        var version: String

        @Flag(help: "Skip the confirmation prompt.")
        var yes = false

        func run() async throws {
            guard let record = try await MetadataStore.shared.kernel(version: version) else {
                throw CLIError(what: "kernel not found", cause: "no installed kernel matches '\(version)'", exitCode: .notFound)
            }

            // Hard restriction, design doc §1.1.2 — not overridable by --yes.
            if record.isActive {
                throw CLIError(
                    what: "cannot remove '\(version)'",
                    cause: "it is the currently running kernel (§1.1.2)",
                    fix: "switch to a different kernel first with 'mihomo kernel use <other-version>'",
                    exitCode: .permissionDenied
                )
            }

            let result = try confirm("Remove kernel '\(version)'?", yes: yes)
            guard result == .confirmed else {
                print("Removal cancelled.")
                return
            }

            // Remove the binary from disk first, then the store record.
            // A failure here (e.g. missing file) is non-fatal — the store
            // record is still removed so the tool doesn't list a ghost entry.
            let binaryURL = URL(fileURLWithPath: record.binaryPath)
            let kernelDir = binaryURL.deletingLastPathComponent()
            do {
                // Remove the whole per-version directory (binary + any sidecar files).
                try FileManager.default.removeItem(at: kernelDir)
            } catch {
                // Not fatal — warn and continue to store removal.
                fputs("warning: could not delete '\(kernelDir.path)': \(error.localizedDescription)\n", stderr)
            }

            try await MetadataStore.shared.removeKernel(version: version)
            print("Removed kernel '\(version)'.")
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status", abstract: "Show the running kernel's status.")

        @Flag(help: "Emit machine-readable JSON instead of formatted text.")
        var json = false

        func run() async throws {
            let service = KernelStatusService()
            let report = try await service.report()

            if json {
                print(try KernelStatusService.jsonOutput(from: report))
            } else {
                print(KernelStatusService.humanOutput(from: report))
            }
        }
    }
}


