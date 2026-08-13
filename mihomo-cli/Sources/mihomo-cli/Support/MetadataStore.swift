import Foundation
import Security

/// Local metadata store for everything the manager needs to remember between
/// invocations: installed kernel records, subscription records, the current
/// control-API port/secret, and daemon supervision state.
///
/// This is the dependency almost every command handler needs first — see
/// README.md's suggested implementation order. Backed by a single JSON file
/// at `~/.mihomo-cli/store.json`, written using the
/// temp-file-write + atomic-replace pattern mandated by design doc §4.1.4
/// so a crash or power loss mid-write can never corrupt the store.
///
/// An `actor` rather than a plain class: command handlers are async
/// (`AsyncParsableCommand`), and this serializes concurrent access to the
/// in-memory document within a single process. Cross-process concurrency is
/// handled separately by `AdvisoryLock` around mutating commands (design doc §3);
/// this actor is not a substitute for that lock, since flock is what protects
/// against a *second CLI invocation*, not just concurrent tasks in one process.
actor MetadataStore {
    private let storeURL: URL
    private var cached: MetadataDocument?

    static let shared = MetadataStore()

    init(baseDirectory: String = "\(NSHomeDirectory())/.mihomo-cli") {
        self.storeURL = URL(fileURLWithPath: baseDirectory).appendingPathComponent("store.json")
    }

    // MARK: - Load / Save

    /// Loads from disk on first access, then serves the in-memory cache.
    /// Returns an empty document (not an error) if the store doesn't exist
    /// yet — matches the "no kernels installed" / "no subscriptions
    /// configured" empty-state messaging in the list commands, rather than
    /// treating first-run as a failure.
    private func load() throws -> MetadataDocument {
        if let cached { return cached }

        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            let empty = MetadataDocument()
            cached = empty
            return empty
        }

        let data: Data
        do {
            data = try Data(contentsOf: storeURL)
        } catch {
            throw CLIError(
                what: "could not read local metadata store",
                cause: "\(storeURL.path) exists but could not be read (\(error.localizedDescription))",
                fix: "check file permissions, or remove the file to start fresh (this discards kernel/subscription records)",
                exitCode: .permissionDenied
            )
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let doc = try decoder.decode(MetadataDocument.self, from: data)
            cached = doc
            return doc
        } catch {
            throw CLIError(
                what: "local metadata store is corrupted",
                cause: "\(storeURL.path) does not contain valid JSON matching the expected schema (\(error.localizedDescription))",
                fix: "this should not happen given the atomic-write pattern used to write it — if it does, back up the file and file a bug; the tool will not guess at a partial recovery",
                exitCode: .validationFailure
            )
        }
    }

    /// Writes the document using temp-file-write + atomic-replace (design
    /// doc §4.1.4): write to a sibling temp file, fsync, then rename over
    /// the real path. `rename(2)` on the same volume is atomic, so a
    /// process that dies mid-write leaves the original store.json
    /// untouched rather than half-written.
    private func save(_ doc: MetadataDocument) throws {
        let directory = storeURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(doc)
        } catch {
            throw CLIError(
                what: "could not serialize local metadata store",
                cause: error.localizedDescription,
                exitCode: .validationFailure
            )
        }

        let tempURL = storeURL.appendingPathExtension("tmp-\(UUID().uuidString.prefix(8))")
        do {
            try data.write(to: tempURL, options: .atomic)
            // .atomic already does write-to-temp + rename internally on the
            // *destination* URL, but we go through our own temp file first
            // so a failure during `data.write` never touches storeURL at all,
            // matching the explicit two-step pattern described in §4.1.4.
            _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw CLIError(
                what: "could not persist local metadata store",
                cause: error.localizedDescription,
                fix: "check disk space and permissions on \(directory.path)",
                exitCode: .permissionDenied
            )
        }

        cached = doc
    }

    /// Read-modify-write helper so every mutation goes through the same
    /// load -> mutate -> save path. Callers still need `AdvisoryLock`
    /// around the whole command for cross-process safety; this only
    /// guarantees the in-memory document and on-disk write stay consistent.
    private func mutate<T>(_ body: (inout MetadataDocument) throws -> T) throws -> T {
        var doc = try load()
        let result = try body(&doc)
        try save(doc)
        return result
    }

    // MARK: - Kernels

    func listKernels() throws -> [KernelRecord] {
        try load().kernels.sorted(by: KernelRecord.defaultSort)
    }

    func kernel(version: String) throws -> KernelRecord? {
        try load().kernels.first { $0.version == version }
    }

    func activeKernel() throws -> KernelRecord? {
        try load().kernels.first { $0.isActive }
    }

    @discardableResult
    func upsertKernel(_ record: KernelRecord) throws -> KernelRecord {
        try mutate { doc in
            if let idx = doc.kernels.firstIndex(where: { $0.version == record.version }) {
                doc.kernels[idx] = record
            } else {
                doc.kernels.append(record)
            }
            return record
        }
    }

    /// Marks `version` active and every other kernel inactive, in one
    /// atomic document write — used by the persist step of `kernel use`'s
    /// atomic switch workflow (design doc §4.1.1).
    func setActiveKernel(version: String) throws {
        try mutate { doc in
            for i in doc.kernels.indices {
                doc.kernels[i].isActive = (doc.kernels[i].version == version)
                if doc.kernels[i].isActive {
                    doc.kernels[i].lastUsedAt = Date()
                }
            }
        }
    }

    /// Removes a kernel record. Callers are responsible for enforcing the
    /// "cannot remove the active kernel" hard restriction (design doc §1.1.2)
    /// *before* calling this — kept out of the store layer so the store
    /// stays a dumb persistence layer and the business rule lives in the
    /// command handler alongside its error message.
    func removeKernel(version: String) throws {
        try mutate { doc in
            doc.kernels.removeAll { $0.version == version }
        }
    }

    // MARK: - Subscriptions

    func listSubscriptions() throws -> [SubscriptionRecord] {
        try load().subscriptions.sorted(by: SubscriptionRecord.defaultSort)
    }

    func subscription(name: String) throws -> SubscriptionRecord? {
        try load().subscriptions.first { $0.name == name }
    }

    func activeSubscription() throws -> SubscriptionRecord? {
        try load().subscriptions.first { $0.isActive }
    }

    @discardableResult
    func upsertSubscription(_ record: SubscriptionRecord) throws -> SubscriptionRecord {
        try mutate { doc in
            if let idx = doc.subscriptions.firstIndex(where: { $0.name == record.name }) {
                doc.subscriptions[idx] = record
            } else {
                doc.subscriptions.append(record)
            }
            return record
        }
    }

    func setActiveSubscription(name: String) throws {
        try mutate { doc in
            for i in doc.subscriptions.indices {
                doc.subscriptions[i].isActive = (doc.subscriptions[i].name == name)
                if doc.subscriptions[i].isActive {
                    doc.subscriptions[i].lastUsedAt = Date()
                }
            }
        }
    }

    func removeSubscription(name: String) throws {
        try mutate { doc in
            doc.subscriptions.removeAll { $0.name == name }
        }
    }

    /// Generates a unique name by appending a numeric suffix, per the
    /// collision-handling rule in design doc §1.2.3 ("if overwrite is
    /// declined, a serial number is appended").
    func uniqueSubscriptionName(preferred: String) throws -> String {
        let existing = Set(try load().subscriptions.map(\.name))
        guard existing.contains(preferred) else { return preferred }
        var suffix = 2
        while existing.contains("\(preferred)-\(suffix)") { suffix += 1 }
        return "\(preferred)-\(suffix)"
    }

    // MARK: - Control API credentials

    func controlAPICredentials() throws -> ControlAPICredentials? {
        try load().controlAPI
    }

    /// Generates a fresh random secret and stores it alongside the given
    /// port, per mihomo_control_api_integration_spec.md §2 ("regenerated
    /// on every kernel use/start"). Always loopback-bound; callers never
    /// pass in a non-local port.
    @discardableResult
    func regenerateControlAPICredentials(port: Int) throws -> ControlAPICredentials {
        let secret = Self.generateSecret()
        let creds = ControlAPICredentials(port: port, secret: secret)
        try mutate { doc in doc.controlAPI = creds }
        return creds
    }

    private static func generateSecret(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let result = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(result == errSecSuccess, "SecRandomCopyBytes failed unexpectedly")
        return Data(bytes).base64EncodedString()
    }

    // MARK: - Daemon state

    func daemonState() throws -> DaemonState {
        try load().daemon
    }

    func updateDaemonState(_ body: (inout DaemonState) -> Void) throws {
        try mutate { doc in body(&doc.daemon) }
    }

    // MARK: - Running kernel state

    func runningKernel() throws -> RunningKernelState? {
        try load().runningKernel
    }

    func setRunningKernel(_ state: RunningKernelState?) throws {
        try mutate { doc in doc.runningKernel = state }
    }

    /// Shared "intentional stop" marker used by `mihomo stop`, `kernel use`,
    /// `restart`, and uninstall before terminating a managed kernel process.
    /// This is the daemon-visible contract that prevents launchd supervision
    /// from racing an expected switch/teardown as if it were a crash.
    func markKernelStopExpected() throws {
        try updateDaemonState { $0.lastStopWasUserInitiated = true }
    }

    /// Called after a manager-launched kernel has passed liveness. From this
    /// point forward, an unexpected exit should again be visible to daemon
    /// supervision as a crash candidate rather than mistaken for the earlier
    /// intentional stop that made the switch possible.
    func markKernelStartObserved() throws {
        try updateDaemonState { $0.lastStopWasUserInitiated = false }
    }

    // MARK: - Network Mode

    func networkMode() throws -> ActiveNetworkMode {
        try load().networkMode
    }

    func setNetworkMode(_ mode: ActiveNetworkMode) throws {
        try mutate { doc in doc.networkMode = mode }
    }

    func lastAppliedSystemProxy() throws -> SystemProxySettings? {
        try load().lastAppliedSystemProxy
    }

    func setLastAppliedSystemProxy(_ settings: SystemProxySettings?) throws {
        try mutate { doc in doc.lastAppliedSystemProxy = settings }
    }
}

