import Foundation
import XCTest
@testable import mihomo_cli

final class HTTPKernelClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testVersionSendsBearerTokenAndDecodesResponse() async throws {
        StubURLProtocol.enqueue(.json(["version": "v1.19.10", "meta": true]))
        let client = makeClient()

        let version = try await client.version()

        XCTAssertEqual(version, VersionInfo(version: "v1.19.10", meta: true))
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(StubURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        XCTAssertEqual(StubURLProtocol.requests[0].url?.path, "/version")
    }

    func testGetConfigsRunsReachabilityPreflightThenDecodesConfigs() async throws {
        StubURLProtocol.enqueue(.json(["version": "v1.19.10", "meta": true]))
        StubURLProtocol.enqueue(.json(["mode": "rule", "mixed-port": 7890]))
        let client = makeClient()

        let configs = try await client.getConfigs()

        XCTAssertEqual(configs, Configs(mode: "rule", mixedPort: 7890))
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.path }, ["/version", "/configs"])
    }

    func testPatchConfigsSendsModePatchAndAcceptsNoBody204() async throws {
        StubURLProtocol.enqueue(.json(["version": "v1.19.10", "meta": true]))
        StubURLProtocol.enqueue(.status(204))
        let client = makeClient()

        try await client.patchConfigs(ConfigsPatch(mode: "global"))

        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.path }, ["/version", "/configs"])
        XCTAssertEqual(StubURLProtocol.requests[1].httpMethod, "PATCH")
        XCTAssertEqual(StubURLProtocol.requests[1].value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(StubURLProtocol.requests[1].httpBodyStream?.readAllData())
        let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
        XCTAssertEqual(json?["mode"], "global")
    }

    func testGetProxiesUsesGroupEndpointAndDecodesPolicyGroups() async throws {
        StubURLProtocol.enqueue(.json(["version": "v1.19.10", "meta": true]))
        StubURLProtocol.enqueue(.json([
            "Proxy": [
                "name": "Proxy",
                "now": "Node A",
                "all": ["Node A", "Node B"],
            ],
        ]))
        let client = makeClient()

        let groups = try await client.getProxies()

        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.path }, ["/version", "/group"])
        XCTAssertEqual(groups.groups["Proxy"], ProxyGroups.Group(name: "Proxy", now: "Node A", all: ["Node A", "Node B"]))
    }

    func testSelectProxySendsNodeNameToProxyGroupEndpoint() async throws {
        StubURLProtocol.enqueue(.json(["version": "v1.19.10", "meta": true]))
        StubURLProtocol.enqueue(.status(204))
        let client = makeClient()

        try await client.selectProxy(group: "Auto Select", node: "Node B")

        let encodedPaths = StubURLProtocol.requests.map { request in
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath }
        }
        XCTAssertEqual(encodedPaths, ["/version", "/proxies/Auto%20Select"])
        XCTAssertEqual(StubURLProtocol.requests[1].httpMethod, "PUT")
        let body = try XCTUnwrap(StubURLProtocol.requests[1].httpBodyStream?.readAllData())
        let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
        XCTAssertEqual(json?["name"], "Node B")
    }

    func testGetConnectionsDecodesArrayAndDerivesCount() async throws {
        StubURLProtocol.enqueue(.json(["version": "v1.19.10", "meta": true]))
        StubURLProtocol.enqueue(.json([
            "downloadTotal": 12,
            "uploadTotal": 34,
            "connections": [
                ["id": "a", "upload": 1, "download": 2],
                ["id": "b", "upload": 3, "download": 4],
            ],
        ]))
        let client = makeClient()

        let snapshot = try await client.getConnections()

        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.path }, ["/version", "/connections"])
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.downloadTotal, 12)
        XCTAssertEqual(snapshot.uploadTotal, 34)
    }

    func testCloseConnectionsSendsDelete() async throws {
        StubURLProtocol.enqueue(.json(["version": "v1.19.10", "meta": true]))
        StubURLProtocol.enqueue(.status(204))
        let client = makeClient()

        try await client.closeConnections()

        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.path }, ["/version", "/connections"])
        XCTAssertEqual(StubURLProtocol.requests[1].httpMethod, "DELETE")
    }

    func testAuthFailureMapsToPermissionDeniedCLIError() async throws {
        StubURLProtocol.enqueue(.status(401))
        let client = makeClient()

        do {
            _ = try await client.getConfigs()
            XCTFail("expected auth failure")
        } catch let error as CLIError {
            XCTAssertEqual(error.exitCode, .permissionDenied)
            XCTAssertTrue(error.description.contains("stored secret is stale"))
        }
    }

    func testMalformedJSONMapsToValidationFailure() async throws {
        StubURLProtocol.enqueue(.data("{".data(using: .utf8)!))
        let client = makeClient()

        do {
            _ = try await client.version()
            XCTFail("expected decode failure")
        } catch let error as CLIError {
            XCTAssertEqual(error.exitCode, .validationFailure)
        }
    }

    func testEndpointNotFoundMapsToNotFoundCLIError() async throws {
        StubURLProtocol.enqueue(.json(["version": "v1.19.10", "meta": true]))
        StubURLProtocol.enqueue(.status(404))
        let client = makeClient()

        do {
            _ = try await client.getConnections()
            XCTFail("expected not found")
        } catch let error as CLIError {
            XCTAssertEqual(error.exitCode, .notFound)
        }
    }

    func testTransportFailureMapsToNoKernelRunning() async throws {
        StubURLProtocol.enqueue(.failure(URLError(.cannotConnectToHost)))
        let client = makeClient()

        do {
            _ = try await client.version()
            XCTFail("expected transport failure")
        } catch let error as CLIError {
            XCTAssertEqual(error.exitCode, .permissionDenied)
            XCTAssertTrue(error.description.contains("no kernel running"))
        }
    }

    func testLivenessCheckReportsHealthyWhenVersionAndConfigMatch() async throws {
        StubURLProtocol.enqueue(.json(["version": "v1.19.10", "meta": true]))
        StubURLProtocol.enqueue(.json(["version": "v1.19.10", "meta": true]))
        StubURLProtocol.enqueue(.json(["mode": "direct", "mixed-port": 7890]))
        let client = makeClient()

        let result = try await client.livenessCheck(
            expectedVersion: "v1.19.10",
            expectedConfigPatch: ConfigsPatch(mode: "direct")
        )

        XCTAssertEqual(result, .healthy)
    }

    func testLivenessCheckReportsVersionMismatch() async throws {
        StubURLProtocol.enqueue(.json(["version": "v1.19.9", "meta": true]))
        let client = makeClient()

        let result = try await client.livenessCheck(expectedVersion: "v1.19.10", expectedConfigPatch: nil)

        XCTAssertEqual(result, .versionMismatch(expected: "v1.19.10", actual: "v1.19.9"))
    }

    func testLivenessCheckReportsConfigMismatch() async throws {
        StubURLProtocol.enqueue(.json(["version": "v1.19.10", "meta": true]))
        StubURLProtocol.enqueue(.json(["version": "v1.19.10", "meta": true]))
        StubURLProtocol.enqueue(.json(["mode": "rule", "mixed-port": 7890]))
        let client = makeClient()

        let result = try await client.livenessCheck(
            expectedVersion: "v1.19.10",
            expectedConfigPatch: ConfigsPatch(mode: "global")
        )

        XCTAssertEqual(result, .configMismatch(field: "mode", expected: "global", actual: "rule"))
    }

    func testLivenessCheckReportsUnresponsive() async throws {
        StubURLProtocol.enqueue(.failure(URLError(.timedOut)))
        let client = makeClient()

        let result = try await client.livenessCheck(expectedVersion: "v1.19.10", expectedConfigPatch: nil)

        guard case .unresponsive(let reason) = result else {
            return XCTFail("expected unresponsive, got \(result)")
        }
        XCTAssertTrue(reason.contains("no kernel running"))
    }

    private func makeClient() -> HTTPKernelClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return HTTPKernelClient(port: 9090, secret: "test-secret", session: session)
    }
}

private final class StubURLProtocol: URLProtocol {
    struct Response {
        var statusCode: Int
        var data: Data
        var error: Error?

        static func status(_ statusCode: Int) -> Response {
            Response(statusCode: statusCode, data: Data())
        }

        static func data(_ data: Data, statusCode: Int = 200) -> Response {
            Response(statusCode: statusCode, data: data)
        }

        static func json(_ object: Any, statusCode: Int = 200) -> Response {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return Response(statusCode: statusCode, data: data)
        }

        static func failure(_ error: Error) -> Response {
            Response(statusCode: 0, data: Data(), error: error)
        }
    }

    nonisolated(unsafe) private static var queuedResponses: [Response] = []
    nonisolated(unsafe) private(set) static var requests: [URLRequest] = []

    static func enqueue(_ response: Response) {
        queuedResponses.append(response)
    }

    static func reset() {
        queuedResponses = []
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.append(request)
        let response = Self.queuedResponses.isEmpty ? .status(500) : Self.queuedResponses.removeFirst()
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension InputStream {
    func readAllData() -> Data {
        open()
        defer { close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while hasBytesAvailable {
            let count = read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
