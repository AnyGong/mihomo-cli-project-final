import Foundation

struct GitHubRelease: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let prerelease: Bool
    let draft: Bool
    let publishedAt: Date?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case prerelease
        case draft
        case publishedAt = "published_at"
        case assets
    }

    var isStable: Bool {
        !draft && !prerelease
    }

    func darwinARM64Asset() -> Asset? {
        let candidates = assets.filter { asset in
            let name = asset.name.lowercased()
            return name.hasPrefix("mihomo-darwin-arm64") && name.hasSuffix(".gz")
        }

        if let exact = candidates.first(where: { $0.name == "mihomo-darwin-arm64-\(tagName).gz" }) {
            return exact
        }

        if let plain = candidates.first(where: { !$0.name.lowercased().contains("-go") }) {
            return plain
        }

        return candidates.first
    }
}

protocol KernelReleaseProviding {
    func latestReleases(limit: Int) async throws -> [GitHubRelease]
    func release(tag: String) async throws -> GitHubRelease
}

final class GitHubKernelReleaseClient: KernelReleaseProviding {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    init(
        baseURL: URL = URL(string: "https://api.github.com/repos/MetaCubeX/mihomo")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func latestReleases(limit: Int = 10) async throws -> [GitHubRelease] {
        var components = URLComponents(url: baseURL.appendingPathComponent("releases"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "per_page", value: "\(limit)")]
        return try await request(components.url!)
    }

    func release(tag: String) async throws -> GitHubRelease {
        try await request(baseURL.appendingPathComponent("releases/tags/\(tag)"))
    }

    private func request<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("mihomo-cli", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CLIError(
                what: "could not reach upstream release API",
                cause: error.localizedDescription,
                fix: "check network access to api.github.com and retry",
                exitCode: .networkError
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw CLIError(
                what: "invalid upstream release API response",
                cause: "GitHub did not return an HTTP response",
                exitCode: .networkError
            )
        }

        switch http.statusCode {
        case 200:
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw CLIError(
                    what: "could not decode upstream release metadata",
                    cause: error.localizedDescription,
                    fix: "retry later; if this persists, the GitHub release schema may have changed",
                    exitCode: .networkError
                )
            }
        case 404:
            throw CLIError(
                what: "release not found",
                cause: "tag is not present in the upstream release list",
                fix: "check available tags at https://github.com/MetaCubeX/mihomo/releases",
                exitCode: .validationFailure
            )
        default:
            throw CLIError(
                what: "could not fetch upstream release metadata",
                cause: "GitHub returned HTTP \(http.statusCode)",
                fix: "retry later",
                exitCode: .networkError
            )
        }
    }
}
