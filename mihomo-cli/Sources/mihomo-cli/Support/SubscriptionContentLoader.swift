import Foundation

/// Resolves the on-disk path for a subscription and loads its raw YAML
/// content. Previously this logic lived only as private helpers inside
/// `SubscriptionService` (`destinationURL(for:)` / `loadContent(for:)`).
/// Factored out so the kernel-launch paths (`KernelUseService`,
/// `LifecycleService`) can load the *active* subscription's content too —
/// they previously never did, which meant every kernel launch wrote the
/// hardcoded empty passthrough config (`proxies: []`, `proxy-groups: []`)
/// regardless of what subscription was active, silently ignoring
/// `proxy-providers`, `proxy-groups`, custom `rules`, etc. from the real
/// subscription file. Only `sub use`/`sub refresh` (switching subscriptions
/// on an *already-running* kernel) ever passed real content through.
enum SubscriptionContentLoader {
    static func destinationURL(for name: String, in subscriptionsDirectory: URL) -> URL {
        let safeName = name.replacingOccurrences(of: "/", with: "_")
        return subscriptionsDirectory.appendingPathComponent("\(safeName).yaml")
    }

    /// The on-disk path for a subscription record: the file itself for a
    /// local import, or the managed copy under `subscriptionsDirectory` for
    /// a remote one.
    static func path(for record: SubscriptionRecord, subscriptionsDirectory: URL) -> String {
        switch record.source {
        case .local(let p):
            return p
        case .remote:
            return destinationURL(for: record.name, in: subscriptionsDirectory).path
        }
    }

    /// Loads a subscription's raw YAML text. Throws (rather than silently
    /// falling back to an empty config) if the file is missing or unreadable
    /// — a kernel launched with the wrong config silently is worse than a
    /// clear error.
    static func loadContent(
        for record: SubscriptionRecord,
        subscriptionsDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        let path = path(for: record, subscriptionsDirectory: subscriptionsDirectory)

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
}
