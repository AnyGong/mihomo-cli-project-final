import XCTest
@testable import mihomo_cli

final class MetadataStoreTests: XCTestCase {
    var tempDir: String!
    var store: MetadataStore!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "mihomo-cli-tests-\(UUID().uuidString)"
        store = MetadataStore(baseDirectory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    func testEmptyStoreReturnsEmptyLists() async throws {
        let kernels = try await store.listKernels()
        let subs = try await store.listSubscriptions()
        XCTAssertTrue(kernels.isEmpty)
        XCTAssertTrue(subs.isEmpty)
    }

    func testKernelRoundTripAndActiveFlag() async throws {
        let a = KernelRecord(version: "v1.19.10", binaryPath: "/bin/a", addedAt: Date(), lastUsedAt: nil, isActive: false)
        let b = KernelRecord(version: "v1.19.11", binaryPath: "/bin/b", addedAt: Date(), lastUsedAt: nil, isActive: false)
        try await store.upsertKernel(a)
        try await store.upsertKernel(b)
        try await store.setActiveKernel(version: "v1.19.11")

        let active = try await store.activeKernel()
        XCTAssertEqual(active?.version, "v1.19.11")

        // Re-open a fresh store instance pointed at the same directory to
        // confirm the write actually persisted to disk, not just the cache.
        let reopened = MetadataStore(baseDirectory: tempDir)
        let reloadedActive = try await reopened.activeKernel()
        XCTAssertEqual(reloadedActive?.version, "v1.19.11")
    }

    func testKernelDefaultSortActiveFirst() async throws {
        let old = KernelRecord(version: "v1.0.0", binaryPath: "/bin/old", addedAt: Date(timeIntervalSince1970: 0), lastUsedAt: nil, isActive: false)
        let active = KernelRecord(version: "v1.0.1", binaryPath: "/bin/active", addedAt: Date(), lastUsedAt: nil, isActive: true)
        try await store.upsertKernel(old)
        try await store.upsertKernel(active)

        let list = try await store.listKernels()
        XCTAssertEqual(list.first?.version, "v1.0.1", "active kernel should sort first per design doc §1.1.1")
    }

    func testUniqueSubscriptionNameAppendsSuffix() async throws {
        let record = SubscriptionRecord(
            name: "home-fiber",
            source: .local(path: "home-fiber.yaml"),
            addedAt: Date(),
            updatedAt: Date(),
            lastUsedAt: nil,
            isActive: false
        )
        try await store.upsertSubscription(record)

        let unique = try await store.uniqueSubscriptionName(preferred: "home-fiber")
        XCTAssertEqual(unique, "home-fiber-2", "collision handling per design doc §1.2.3")

        let stillUnique = try await store.uniqueSubscriptionName(preferred: "new-name")
        XCTAssertEqual(stillUnique, "new-name", "no collision should return the name unchanged")
    }

    func testRegenerateControlAPICredentialsProducesDistinctSecrets() async throws {
        let first = try await store.regenerateControlAPICredentials(port: 9090)
        let second = try await store.regenerateControlAPICredentials(port: 9090)
        XCTAssertNotEqual(first.secret, second.secret, "secret must be regenerated on every kernel use/start per integration spec §2")
    }
}
