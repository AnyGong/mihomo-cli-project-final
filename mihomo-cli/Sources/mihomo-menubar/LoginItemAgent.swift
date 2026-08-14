import Foundation

/// Manages "Launch at Login" for the menu bar app itself via a dedicated
/// `launchd` agent — deliberately mirroring the pattern already established
/// and tested in `mihomo-cli`'s `Support/LaunchdAgent.swift` (RunAtLoad
/// plist + `launchctl bootstrap`/`bootout`) rather than introducing a new
/// mechanism. Kept as its own small type instead of importing the
/// `mihomo-cli` target's `DefaultLaunchdManager` directly, since this app
/// never links against that target (see Package.swift) and the two agents
/// serve different purposes: `com.mihomo-cli.agent.plist` supervises the
/// *kernel* process (KeepAlive, crash restart); this one just launches the
/// menu bar app once at login (RunAtLoad only, no KeepAlive — the whole
/// point of a menu bar app is that the user can quit it).
final class LoginItemAgent {
    static let label = "com.mihomo-cli.menubar"

    private let plistURL: URL
    private let executablePath: () -> String

    init(
        fileManager: FileManager = .default,
        executablePath: @escaping () -> String = {
            URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        }
    ) {
        self.plistURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
        self.executablePath = executablePath
    }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try install()
        } else {
            try uninstall()
        }
    }

    private func install() throws {
        let dir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(Self.label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath())</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    private func uninstall() throws {
        guard isEnabled else { return }
        runLaunchctl(["bootout", "gui/\(getuid())", plistURL.path])
        try FileManager.default.removeItem(at: plistURL)
    }

    private func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }
}
