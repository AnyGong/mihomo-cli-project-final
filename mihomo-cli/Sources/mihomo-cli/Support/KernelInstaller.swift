import Foundation

protocol KernelInstalling {
    func install(release: GitHubRelease, asset: GitHubRelease.Asset) async throws -> KernelRecord
}

final class KernelInstaller: KernelInstalling {
    private let kernelsDirectory: URL
    private let downloader: Downloading
    private let fileManager: FileManager
    private let now: () -> Date

    init(
        kernelsDirectory: URL = URL(fileURLWithPath: "\(NSHomeDirectory())/.mihomo-cli/kernels"),
        downloader: Downloading = ResumableDownloader(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.kernelsDirectory = kernelsDirectory
        self.downloader = downloader
        self.fileManager = fileManager
        self.now = now
    }

    func install(release: GitHubRelease, asset: GitHubRelease.Asset) async throws -> KernelRecord {
        try verifyOfficialAssetURL(asset.browserDownloadURL, tag: release.tagName)

        let versionDirectory = kernelsDirectory.appendingPathComponent(safePathComponent(release.tagName), isDirectory: true)
        try fileManager.createDirectory(at: versionDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let archiveURL = versionDirectory.appendingPathComponent(asset.name)
        let binaryURL = versionDirectory.appendingPathComponent("mihomo")

        try await downloader.download(from: asset.browserDownloadURL, to: archiveURL)
        try extractGzip(archiveURL: archiveURL, binaryURL: binaryURL)
        try ensureNonEmptyExecutable(at: binaryURL, version: release.tagName)

        return KernelRecord(
            version: release.tagName,
            binaryPath: binaryURL.path,
            addedAt: now(),
            lastUsedAt: nil,
            isActive: false
        )
    }

    private func verifyOfficialAssetURL(_ url: URL, tag: String) throws {
        guard url.scheme == "https",
              url.host?.lowercased() == "github.com",
              url.path.contains("/MetaCubeX/mihomo/releases/download/\(tag)/") else {
            throw CLIError(
                what: "source verification failed for \(tag)",
                cause: "response did not resolve to an official release asset",
                fix: "retry; if this persists, check whether your network is intercepting HTTPS traffic to github.com",
                exitCode: .sourceVerificationFailure
            )
        }
    }

    private func extractGzip(archiveURL: URL, binaryURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", archiveURL.path]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw CLIError(
                what: "could not extract kernel archive",
                cause: error.localizedDescription,
                fix: "confirm /usr/bin/gunzip is available",
                exitCode: .validationFailure
            )
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(
                what: "could not extract kernel archive",
                cause: stderr?.isEmpty == false ? stderr! : "gunzip exited with status \(process.terminationStatus)",
                fix: "delete the partial download and retry",
                exitCode: .sourceVerificationFailure
            )
        }

        let tempURL = binaryURL.appendingPathExtension("tmp-\(UUID().uuidString.prefix(8))")
        try data.write(to: tempURL, options: .atomic)
        if fileManager.fileExists(atPath: binaryURL.path) {
            _ = try fileManager.replaceItemAt(binaryURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: binaryURL)
        }
    }

    private func ensureNonEmptyExecutable(at binaryURL: URL, version: String) throws {
        guard let attrs = try? fileManager.attributesOfItem(atPath: binaryURL.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > 0 else {
            throw CLIError(
                what: "source verification failed for \(version)",
                cause: "downloaded kernel binary is missing or zero-length after extraction",
                fix: "delete the partial download and retry",
                exitCode: .sourceVerificationFailure
            )
        }

        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
    }

    private func safePathComponent(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: "_")
    }
}
