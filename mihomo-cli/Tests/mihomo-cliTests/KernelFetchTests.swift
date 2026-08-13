import Foundation
import XCTest
@testable import mihomo_cli

final class KernelFetchTests: XCTestCase {
    func testDarwinARM64AssetPrefersExactStableAsset() throws {
        let release = makeRelease(
            tag: "v1.19.29",
            assets: [
                "mihomo-darwin-arm64-go124-v1.19.29.gz",
                "mihomo-darwin-arm64-v1.19.29.gz",
                "mihomo-darwin-amd64-v1.19.29.gz",
            ]
        )

        XCTAssertEqual(release.darwinARM64Asset()?.name, "mihomo-darwin-arm64-v1.19.29.gz")
    }

    func testDarwinARM64AssetFallsBackToPlainAlphaAsset() throws {
        let release = makeRelease(
            tag: "Prerelease-Alpha",
            prerelease: true,
            assets: [
                "mihomo-darwin-arm64-go124-alpha-7ee0b05.gz",
                "mihomo-darwin-arm64-alpha-7ee0b05.gz",
            ]
        )

        XCTAssertEqual(release.darwinARM64Asset()?.name, "mihomo-darwin-arm64-alpha-7ee0b05.gz")
    }

    func testFetchAllSkipsInstalledVersionsAndDownloadsMissingVersions() async throws {
        let releases = FakeReleaseProvider(latest: [
            makeRelease(tag: "v1.19.29"),
            makeRelease(tag: "v1.19.28"),
        ])
        let installer = FakeKernelInstaller()
        var installed = Set(["v1.19.28"])
        var registered: [KernelRecord] = []
        let service = KernelFetchService(
            releases: releases,
            installer: installer,
            installedKernel: { version in
                installed.contains(version)
                    ? KernelRecord(version: version, binaryPath: "/tmp/\(version)", addedAt: Date(), lastUsedAt: nil, isActive: false)
                    : nil
            },
            registerKernel: { record in
                installed.insert(record.version)
                registered.append(record)
            }
        )

        let summary = try await service.fetch(.latest(limit: 10))

        XCTAssertEqual(summary.latestStable, "v1.19.29")
        XCTAssertEqual(summary.outcomes, [
            KernelFetchOutcome(version: "v1.19.29", status: .downloaded),
            KernelFetchOutcome(version: "v1.19.28", status: .alreadyPresent),
        ])
        XCTAssertEqual(installer.installedVersions, ["v1.19.29"])
        XCTAssertEqual(registered.map(\.version), ["v1.19.29"])
    }

    func testFetchExplicitMissingTagPropagatesValidationFailureWithoutRegistering() async throws {
        let releases = FakeReleaseProvider(tagError: CLIError(
            what: "release not found",
            cause: "tag is not present in the upstream release list",
            exitCode: .validationFailure
        ))
        let installer = FakeKernelInstaller()
        var registered: [KernelRecord] = []
        let service = KernelFetchService(
            releases: releases,
            installer: installer,
            installedKernel: { _ in nil },
            registerKernel: { registered.append($0) }
        )

        do {
            _ = try await service.fetch(.tag("v0.0.0"))
            XCTFail("expected missing-tag failure")
        } catch let error as CLIError {
            XCTAssertEqual(error.exitCode, .validationFailure)
        }

        XCTAssertTrue(installer.installedVersions.isEmpty)
        XCTAssertTrue(registered.isEmpty)
    }

    func testFetchFailsSourceVerificationWhenReleaseHasNoDarwinARM64Asset() async throws {
        let releases = FakeReleaseProvider(tagged: makeRelease(tag: "v1.19.29", assets: ["mihomo-linux-arm64-v1.19.29.gz"]))
        let service = KernelFetchService(
            releases: releases,
            installer: FakeKernelInstaller(),
            installedKernel: { _ in nil },
            registerKernel: { _ in }
        )

        do {
            _ = try await service.fetch(.tag("v1.19.29"))
            XCTFail("expected missing asset failure")
        } catch let error as CLIError {
            XCTAssertEqual(error.exitCode, .sourceVerificationFailure)
        }
    }

    func testResumableDownloaderSendsRangeAndAppendsPartialDownload() async throws {
        DownloadStubURLProtocol.reset()
        DownloadStubURLProtocol.enqueue(.data("def".data(using: .utf8)!, statusCode: 206))

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mihomo-download-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let destination = tempDir.appendingPathComponent("mihomo.gz")
        try "abc".data(using: .utf8)!.write(to: destination.appendingPathExtension("partial"))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadStubURLProtocol.self]
        let downloader = ResumableDownloader(session: URLSession(configuration: configuration), maxRetries: 1)

        try await downloader.download(from: URL(string: "https://github.com/MetaCubeX/mihomo/releases/download/v1/mihomo.gz")!, to: destination)

        XCTAssertEqual(DownloadStubURLProtocol.requests.first?.value(forHTTPHeaderField: "Range"), "bytes=3-")
        XCTAssertEqual(try Data(contentsOf: destination), "abcdef".data(using: .utf8)!)
    }
}

private func makeRelease(
    tag: String,
    prerelease: Bool = false,
    assets names: [String] = ["mihomo-darwin-arm64-\(UUID().uuidString).gz"]
) -> GitHubRelease {
    GitHubRelease(
        tagName: tag,
        prerelease: prerelease,
        draft: false,
        publishedAt: Date(timeIntervalSince1970: 0),
        assets: names.map { name in
            GitHubRelease.Asset(
                name: name,
                browserDownloadURL: URL(string: "https://github.com/MetaCubeX/mihomo/releases/download/\(tag)/\(name)")!
            )
        }
    )
}

private final class FakeReleaseProvider: KernelReleaseProviding {
    let latest: [GitHubRelease]
    let tagged: GitHubRelease?
    let tagError: Error?

    init(latest: [GitHubRelease] = [], tagged: GitHubRelease? = nil, tagError: Error? = nil) {
        self.latest = latest
        self.tagged = tagged
        self.tagError = tagError
    }

    func latestReleases(limit: Int) async throws -> [GitHubRelease] {
        Array(latest.prefix(limit))
    }

    func release(tag: String) async throws -> GitHubRelease {
        if let tagError { throw tagError }
        return tagged ?? makeRelease(tag: tag)
    }
}

private final class FakeKernelInstaller: KernelInstalling {
    private(set) var installedVersions: [String] = []

    func install(release: GitHubRelease, asset: GitHubRelease.Asset) async throws -> KernelRecord {
        installedVersions.append(release.tagName)
        return KernelRecord(
            version: release.tagName,
            binaryPath: "/tmp/\(release.tagName)/mihomo",
            addedAt: Date(timeIntervalSince1970: 0),
            lastUsedAt: nil,
            isActive: false
        )
    }
}

private final class DownloadStubURLProtocol: URLProtocol {
    struct Response {
        let data: Data
        let statusCode: Int

        static func data(_ data: Data, statusCode: Int = 200) -> Response {
            Response(data: data, statusCode: statusCode)
        }
    }

    nonisolated(unsafe) private(set) static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var responses: [Response] = []

    static func enqueue(_ response: Response) {
        responses.append(response)
    }

    static func reset() {
        requests = []
        responses = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.append(request)
        let response = Self.responses.isEmpty ? .data(Data(), statusCode: 500) : Self.responses.removeFirst()
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
