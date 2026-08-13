import Foundation

enum KernelFetchMode {
    case latestStable
    case latest(limit: Int)
    case tag(String)
}

struct KernelFetchOutcome: Equatable {
    enum Status: Equatable {
        case downloaded
        case alreadyPresent
    }

    let version: String
    let status: Status
}

struct KernelFetchSummary: Equatable {
    let outcomes: [KernelFetchOutcome]
    let latestStable: String?
}

final class KernelFetchService {
    private let releases: KernelReleaseProviding
    private let installer: KernelInstalling
    private let installedKernel: (String) async throws -> KernelRecord?
    private let registerKernel: (KernelRecord) async throws -> Void

    init(
        releases: KernelReleaseProviding = GitHubKernelReleaseClient(),
        installer: KernelInstalling = KernelInstaller(),
        installedKernel: @escaping (String) async throws -> KernelRecord? = { version in
            try MetadataStore.shared.kernel(version: version)
        },
        registerKernel: @escaping (KernelRecord) async throws -> Void = { record in
            _ = try MetadataStore.shared.upsertKernel(record)
        }
    ) {
        self.releases = releases
        self.installer = installer
        self.installedKernel = installedKernel
        self.registerKernel = registerKernel
    }

    func fetch(_ mode: KernelFetchMode) async throws -> KernelFetchSummary {
        switch mode {
        case .latestStable:
            let releases = try await releases.latestReleases(limit: 10)
            guard let latestStable = releases.first(where: \.isStable) else {
                throw CLIError(
                    what: "no stable release found",
                    cause: "upstream release list contains no non-prerelease mihomo release",
                    fix: "retry later, or run 'mihomo kernel fetch --all' to inspect recent releases",
                    exitCode: .networkError
                )
            }
            let outcome = try await fetchRelease(latestStable)
            return KernelFetchSummary(outcomes: [outcome], latestStable: latestStable.tagName)

        case .latest(let limit):
            let releases = try await releases.latestReleases(limit: limit)
            let latestStable = releases.first(where: \.isStable)?.tagName
            let outcomes = try await releases.asyncMap { release in
                try await fetchRelease(release)
            }
            return KernelFetchSummary(outcomes: outcomes, latestStable: latestStable)

        case .tag(let tag):
            let release = try await releases.release(tag: tag)
            let outcome = try await fetchRelease(release)
            return KernelFetchSummary(outcomes: [outcome], latestStable: release.isStable ? release.tagName : nil)
        }
    }

    private func fetchRelease(_ release: GitHubRelease) async throws -> KernelFetchOutcome {
        if try await installedKernel(release.tagName) != nil {
            return KernelFetchOutcome(version: release.tagName, status: .alreadyPresent)
        }

        guard let asset = release.darwinARM64Asset() else {
            throw CLIError(
                what: "source verification failed for \(release.tagName)",
                cause: "release does not contain a darwin-arm64 kernel asset",
                fix: "retry later; if this persists, check the upstream release assets",
                exitCode: .sourceVerificationFailure
            )
        }

        let record = try await installer.install(release: release, asset: asset)
        try await registerKernel(record)
        return KernelFetchOutcome(version: release.tagName, status: .downloaded)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self {
            let value = try await transform(element)
            values.append(value)
        }
        return values
    }
}
