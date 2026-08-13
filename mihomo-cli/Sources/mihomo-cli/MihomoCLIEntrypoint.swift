import ArgumentParser
import Darwin

@main
enum MihomoCLIEntrypoint {
    static func main() async {
        do {
            var command = try await MihomoCLI.asyncParseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let error as CLIError {
            error.writeToStandardError()
            exit(error.exitCode.rawValue)
        } catch {
            MihomoCLI.exit(withError: error)
        }
    }
}
