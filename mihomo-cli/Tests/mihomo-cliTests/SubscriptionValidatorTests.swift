import XCTest
@testable import mihomo_cli

final class SubscriptionValidatorTests: XCTestCase {

    private func fixtureURL(named name: String) -> URL {
        // Look up fixture relative to current test file / working directory
        let packageDir = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/subscriptions/\(name)")
        return packageDir
    }

    private func loadFixture(named name: String) throws -> String {
        let url = fixtureURL(named: name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testValidMinimalFixture() throws {
        let yaml = try loadFixture(named: "valid_minimal.yaml")
        let result = SubscriptionValidator.validate(yamlString: yaml)

        XCTAssertTrue(result.isValid, "Expected valid_minimal.yaml to be valid, but got issues: \(result.issues)")
        XCTAssertEqual(result.issues.count, 0)
        XCTAssertEqual(result.embeddedMode, "rule")
    }

    func testValidFullFixture() throws {
        let yaml = try loadFixture(named: "valid_full.yaml")
        let result = SubscriptionValidator.validate(yamlString: yaml)

        XCTAssertTrue(result.isValid, "Expected valid_full.yaml to be valid, but got issues: \(result.issues)")
        XCTAssertEqual(result.issues.count, 0)
        XCTAssertEqual(result.embeddedMode, "rule")
    }

    func testInvalidSyntaxFixture() throws {
        let yaml = try loadFixture(named: "invalid_syntax.yaml")
        let result = SubscriptionValidator.validate(yamlString: yaml)

        XCTAssertFalse(result.isValid)
        XCTAssertGreaterThanOrEqual(result.issues.count, 1)
        XCTAssertNotNil(result.issues.first?.line)
        XCTAssertTrue(result.issues.first?.message.contains("YAML syntax error") ?? false)
    }

    func testInvalidProxyTypeFixture() throws {
        let yaml = try loadFixture(named: "invalid_proxy_type.yaml")
        let result = SubscriptionValidator.validate(yamlString: yaml)

        XCTAssertFalse(result.isValid)
        let typeIssue = result.issues.first { $0.message.contains("unknown proxy type 'vmess2'") }
        XCTAssertNotNil(typeIssue, "Expected unknown proxy type 'vmess2' issue")
        XCTAssertEqual(typeIssue?.line, 4) // line 4 in invalid_proxy_type.yaml
    }

    func testInvalidGroupReferenceFixture() throws {
        let yaml = try loadFixture(named: "invalid_group_reference.yaml")
        let result = SubscriptionValidator.validate(yamlString: yaml)

        XCTAssertFalse(result.isValid)
        let groupIssue = result.issues.first { $0.message.contains("references non-existent proxy 'Node-99'") }
        XCTAssertNotNil(groupIssue, "Expected non-existent proxy 'Node-99' issue")
        XCTAssertEqual(groupIssue?.line, 11)

        let ruleIssue = result.issues.first { $0.message.contains("references unknown proxy or proxy group 'NON_EXISTENT_GROUP'") }
        XCTAssertNotNil(ruleIssue, "Expected unknown proxy group rule issue")
        XCTAssertEqual(ruleIssue?.line, 13)
    }

    func testInvalidRuleProviderFixture() throws {
        let yaml = try loadFixture(named: "invalid_rule_provider.yaml")
        let result = SubscriptionValidator.validate(yamlString: yaml)

        XCTAssertFalse(result.isValid)
        let providerIssue = result.issues.first { $0.message.contains("rule-provider 'ads' has no matching path or url") }
        XCTAssertNotNil(providerIssue, "Expected rule-provider 'ads' path/url missing issue")
        XCTAssertEqual(providerIssue?.line, 13)

        let ruleIssue = result.issues.first { $0.message.contains("rule references undeclared rule-provider 'dangling_ruleset'") }
        XCTAssertNotNil(ruleIssue, "Expected undeclared rule-provider issue")
        XCTAssertEqual(ruleIssue?.line, 18)
    }

    func testFormatErrorOutput() {
        let issues = [
            ValidationIssue(line: 14, message: "unknown proxy type 'vmess2'"),
            ValidationIssue(line: 41, message: "rule-provider 'ads' has no matching path or url")
        ]
        let formatted = SubscriptionValidator.formatErrorOutput(issues: issues)

        let expected = """
        error: subscription rejected — 2 validation errors
          line 14: unknown proxy type 'vmess2'
          line 41: rule-provider 'ads' has no matching path or url
        """
        XCTAssertEqual(formatted, expected)
    }
}
