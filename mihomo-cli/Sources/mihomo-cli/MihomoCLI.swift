import ArgumentParser

/// Root command. Subcommand groups map 1:1 to the groups in the Full Specification
/// (mihomo_CLI_Manager_Full_Specification.md, Appendix A):
///   sub, net, kernel, mode, daemon, plus top-level lifecycle/diagnostics commands.
struct MihomoCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mihomo",
        abstract: "Pure CLI manager for the mihomo kernel on macOS (Apple Silicon).",
        version: "0.1.0-scaffold",
        subcommands: [
            // Command groups (§6.1–6.5 of the design doc)
            KernelCommand.self,
            SubCommand.self,
            NetCommand.self,
            ModeCommand.self,
            DaemonCommand.self,

            // Top-level lifecycle & diagnostics (§6.6)
            StartCommand.self,
            StopCommand.self,
            RestartCommand.self,
            LogCommand.self,
            AuditCommand.self,
            DoctorCommand.self,
            UninstallCommand.self,
        ]
    )
}
