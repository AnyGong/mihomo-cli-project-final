import Foundation
import Yams

/// Structured representation of a single validation problem with optional line number.
struct ValidationIssue: Equatable {
    let line: Int?
    let message: String
}

/// Outcome of validating a subscription YAML.
struct ValidationResult: Equatable {
    let isValid: Bool
    let issues: [ValidationIssue]
    /// The `mode` specified inside the subscription file (if any, e.g. "rule", "global", "direct").
    let embeddedMode: String?
}

/// Core YAML and semantic validator for subscription configurations.
/// Implements full-link pre-flight validation (Design Doc §4.1.3, Full Spec §1.2.2).
struct SubscriptionValidator {

    private static let validProxyTypes: Set<String> = [
        "ss", "shadowsocks", "ssr", "shadowsocksr",
        "vmess", "vless", "trojan",
        "hysteria", "hysteria2", "hy", "hy2",
        "wireguard", "wg",
        "http", "https", "socks5", "socks5s", "socks",
        "tuic", "snell", "ssh", "mihomo"
    ]

    private static let validGroupTypes: Set<String> = [
        "select", "url-test", "fallback", "load-balance", "relay"
    ]

    private static let builtInTargets: Set<String> = [
        "DIRECT", "REJECT", "GLOBAL", "COMPATIBLE", "PASS",
        "direct", "reject", "global", "compatible", "pass"
    ]

    /// Validates a raw YAML string and returns a `ValidationResult`.
    static func validate(yamlString: String) -> ValidationResult {
        var issues: [ValidationIssue] = []

        // 1. YAML Syntax Check via Yams AST Constructor
        let rootNode: Node
        do {
            guard let node = try Yams.compose(yaml: yamlString) else {
                return ValidationResult(
                    isValid: false,
                    issues: [ValidationIssue(line: 1, message: "subscription content is empty")],
                    embeddedMode: nil
                )
            }
            rootNode = node
        } catch let yamlError as YamlError {
            var line: Int?
            var problemMsg = yamlError.localizedDescription
            switch yamlError {
            case .reader(let problem, _, _, _):
                problemMsg = problem
            case .scanner(_, let problem, let mark, _):
                line = mark.line
                problemMsg = problem
            case .parser(_, let problem, let mark, _):
                line = mark.line
                problemMsg = problem
            case .composer(_, let problem, let mark, _):
                line = mark.line
                problemMsg = problem
            default:
                break
            }
            return ValidationResult(
                isValid: false,
                issues: [ValidationIssue(line: line, message: "YAML syntax error: \(problemMsg)")],
                embeddedMode: nil
            )
        } catch {
            return ValidationResult(
                isValid: false,
                issues: [ValidationIssue(line: 1, message: "YAML parse error: \(error.localizedDescription)")],
                embeddedMode: nil
            )
        }

        guard let rootMapping = rootNode.mapping else {
            return ValidationResult(
                isValid: false,
                issues: [ValidationIssue(line: rootNode.mark?.line, message: "root element must be a YAML mapping/dictionary")],
                embeddedMode: nil
            )
        }

        var embeddedMode: String?
        var declaredProxyNames = Set<String>()
        var declaredGroupNames = Set<String>()
        var declaredProviderNames = Set<String>()

        // Helper to find mapping entry by key
        func entry(for key: String) -> (keyNode: Node, valueNode: Node)? {
            for (k, v) in rootMapping {
                if k.string == key {
                    return (k, v)
                }
            }
            return nil
        }

        // 2. Validate `mode` if present
        if let (_, modeNode) = entry(for: "mode") {
            if let m = modeNode.string?.lowercased() {
                embeddedMode = m
                if !["rule", "global", "direct"].contains(m) {
                    issues.append(ValidationIssue(
                        line: modeNode.mark?.line,
                        message: "invalid mode '\(modeNode.string ?? "")' — must be 'rule', 'global', or 'direct'"
                    ))
                }
            } else {
                issues.append(ValidationIssue(
                    line: modeNode.mark?.line,
                    message: "'mode' must be a string ('rule', 'global', or 'direct')"
                ))
            }
        }

        // 3. Validate `proxies`
        if let (_, proxiesNode) = entry(for: "proxies") {
            if let sequence = proxiesNode.sequence {
                for item in sequence {
                    guard let proxyMap = item.mapping else {
                        issues.append(ValidationIssue(line: item.mark?.line, message: "proxy entry must be a mapping"))
                        continue
                    }

                    var name: String?
                    var type: String?
                    var typeNode: Node?
                    for (k, v) in proxyMap {
                        if k.string == "name" { name = v.string }
                        if k.string == "type" { type = v.string; typeNode = v }
                    }

                    guard let pName = name, !pName.isEmpty else {
                        issues.append(ValidationIssue(line: item.mark?.line, message: "proxy entry missing required 'name'"))
                        continue
                    }

                    if declaredProxyNames.contains(pName) {
                        issues.append(ValidationIssue(line: item.mark?.line, message: "duplicate proxy name '\(pName)'"))
                    } else {
                        declaredProxyNames.insert(pName)
                    }

                    guard let pType = type?.lowercased(), !pType.isEmpty else {
                        issues.append(ValidationIssue(line: item.mark?.line, message: "proxy '\(pName)' missing required 'type'"))
                        continue
                    }

                    if !validProxyTypes.contains(pType) {
                        issues.append(ValidationIssue(
                            line: typeNode?.mark?.line ?? item.mark?.line,
                            message: "unknown proxy type '\(type ?? "")'"
                        ))
                    }
                }
            } else {
                issues.append(ValidationIssue(line: proxiesNode.mark?.line, message: "'proxies' must be a list"))
            }
        }

        // 4. Validate `proxy-groups`
        if let (_, groupsNode) = entry(for: "proxy-groups") {
            if let sequence = groupsNode.sequence {
                for item in sequence {
                    guard let groupMap = item.mapping else {
                        issues.append(ValidationIssue(line: item.mark?.line, message: "proxy-group entry must be a mapping"))
                        continue
                    }

                    var name: String?
                    var type: String?
                    var typeNode: Node?
                    for (k, v) in groupMap {
                        if k.string == "name" { name = v.string }
                        if k.string == "type" { type = v.string; typeNode = v }
                    }

                    guard let gName = name, !gName.isEmpty else {
                        issues.append(ValidationIssue(line: item.mark?.line, message: "proxy-group missing required 'name'"))
                        continue
                    }

                    if declaredGroupNames.contains(gName) {
                        issues.append(ValidationIssue(line: item.mark?.line, message: "duplicate proxy group name '\(gName)'"))
                    } else {
                        declaredGroupNames.insert(gName)
                    }

                    guard let gType = type?.lowercased(), !gType.isEmpty else {
                        issues.append(ValidationIssue(line: item.mark?.line, message: "proxy group '\(gName)' missing required 'type'"))
                        continue
                    }

                    if !validGroupTypes.contains(gType) {
                        issues.append(ValidationIssue(
                            line: typeNode?.mark?.line ?? item.mark?.line,
                            message: "unknown proxy group type '\(type ?? "")'"
                        ))
                    }
                }
            } else {
                issues.append(ValidationIssue(line: groupsNode.mark?.line, message: "'proxy-groups' must be a list"))
            }
        }

        // 5. Validate `rule-providers`
        if let (_, providersNode) = entry(for: "rule-providers") {
            if let mapping = providersNode.mapping {
                for (kNode, vNode) in mapping {
                    guard let pName = kNode.string, !pName.isEmpty else {
                        issues.append(ValidationIssue(line: kNode.mark?.line, message: "rule-provider missing name"))
                        continue
                    }
                    declaredProviderNames.insert(pName)

                    guard let pMap = vNode.mapping else {
                        issues.append(ValidationIssue(line: vNode.mark?.line, message: "rule-provider '\(pName)' must be a mapping"))
                        continue
                    }

                    var pType: String?
                    var pPath: String?
                    var pUrl: String?

                    for (pk, pv) in pMap {
                        if pk.string == "type" { pType = pv.string?.lowercased() }
                        if pk.string == "path" { pPath = pv.string }
                        if pk.string == "url" { pUrl = pv.string }
                    }

                    // Check path / url presence per spec: "rule-provider 'ads' has no matching path or url"
                    if pPath == nil && pUrl == nil {
                        issues.append(ValidationIssue(
                            line: kNode.mark?.line ?? vNode.mark?.line,
                            message: "rule-provider '\(pName)' has no matching path or url"
                        ))
                    } else if pType == "http" && (pUrl == nil || pUrl?.isEmpty == true) {
                        issues.append(ValidationIssue(
                            line: kNode.mark?.line ?? vNode.mark?.line,
                            message: "rule-provider '\(pName)' of type 'http' requires a 'url'"
                        ))
                    }
                }
            } else {
                issues.append(ValidationIssue(line: providersNode.mark?.line, message: "'rule-providers' must be a mapping"))
            }
        }

        // 6. Validate group member references (semantic validation)
        if let (_, groupsNode) = entry(for: "proxy-groups"), let sequence = groupsNode.sequence {
            for item in sequence {
                guard let groupMap = item.mapping else { continue }
                var groupName = "unknown"
                var memberSequence: Node.Sequence?

                for (k, v) in groupMap {
                    if k.string == "name" { groupName = v.string ?? "unknown" }
                    if k.string == "proxies" { memberSequence = v.sequence }
                }

                if let members = memberSequence {
                    for memberNode in members {
                        guard let memberName = memberNode.string else { continue }
                        let isKnown = declaredProxyNames.contains(memberName)
                            || declaredGroupNames.contains(memberName)
                            || builtInTargets.contains(memberName)

                        if !isKnown {
                            issues.append(ValidationIssue(
                                line: memberNode.mark?.line ?? item.mark?.line,
                                message: "proxy group '\(groupName)' references non-existent proxy '\(memberName)'"
                            ))
                        }
                    }
                }
            }
        }

        // 7. Validate `rules`
        if let (_, rulesNode) = entry(for: "rules") {
            if let sequence = rulesNode.sequence {
                for item in sequence {
                    guard let ruleStr = item.string?.trimmingCharacters(in: .whitespacesAndNewlines), !ruleStr.isEmpty else {
                        issues.append(ValidationIssue(line: item.mark?.line, message: "rule entry must be a non-empty string"))
                        continue
                    }

                    let parts = ruleStr.split(separator: ",", omittingEmptySubsequences: false).map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }

                    guard !parts.isEmpty else { continue }
                    let ruleType = parts[0].uppercased()

                    if ruleType == "MATCH" {
                        if parts.count >= 2 {
                            let target = parts[1]
                            checkRuleTarget(target, line: item.mark?.line, issues: &issues)
                        } else {
                            issues.append(ValidationIssue(line: item.mark?.line, message: "MATCH rule missing target policy"))
                        }
                    } else if ruleType == "RULE-SET" {
                        if parts.count >= 3 {
                            let providerName = parts[1]
                            let target = parts[2]
                            if !declaredProviderNames.contains(providerName) {
                                issues.append(ValidationIssue(
                                    line: item.mark?.line,
                                    message: "rule references undeclared rule-provider '\(providerName)'"
                                ))
                            }
                            checkRuleTarget(target, line: item.mark?.line, issues: &issues)
                        } else {
                            issues.append(ValidationIssue(line: item.mark?.line, message: "RULE-SET rule format must be RULE-SET,<provider>,<target>"))
                        }
                    } else if parts.count >= 3 {
                        let target = parts[2]
                        checkRuleTarget(target, line: item.mark?.line, issues: &issues)
                    } else if parts.count < 3 && ruleType != "NOT" && ruleType != "AND" && ruleType != "OR" {
                        issues.append(ValidationIssue(
                            line: item.mark?.line,
                            message: "malformed rule '\(ruleStr)'"
                        ))
                    }
                }
            } else {
                issues.append(ValidationIssue(line: rulesNode.mark?.line, message: "'rules' must be a list"))
            }
        }

        func checkRuleTarget(_ target: String, line: Int?, issues: inout [ValidationIssue]) {
            let isKnown = declaredProxyNames.contains(target)
                || declaredGroupNames.contains(target)
                || builtInTargets.contains(target)

            if !isKnown {
                issues.append(ValidationIssue(
                    line: line,
                    message: "rule references unknown proxy or proxy group '\(target)'"
                ))
            }
        }

        return ValidationResult(
            isValid: issues.isEmpty,
            issues: issues,
            embeddedMode: embeddedMode
        )
    }

    /// Formats a list of validation issues into the spec's exact error string format.
    static func formatErrorOutput(issues: [ValidationIssue]) -> String {
        let count = issues.count
        let s = count == 1 ? "" : "s"
        var lines = ["error: subscription rejected — \(count) validation error\(s)"]
        for issue in issues {
            if let line = issue.line {
                lines.append("  line \(line): \(issue.message)")
            } else {
                lines.append("  \(issue.message)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
