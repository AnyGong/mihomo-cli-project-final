import ArgumentParser
import Foundation

/// `mihomo sub ...` — see mihomo_sub_command_spec.md for full behavior.
struct SubCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sub",
        abstract: "Manage subscription configurations.",
        subcommands: [List.self, Add.self, Use.self, Edit.self, Remove.self, Refresh.self, Validate.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List subscriptions.")

        @Flag(help: "Emit machine-readable JSON instead of a table.")
        var json = false

        @Option(help: "Sort key: active | last-used | updated | added.")
        var sort: String?

        func run() async throws {
            let subs = try await MetadataStore.shared.listSubscriptions()
            _ = sort // TODO: wire --sort override; default order from SubscriptionRecord.defaultSort is always used for now

            if json {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(subs)
                print(String(data: data, encoding: .utf8) ?? "[]")
                return
            }

            guard !subs.isEmpty else {
                print("No subscriptions configured. Run 'mihomo sub add' to import one.")
                return
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            print("  STATUS  NAME                 LOCAL  REMOTE  REFRESH        LAST USED")
            for s in subs {
                let status = s.isActive ? "✅" : (s.isFlaggedInvalid ? "⚠ " : "  ")
                let local = s.isLocal ? "✅" : "  "
                let remote = s.isLocal ? "  " : "✅"
                let refresh: String
                switch s.source {
                case .local: refresh = "Watch-on-use"
                case .remote(_, let interval): refresh = "\(interval) min"
                }
                let lastUsed = s.lastUsedAt.map(formatter.string) ?? ""
                print("  \(status)      \(s.name.padding(toLength: 19, withPad: " ", startingAt: 0))  \(local)     \(remote)      \(refresh.padding(toLength: 13, withPad: " ", startingAt: 0))  \(lastUsed)")
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Import a new subscription.",
            subcommands: [Local.self, Remote.self]
        )

        struct Local: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "local", abstract: "Import a local subscription file.")

            @Argument(help: "Path to the local subscription file.")
            var path: String

            @Option(help: "Subscription name (defaults to filename).")
            var name: String?

            @Flag(help: "Auto-confirm overwrite on name collision.")
            var yes = false

            func run() async throws {
                // TODO: validate format/rules/params before persisting (§1.2.2);
                // name-collision handling with numeric suffix per §1.2.3.
                throw stub("sub add local")
            }
        }

        struct Remote: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "remote", abstract: "Import a remote subscription URL.")

            @Argument(help: "Remote subscription URL.")
            var url: String

            @Option(help: "Refresh interval in minutes (1-1440, default 60).")
            var interval: Int = 60

            @Option(help: "Subscription name (defaults to filename portion of the URL).")
            var name: String?

            @Flag(help: "Auto-confirm overwrite on name collision.")
            var yes = false

            func validate() throws {
                guard (1...1440).contains(interval) else {
                    throw ValidationError("--interval must be between 1 and 1440 minutes.")
                }
            }

            func run() async throws {
                throw stub("sub add remote")
            }
        }
    }

    struct Use: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "use", abstract: "Activate a subscription.")

        @Argument(help: "Subscription name.")
        var name: String

        @Flag(help: "Suppress the unsaved-manual-edit confirmation (never bypasses validation).")
        var force = false

        func run() async throws {
            // TODO: atomic switch workflow with rollback (§4.1.1), staged-failure
            // reporting, and the mode-precedence note (§2.4) printed on success
            // if the subscription's embedded mode differs from what's in effect.
            throw stub("sub use")
        }
    }

    struct Edit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "edit", abstract: "Edit a subscription file.")

        @Argument(help: "Subscription name.")
        var name: String

        @Option(help: "Editor command to use (defaults to $EDITOR).")
        var editor: String?

        func run() async throws {
            // TODO: blocked entirely if `name` is active; re-validate after
            // editor exits and flag ⚠ invalid in `sub list` rather than reverting.
            throw stub("sub edit")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete a subscription.")

        @Argument(help: "Subscription name.")
        var name: String

        @Flag(help: "Skip the confirmation prompt.")
        var yes = false

        func run() async throws {
            throw stub("sub rm") // TODO: blocked if active
        }
    }

    struct Refresh: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "refresh", abstract: "Force-refresh a remote subscription.")

        @Argument(help: "Subscription name.")
        var name: String

        func run() async throws {
            // TODO: remote-only — error if called on a local subscription.
            // Fault-tolerant download (§4.1.4); failure leaves cached copy untouched.
            throw stub("sub refresh")
        }
    }

    struct Validate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "validate", abstract: "Validate a subscription without activating it.")

        @Argument(help: "Subscription name.")
        var name: String

        func run() async throws {
            throw stub("sub validate")
        }
    }
}

private func stub(_ command: String) -> CLIError {
    CLIError(what: "not implemented", cause: "'\(command)' is a scaffold stub", exitCode: .permissionDenied)
}
