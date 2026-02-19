import Foundation

enum PublicIP {
    static func fetch() -> String? {
        for service in ["ipinfo.io/ip", "ifconfig.me", "api.ipify.org"] {
            let result = shell("curl -s --connect-timeout 2 --max-time 3 \(service) 2>/dev/null")
            if !result.isEmpty {
                return result
            }
        }
        return nil
    }

    private static func shell(_ command: String) -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", command]
        task.standardOutput = pipe
        task.standardError = Pipe()
        task.standardInput = nil

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
