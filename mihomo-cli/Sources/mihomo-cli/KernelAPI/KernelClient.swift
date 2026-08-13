import Foundation

/// Client for the running mihomo kernel's REST control API
/// (external-controller). Every command handler that needs to talk to the
/// kernel goes through this protocol rather than constructing HTTP requests
/// inline — see mihomo_control_api_integration_spec.md §7 for the rationale.
protocol KernelClient {
    func version() async throws -> VersionInfo
    func getConfigs() async throws -> Configs
    func patchConfigs(_ patch: ConfigsPatch) async throws
    func getProxies() async throws -> ProxyGroups
    func selectProxy(group: String, node: String) async throws // reserved, unused by any command in v2
    func getConnections() async throws -> ConnectionsSnapshot
    func closeConnections() async throws

    /// Composed liveness check implementing the three sub-checks from
    /// the integration spec §4: API responds, version matches (if given),
    /// and a readback of /configs confirms the change actually applied.
    /// This is the single most load-bearing piece of shared logic in the
    /// tool — every atomic switch in every command group calls this.
    func livenessCheck(expectedVersion: String?, expectedConfigPatch: ConfigsPatch?) async throws -> LivenessResult
}

// MARK: - Data types (fields intentionally minimal for the scaffold —
// expand to match the real Clash API response shapes during implementation)

struct VersionInfo: Decodable, Equatable {
    let version: String
    let meta: Bool
}

/// Field names and mapping confirmed against official mihomo API docs
/// (docs/mihomo_api_reference_notes.md) — response keys are kebab-case,
/// not camelCase, hence the explicit CodingKeys. Only the fields this tool
/// actually reads are decoded; /configs returns more than this (log-level,
/// allow-lan, ipv6, tun, socks-port, etc.) but nothing else here needs them.
struct Configs: Decodable, Equatable {
    let mode: String            // "rule" | "global" | "direct"
    let mixedPort: Int?

    enum CodingKeys: String, CodingKey {
        case mode
        case mixedPort = "mixed-port"
    }
}

/// PATCH /configs takes a partial JSON body and returns HTTP 204 with no
/// body on success — there is nothing to decode back. The only way to
/// confirm a patch actually took effect is a follow-up GET /configs
/// (see KernelClient.livenessCheck's config-readback sub-check).
struct ConfigsPatch: Encodable, Equatable {
    var mode: String?
    // TODO: other patchable fields as needed by `net`/`mode` commands
}

/// Decodes only what `net status`/`doctor` actually display: which node is
/// currently selected in each policy group. mihomo's real /proxies response
/// includes many more fields per entry (delay history, dialer-proxy, TFO/MPTCP
/// flags, etc. — see docs/mihomo_api_reference_notes.md) that this tool has
/// no use for and intentionally does not decode.
///
/// Consider using GET /group instead of GET /proxies at implementation time —
/// /group returns only policy groups (Selector/URLTest/Fallback/LoadBalance),
/// which is this tool's actual scope; /proxies also includes individual leaf
/// proxies this tool never displays or switches independently.
struct ProxyGroups: Decodable, Equatable {
    struct Group: Decodable, Equatable {
        let name: String
        let now: String?        // absent for LoadBalance groups
        let all: [String]
    }
    let groups: [String: Group]

    enum CodingKeys: String, CodingKey {
        case proxies
    }

    init(groups: [String: Group]) {
        self.groups = groups
    }

    init(from decoder: Decoder) throws {
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        if let proxies = try keyed.decodeIfPresent([String: Group].self, forKey: .proxies) {
            self.groups = proxies
            return
        }

        self.groups = try [String: Group](from: decoder)
    }
}

/// GET /connections has no direct "count" field — the real response is
/// downloadTotal/uploadTotal/memory plus a `connections` array; count is
/// derived client-side from the array, not decoded directly.
struct ConnectionsSnapshot: Decodable, Equatable {
    struct ConnectionEntry: Decodable, Equatable {
        let id: String
        let upload: Int
        let download: Int
        // metadata/chains/rule fields intentionally omitted — not needed
        // by any command in this tool's v2 scope (see reference notes).
    }
    let downloadTotal: Int
    let uploadTotal: Int
    let connections: [ConnectionEntry]

    var count: Int { connections.count }
}

enum LivenessResult: Equatable {
    case healthy
    case unresponsive(String)        // connect/request timeout — maps to CLIError with fix "check 'mihomo log'"
    case versionMismatch(expected: String, actual: String)
    case configMismatch(field: String, expected: String, actual: String)
}

// MARK: - Default HTTP-backed implementation

/// Talks to `127.0.0.1:<port>` with the manager-generated secret as a
/// Bearer token. Port and secret are read from the manager's local
/// metadata store (see integration spec §2), never from the user's
/// subscription file.
final class HTTPKernelClient: KernelClient {
    private let baseURL: URL
    private let secret: String
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let connectTimeout: TimeInterval = 0.5
    private let requestTimeout: TimeInterval = 5.0

    convenience init(port: Int, secret: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5.0
        configuration.timeoutIntervalForResource = 5.0
        self.init(port: port, secret: secret, session: URLSession(configuration: configuration))
    }

    init(port: Int, secret: String, session: URLSession) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.secret = secret
        self.session = session
    }

    func version() async throws -> VersionInfo {
        try await requestJSON("version", method: "GET", timeout: connectTimeout, preflight: false)
    }

    func getConfigs() async throws -> Configs {
        try await requestJSON("configs", method: "GET")
    }

    func patchConfigs(_ patch: ConfigsPatch) async throws {
        let body = try encoder.encode(patch)
        try await requestNoBody("configs", method: "PATCH", body: body)
    }

    func getProxies() async throws -> ProxyGroups {
        try await requestJSON("group", method: "GET")
    }

    func selectProxy(group: String, node: String) async throws {
        struct Selection: Encodable {
            let name: String
        }
        let body = try encoder.encode(Selection(name: node))
        try await requestNoBody("proxies/\(group)", method: "PUT", body: body)
    }

    func getConnections() async throws -> ConnectionsSnapshot {
        try await requestJSON("connections", method: "GET")
    }

    func closeConnections() async throws {
        try await requestNoBody("connections", method: "DELETE")
    }

    func livenessCheck(expectedVersion: String?, expectedConfigPatch: ConfigsPatch?) async throws -> LivenessResult {
        let versionInfo: VersionInfo
        do {
            versionInfo = try await version()
        } catch {
            return .unresponsive(errorDescription(error))
        }

        if let expectedVersion, versionInfo.version != expectedVersion {
            return .versionMismatch(expected: expectedVersion, actual: versionInfo.version)
        }

        if let expectedConfigPatch {
            do {
                let configs = try await getConfigs()
                if let expectedMode = expectedConfigPatch.mode, configs.mode != expectedMode {
                    return .configMismatch(field: "mode", expected: expectedMode, actual: configs.mode)
                }
            } catch {
                return .unresponsive(errorDescription(error))
            }
        }

        return .healthy
    }

    private func requestJSON<T: Decodable>(
        _ path: String,
        method: String,
        timeout: TimeInterval? = nil,
        preflight: Bool = true
    ) async throws -> T {
        let data = try await requestData(path, method: method, timeout: timeout, preflight: preflight)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw CLIError(
                what: "could not decode control API response",
                cause: "\(method) /\(path) returned JSON that does not match the expected schema (\(error.localizedDescription))",
                fix: "confirm the running mihomo version matches the API schema in docs/mihomo_api_reference_notes.md",
                exitCode: .validationFailure
            )
        }
    }

    private func requestNoBody(
        _ path: String,
        method: String,
        body: Data? = nil,
        timeout: TimeInterval? = nil,
        preflight: Bool = true
    ) async throws {
        _ = try await requestData(path, method: method, body: body, timeout: timeout, preflight: preflight)
    }

    private func requestData(
        _ path: String,
        method: String,
        body: Data? = nil,
        timeout: TimeInterval? = nil,
        preflight: Bool = true
    ) async throws -> Data {
        if preflight {
            try await ensureReachable()
        }

        var request = makeRequest(path, method: method, timeout: timeout ?? requestTimeout)
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw mapTransportError(error, path: path)
        }

        try validate(response: response, path: path)
        return data
    }

    private func ensureReachable() async throws {
        var request = makeRequest("version", method: "GET", timeout: connectTimeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await session.data(for: request)
            try validate(response: response, path: "version")
        } catch {
            if let cliError = error as? CLIError {
                throw cliError
            }
            throw mapTransportError(error, path: "version")
        }
    }

    private func makeRequest(_ path: String, method: String, timeout: TimeInterval) -> URLRequest {
        let encodedPath = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = "/" + encodedPath
        let url = components.url!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func validate(response: URLResponse, path: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CLIError(
                what: "invalid control API response",
                cause: "/\(path) did not return an HTTP response",
                exitCode: .networkError
            )
        }

        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw CLIError(
                what: "control API rejected the request",
                cause: "stored secret is stale or invalid",
                fix: "run 'mihomo restart' to resync the manager-generated secret",
                exitCode: .permissionDenied
            )
        case 404:
            throw CLIError(
                what: "control API endpoint not found",
                cause: "/\(path) is not exposed by the running mihomo process",
                fix: "confirm the running mihomo version supports the required API endpoint",
                exitCode: .notFound
            )
        default:
            throw CLIError(
                what: "control API request failed",
                cause: "/\(path) returned HTTP \(http.statusCode)",
                fix: "check 'mihomo log' for the kernel-side failure",
                exitCode: .networkError
            )
        }
    }

    private func mapTransportError(_ error: Error, path: String) -> CLIError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCannotConnectToHost,
                 NSURLErrorTimedOut,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet:
                return CLIError(
                    what: "no kernel running",
                    cause: "control API /\(path) is not reachable on \(baseURL.host ?? "127.0.0.1"):\(baseURL.port ?? 0)",
                    fix: "run 'mihomo start' first",
                    exitCode: .permissionDenied
                )
            default:
                break
            }
        }

        return CLIError(
            what: "control API request failed",
            cause: error.localizedDescription,
            fix: "check 'mihomo log' for the kernel-side failure",
            exitCode: .networkError
        )
    }

    private func errorDescription(_ error: Error) -> String {
        if let cliError = error as? CLIError {
            return cliError.description
        }
        return error.localizedDescription
    }
}
