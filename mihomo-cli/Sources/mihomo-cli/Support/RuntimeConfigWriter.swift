import Foundation

struct RuntimeConfig {
    let configURL: URL
    let workDirectory: URL
}

protocol RuntimeConfigWriting {
    func write(version: String, credentials: ControlAPICredentials, mixedPort: Int) throws -> RuntimeConfig
}

final class RuntimeConfigWriter: RuntimeConfigWriting {
    private let runtimeDirectory: URL
    private let fileManager: FileManager

    init(
        runtimeDirectory: URL = URL(fileURLWithPath: "\(NSHomeDirectory())/.mihomo-cli/runtime"),
        fileManager: FileManager = .default
    ) {
        self.runtimeDirectory = runtimeDirectory
        self.fileManager = fileManager
    }

    func write(version: String, credentials: ControlAPICredentials, mixedPort: Int) throws -> RuntimeConfig {
        let safeVersion = version.replacingOccurrences(of: "/", with: "_")
        let workDirectory = runtimeDirectory.appendingPathComponent(safeVersion, isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let configURL = workDirectory.appendingPathComponent("config.yaml")
        let content = """
        mixed-port: \(mixedPort)
        external-controller: 127.0.0.1:\(credentials.port)
        secret: \(credentials.secret)
        mode: rule
        log-level: info
        allow-lan: false
        proxies: []
        proxy-groups: []
        rules:
          - MATCH,DIRECT

        """

        let tempURL = configURL.appendingPathExtension("tmp-\(UUID().uuidString.prefix(8))")
        try content.data(using: .utf8)?.write(to: tempURL, options: .atomic)
        if fileManager.fileExists(atPath: configURL.path) {
            _ = try fileManager.replaceItemAt(configURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: configURL)
        }
        return RuntimeConfig(configURL: configURL, workDirectory: workDirectory)
    }
}
