// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mihomo-cli",
    platforms: [
        // Pinned to the actual target machine: Mac Mini M4, macOS 27 Beta.
        // This is local-only personal-use tooling, not a distributed product —
        // there is no compatibility matrix to support, so the floor is set to
        // match the one machine this runs on rather than a broad "Ventura+"
        // guess. String-literal form used since macOS 27 likely predates a
        // named enum case (.v13/.v14/etc.) in whatever SwiftPM/Xcode version
        // is available — if `swift build` complains about tools-version or
        // SDK support for "27.0" on the real machine, bump `swift-tools-version`
        // at the top of this file to whatever Xcode's actual Swift version is,
        // and adjust this string to match `sw_vers -productVersion` exactly.
        .macOS("27.0")
    ],
    dependencies: [
        // Command parsing / subcommand tree
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        // YAML parser for subscription configuration validation
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "mihomo-cli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/mihomo-cli"
        ),
        // Menu bar companion app (docs/mihomo_menubar_spec.md). Deliberately
        // has zero dependencies beyond system frameworks (AppKit,
        // ServiceManagement isn't used — see spec for why) and never links
        // against the `mihomo-cli` target: it drives the tool exclusively by
        // shelling out to the built `mihomo-cli` executable, the same way a
        // person would from a terminal, so every action it triggers reuses
        // already-tested business logic (locking, atomic switch, rollback)
        // instead of duplicating it. This keeps the GUI layer thin and
        // avoids the risk of the two surfaces drifting out of sync.
        .executableTarget(
            name: "mihomo-menubar",
            dependencies: [],
            path: "Sources/mihomo-menubar"
        ),
        .testTarget(
            name: "mihomo-cliTests",
            dependencies: [
                "mihomo-cli",
                // Needed so tests can parse written config.yaml output back
                // into a dictionary to assert on it directly (see
                // RuntimeConfigWriterTests) rather than string-matching —
                // previously only the executable target could `import Yams`.
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Tests/mihomo-cliTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
