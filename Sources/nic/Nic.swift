import ArgumentParser
import CLICore

@main
struct Nic: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nic",
        abstract: "Show network interfaces and addresses.",
        version: "1.0.0"
    )

    @Flag(name: [.short, .long], help: "Include inactive interfaces.")
    var all = false

    @Flag(name: .long, help: "Output as JSON.")
    var json = false

    @Flag(name: .long, help: "Skip public IP lookup.")
    var noPublicIp = false

    @Argument(help: "Show detail for a specific interface.")
    var interface: String?

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let wantsHelp = args.contains("-h") || args.contains("--help")
        let wantsVersion = args.contains("--version")

        if wantsHelp {
            Help.print()
            return
        }

        if wantsVersion {
            print(configuration.version)
            return
        }

        do {
            var command = try parseAsRoot()
            try command.run()
        } catch {
            exit(withError: error)
        }
    }

    func run() throws {
        let interfaces = NetworkData.collect()

        if let name = interface {
            guard let iface = interfaces.first(where: { $0.name == name }) else {
                Output.error("unknown interface '\(name)'")
                throw ExitCode.failure
            }
            if json {
                print(Formatter.renderDetailJSON(iface))
            } else {
                Formatter.printDetail(iface)
            }
        } else {
            let filtered = all ? interfaces : interfaces.filter(\.isActive)
            if json {
                print(Formatter.renderListJSON(filtered))
            } else {
                let publicIP = noPublicIp ? nil : PublicIP.fetch()
                Formatter.printTable(filtered, publicIP: publicIP)
            }
        }
    }

}
