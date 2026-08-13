import Foundation

/// Testable service encapsulating the `kernel check` business logic.
/// Command handler in `KernelCommand.Check` calls this; tests inject fakes
/// for each dependency via the initialiser.
///
/// Workflow (per Full Specification §kernel-check):
///   1. Fetch latest stable release metadata (no download).
///   2. Compare against active kernel version from the store.
///   3. If already current → print informational message, exit 0.
///   4. If newer available → confirm via prompt (or --yes), then
///      fetch + use as a combined atomic operation.
///   5. If declined → print informational declined message, exit 0.
final class KernelCheckService {

    // MARK: - Injectable dependencies (all closures for testability)

    private let releaseProvider: KernelReleaseProviding
    private let activeKernel: () async throws -> KernelRecord?
    /// Injected fetch action — defaults to KernelFetchService().fetch(.tag(version)).
    private let fetchKernel: (String) async throws -> Void
    /// Injected use action — defaults to KernelUseService().use(version:).
    private let useKernel: (String) async throws -> KernelUseResult
    private let confirmationPrompt: (_ question: String, _ yes: Bool) throws -> PromptResult
    private let printLine: (String) -> Void

    init(
        releaseProvider: KernelReleaseProviding = GitHubKernelReleaseClient(),
        activeKernel: @escaping () async throws -> KernelRecord? = {
            try await MetadataStore.shared.activeKernel()
        },
        fetchKernel: @escaping (String) async throws -> Void = { version in
            _ = try await KernelFetchService().fetch(.tag(version))
        },
        useKernel: @escaping (String) async throws -> KernelUseResult = { version in
            try await KernelUseService().use(version: version)
        },
        confirmationPrompt: @escaping (_ question: String, _ yes: Bool) throws -> PromptResult = confirm,
        printLine: @escaping (String) -> Void = { print($0) }
    ) {
        self.releaseProvider = releaseProvider
        self.activeKernel = activeKernel
        self.fetchKernel = fetchKernel
        self.useKernel = useKernel
        self.confirmationPrompt = confirmationPrompt
        self.printLine = printLine
    }

    /// Runs the update check.
    /// - Parameter yes: whether to skip the confirmation prompt.
    func check(yes: Bool) async throws {
        // 1. Fetch latest stable metadata — no download yet.
        let releases = try await releaseProvider.latestReleases(limit: 10)

        guard let latest = releases.first(where: \.isStable) else {
            throw CLIError(
                what: "no stable release found",
                cause: "upstream release list contains no non-prerelease mihomo release",
                fix: "retry later, or run 'mihomo kernel fetch --all' to inspect recent releases",
                exitCode: .networkError
            )
        }

        let latestVersion = latest.tagName
        let activeVersion = try await activeKernel()?.version

        // 2. Already current?
        if let activeVersion, activeVersion == latestVersion {
            printLine("Local version \(activeVersion) is already the latest stable release. Nothing to do.")
            return
        }

        // Format a human-readable publication date if available.
        let dateString: String
        if let publishedAt = latest.publishedAt {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            dateString = " (published \(fmt.string(from: publishedAt)))"
        } else {
            dateString = ""
        }

        // 3. Report what's available.
        printLine("A newer stable release is available: \(latestVersion)\(dateString)")
        if let activeVersion {
            printLine("Currently active: \(activeVersion)")
        } else {
            printLine("No kernel is currently active.")
        }

        // 4. Prompt (or auto-confirm via --yes).
        let question = "Download and switch to it?"
        let result = try confirmationPrompt(question, yes)

        switch result {
        case .declined:
            printLine(
                "Update available but not applied. " +
                "Run 'mihomo kernel fetch \(latestVersion)' to get it without switching."
            )
            return

        case .confirmed:
            // 5. Combined atomic fetch + use.
            // fetch first — if it fails, nothing changes.
            try await fetchKernel(latestVersion)
            let useResult = try await useKernel(latestVersion)
            switch useResult.outcome {
            case .switched:
                printLine("Kernel '\(latestVersion)' is now active.")
            case .alreadyActive:
                // Shouldn't normally happen (we already checked), but handle gracefully.
                printLine("'\(latestVersion)' is already the active kernel. Nothing to do.")
            }
        }
    }
}
