import Foundation

protocol Downloading {
    func download(from url: URL, to destinationURL: URL) async throws
}

final class ResumableDownloader: Downloading {
    private let session: URLSession
    private let fileManager: FileManager
    private let maxRetries: Int

    init(session: URLSession = .shared, fileManager: FileManager = .default, maxRetries: Int = 3) {
        self.session = session
        self.fileManager = fileManager
        self.maxRetries = maxRetries
    }

    func download(from url: URL, to destinationURL: URL) async throws {
        let directory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let partialURL = destinationURL.appendingPathExtension("partial")
        var lastError: Error?

        for _ in 0..<maxRetries {
            do {
                try await downloadOnce(from: url, partialURL: partialURL)
                try replaceItem(at: destinationURL, with: partialURL)
                return
            } catch {
                lastError = error
            }
        }

        if let cliError = lastError as? CLIError {
            throw cliError
        }
        throw CLIError(
            what: "download failed",
            cause: lastError?.localizedDescription ?? "unknown network error",
            fix: "retry when the network is stable",
            exitCode: .networkError
        )
    }

    private func downloadOnce(from url: URL, partialURL: URL) async throws {
        let existingBytes = fileSize(at: partialURL)
        var request = URLRequest(url: url, timeoutInterval: 60)
        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CLIError(
                what: "download failed",
                cause: error.localizedDescription,
                fix: "retry when the network is stable",
                exitCode: .networkError
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw CLIError(
                what: "source verification failed",
                cause: "download did not return an HTTP response",
                fix: "retry; if this persists, check whether HTTPS traffic to github.com is being intercepted",
                exitCode: .sourceVerificationFailure
            )
        }

        switch http.statusCode {
        case 200:
            try data.write(to: partialURL, options: .atomic)
        case 206 where existingBytes > 0:
            let handle = try FileHandle(forWritingTo: partialURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        default:
            throw CLIError(
                what: "source verification failed",
                cause: "download returned HTTP \(http.statusCode)",
                fix: "retry; if this persists, check whether HTTPS traffic to github.com is being intercepted",
                exitCode: .sourceVerificationFailure
            )
        }
    }

    private func fileSize(at url: URL) -> UInt64 {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
    }

    private func replaceItem(at destinationURL: URL, with tempURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        }
    }
}
