import Foundation
import XCTest
import Yams
@testable import mihomo_cli

/// Regression coverage for the runtime config generation bug: a full
/// mihomo config imported via `sub add local` that uses `proxy-providers`
/// (and has no top-level `proxies` list) was getting reduced to an empty
/// `proxies: []` / `proxy-groups: []` passthrough config, with
/// `proxy-providers` dropped entirely and no traffic proxied.
///
/// The actual bug wasn't in `RuntimeConfigWriter` itself — its merge logic
/// (load the whole YAML dict, overlay `mixed-port`/`external-controller`/
/// `secret`/`mode`, re-dump the whole thing) already preserves arbitrary
/// top-level keys like `proxy-providers` correctly. The bug was that the
/// kernel-launch paths (`KernelUseService.launch`, `LifecycleService.
/// performStart`) never loaded the active subscription's content at all —
/// they always called the `subscriptionYAML: nil` convenience overload,
/// which falls back to the hardcoded empty template unconditionally. See
/// the matching tests in `KernelUseServiceTests` / `LifecycleServiceTests`
/// for coverage of that half of the fix; this file covers the writer's own
/// preservation behavior in isolation.
final class RuntimeConfigWriterTests: XCTestCase {
    private var tempDir: URL!
    private var writer: RuntimeConfigWriter!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        writer = RuntimeConfigWriter(runtimeDirectory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func readWrittenConfig(_ config: RuntimeConfig) throws -> [String: Any] {
        let text = try String(contentsOf: config.configURL, encoding: .utf8)
        guard let dict = try Yams.load(yaml: text) as? [String: Any] else {
            XCTFail("written config.yaml did not parse back as a YAML mapping")
            return [:]
        }
        return dict
    }

    func testProxyProvidersOnlyConfigIsPreservedNotReducedToEmptyNodeList() throws {
        // Minimal repro from the bug report: a full config using
        // proxy-providers, with no top-level `proxies` at all.
        let subscriptionYAML = """
        proxy-providers:
          myprovider:
            type: http
            url: https://example.com/nodes.yaml
            path: ./proxy-providers/myprovider.yaml
            interval: 3600
        proxy-groups:
          - name: PROXY
            type: select
            use:
              - myprovider
        rules:
          - MATCH,PROXY
        """

        let config = try writer.write(
            version: "v1",
            credentials: ControlAPICredentials(port: 9090, secret: "s3cr3t"),
            mixedPort: 7890,
            subscriptionYAML: subscriptionYAML,
            modeOverride: nil
        )

        let written = try readWrittenConfig(config)

        XCTAssertNotNil(written["proxy-providers"], "proxy-providers must survive into the runtime config")
        let providers = written["proxy-providers"] as? [String: Any]
        XCTAssertNotNil(providers?["myprovider"], "the specific provider entry must be preserved")

        let groups = written["proxy-groups"] as? [[String: Any]]
        XCTAssertEqual(groups?.count, 1, "the real proxy-group must be preserved, not overwritten with an empty list")
        XCTAssertEqual(groups?.first?["name"] as? String, "PROXY")

        let rules = written["rules"] as? [String]
        XCTAssertEqual(rules, ["MATCH,PROXY"], "the subscription's real rules must be preserved, not the MATCH,DIRECT fallback")

        // Injected runtime fields still take effect on top of the imported config.
        XCTAssertEqual(written["mixed-port"] as? Int, 7890)
        XCTAssertEqual(written["external-controller"] as? String, "127.0.0.1:9090")
        XCTAssertEqual(written["secret"] as? String, "s3cr3t")
    }

    func testPlainProxiesListSubscriptionStillWorksAsBefore() throws {
        let subscriptionYAML = """
        proxies:
          - name: node-1
            type: ss
            server: 1.2.3.4
            port: 443
            cipher: aes-256-gcm
            password: hunter2
        proxy-groups:
          - name: PROXY
            type: select
            proxies:
              - node-1
        rules:
          - MATCH,PROXY
        """

        let config = try writer.write(
            version: "v1",
            credentials: ControlAPICredentials(port: 9090, secret: "s3cr3t"),
            mixedPort: 7890,
            subscriptionYAML: subscriptionYAML,
            modeOverride: nil
        )

        let written = try readWrittenConfig(config)
        let proxies = written["proxies"] as? [[String: Any]]
        XCTAssertEqual(proxies?.count, 1)
        XCTAssertEqual(proxies?.first?["name"] as? String, "node-1")
    }

    func testNoSubscriptionFallsBackToEmptyPassthroughConfig() throws {
        let config = try writer.write(
            version: "v1",
            credentials: ControlAPICredentials(port: 9090, secret: "s3cr3t"),
            mixedPort: 7890,
            subscriptionYAML: nil,
            modeOverride: nil
        )

        let written = try readWrittenConfig(config)
        XCTAssertEqual(written["proxies"] as? [Any], [])
        XCTAssertEqual(written["proxy-groups"] as? [Any], [])
        XCTAssertNil(written["proxy-providers"], "no subscription means no proxy-providers, not a fabricated one")
    }

    func testModeOverrideTakesPrecedenceOverEmbeddedMode() throws {
        let subscriptionYAML = """
        mode: global
        proxies: []
        """

        let config = try writer.write(
            version: "v1",
            credentials: ControlAPICredentials(port: 9090, secret: "s3cr3t"),
            mixedPort: 7890,
            subscriptionYAML: subscriptionYAML,
            modeOverride: "direct"
        )

        let written = try readWrittenConfig(config)
        XCTAssertEqual(written["mode"] as? String, "direct")
    }

    func testEmbeddedModeUsedWhenNoOverrideGiven() throws {
        let subscriptionYAML = """
        mode: global
        proxies: []
        """

        let config = try writer.write(
            version: "v1",
            credentials: ControlAPICredentials(port: 9090, secret: "s3cr3t"),
            mixedPort: 7890,
            subscriptionYAML: subscriptionYAML,
            modeOverride: nil
        )

        let written = try readWrittenConfig(config)
        XCTAssertEqual(written["mode"] as? String, "global")
    }
}
