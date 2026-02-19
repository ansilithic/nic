import CLICore
import Foundation

enum Formatter {

    // MARK: - Table View

    static func printTable(_ interfaces: [InterfaceInfo], publicIP: String?) {
        let table = TrafficLightTable(segments: [
            .indicators([
                Indicator("active", color: .green),
                Indicator("ipv4", color: .blue),
            ]),
            .column(TextColumn("Interface", sizing: .auto())),
            .column(TextColumn("Type", sizing: .auto())),
            .column(TextColumn("Address", sizing: .auto())),
            .column(TextColumn("MTU", sizing: .fixed(5))),
            .column(TextColumn("Traffic", sizing: .auto())),
            .column(TextColumn("MAC", sizing: .flexible(minWidth: 10))),
        ])

        var activeCount = 0
        var ipv4Count = 0
        var rows: [TrafficLightRow] = []

        for iface in interfaces {
            let hasIPv4 = !iface.ipv4Addresses.isEmpty

            if iface.isActive { activeCount += 1 }
            if hasIPv4 { ipv4Count += 1 }

            let ipv4Display = iface.ipv4Addresses.first?.address ?? styled("\u{2014}", .dim)
            let macDisplay = iface.mac ?? styled("\u{2014}", .dim)
            let trafficDisplay = (iface.bytesIn > 0 || iface.bytesOut > 0)
                ? styled("\u{2193}\(formatBytes(iface.bytesIn)) \u{2191}\(formatBytes(iface.bytesOut))", .dim)
                : styled("\u{2014}", .dim)

            rows.append(TrafficLightRow(
                indicators: [[
                    iface.isActive ? .on : .off,
                    hasIPv4 ? .on : .off,
                ]],
                values: [
                    styled(iface.name, .white),
                    styled(iface.type.rawValue, .dim),
                    ipv4Display,
                    iface.mtu > 0 ? styled(String(iface.mtu), .dim) : styled("\u{2014}", .dim),
                    trafficDisplay,
                    styled(macDisplay.strippingANSI, .dim),
                ]
            ))
        }

        // Public IP as a footer row
        let pubIP = publicIP ?? styled("(offline)", .yellow)
        if publicIP != nil { ipv4Count += 1 }
        rows.append(TrafficLightRow(
            indicators: [[.off, publicIP != nil ? .on : .off]],
            values: [
                styled("\u{2014}", .dim),
                styled("Public", .white),
                pubIP,
                styled("\u{2014}", .dim),
                styled("\u{2014}", .dim),
                styled("\u{2014}", .dim),
            ]
        ))

        let counts: [[Int]] = [[activeCount, ipv4Count]]
        print(table.render(rows: rows, counts: counts))

        // Traffic chart for interfaces with traffic
        let trafficItems = interfaces
            .filter { $0.bytesIn + $0.bytesOut > 0 }
            .sorted { ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut) }
            .map { iface in
                let total = iface.bytesIn + iface.bytesOut
                return BarChart.Item(
                    iface.name,
                    value: Double(total),
                    display: formatBytesLong(total)
                )
            }
        if !trafficItems.isEmpty {
            print(styled("  Traffic", .dim))
            print(BarChart(items: trafficItems, color: .blue).render())
            print()
        }
    }

    // MARK: - Detail View

    static func printDetail(_ iface: InterfaceInfo) {
        let keyWidth = 18

        func field(_ key: String, _ value: String) {
            let paddedKey = styled(
                key.padding(toLength: keyWidth, withPad: " ", startingAt: 0), .gray)
            print("  \(paddedKey)\(value)")
        }

        print()
        print(styled("  \(iface.name)", .bold, .white))
        print(styled("  " + String(repeating: "\u{2500}", count: iface.name.count), .dim))
        print()

        // Status & basics
        let statusIcon = iface.isActive ? styled("\u{25CF}", .green) : styled("\u{25CF}", .red)
        let statusLabel = iface.isActive ? "Active" : "Inactive"
        field("Status", "\(statusIcon) \(statusLabel)")
        field("Type", iface.type.rawValue)
        if iface.mtu > 0 {
            field("MTU", "\(iface.mtu)")
        }
        if let mac = iface.mac {
            field("MAC", mac)
        }
        if iface.linkSpeed > 0 {
            field("Link Speed", formatBitrate(iface.linkSpeed))
        }

        // Wi-Fi
        if iface.ssid != nil || iface.channel != nil {
            print()
            if let ssid = iface.ssid {
                field("SSID", ssid)
            }
            if let channel = iface.channel {
                field("Channel", channel)
            }
            if let rssi = iface.rssi {
                let quality = signalQuality(rssi)
                let color = signalColor(rssi)
                let fraction = signalFraction(rssi)
                let gauge = bar(fraction, width: 20, fill: color, empty: .darkGray)
                field("Signal", "\(gauge)  \(rssi) dBm  \(styled(quality, .dim))")
            }
            if let noise = iface.noise {
                field("Noise", "\(noise) dBm")
            }
            if let rate = iface.txRate, rate > 0 {
                field("Tx Rate", "\(Int(rate)) Mbps")
            }
        }

        // IPv4
        if !iface.ipv4Addresses.isEmpty {
            print()
            for (i, addr) in iface.ipv4Addresses.enumerated() {
                field(i == 0 ? "IPv4" : "", addr.displayAddress)
                if let bcast = addr.broadcast {
                    field("Broadcast", bcast)
                }
            }
        }

        // IPv6
        if !iface.ipv6Addresses.isEmpty {
            print()
            let sorted = iface.ipv6Addresses.sorted { $0.scope < $1.scope }
            for (i, addr) in sorted.enumerated() {
                let scopeStr = addr.scopeLabel
                let suffix = scopeStr.isEmpty ? "" : "  " + styled(scopeStr, .dim)
                field(i == 0 ? "IPv6" : "", addr.displayAddress + suffix)
            }
        }

        // Traffic
        if iface.bytesIn > 0 || iface.bytesOut > 0 {
            print()
            field("Traffic In", "\(formatBytesLong(iface.bytesIn))  \(styled("(\(formatNumber(iface.packetsIn)) packets)", .dim))")
            field("Traffic Out", "\(formatBytesLong(iface.bytesOut))  \(styled("(\(formatNumber(iface.packetsOut)) packets)", .dim))")
            if iface.errorsIn > 0 || iface.errorsOut > 0 {
                field("Errors", "\(formatNumber(iface.errorsIn)) in / \(formatNumber(iface.errorsOut)) out")
            }
            if iface.collisions > 0 {
                field("Collisions", formatNumber(iface.collisions))
            }
        }

        // Flags
        if !iface.flagDescriptions.isEmpty {
            print()
            field("Flags", iface.flagDescriptions.joined(separator: ", "))
        }

        print()
    }

    // MARK: - JSON

    static func renderListJSON(_ interfaces: [InterfaceInfo]) -> String {
        let items = interfaces.map { jsonDict(for: $0) }
        return toJSON(items)
    }

    static func renderDetailJSON(_ iface: InterfaceInfo) -> String {
        toJSON(jsonDict(for: iface))
    }

    private static func jsonDict(for iface: InterfaceInfo) -> [String: Any] {
        var dict: [String: Any] = [
            "name": iface.name,
            "type": iface.type.rawValue,
            "active": iface.isActive,
            "mtu": iface.mtu,
            "flags": iface.flagDescriptions,
        ]
        if let mac = iface.mac {
            dict["mac"] = mac
        }
        if iface.linkSpeed > 0 {
            dict["linkSpeed"] = iface.linkSpeed
        }
        if let ssid = iface.ssid {
            dict["ssid"] = ssid
        }
        if let rssi = iface.rssi {
            dict["rssi"] = rssi
        }
        if let noise = iface.noise {
            dict["noise"] = noise
        }
        if let rate = iface.txRate, rate > 0 {
            dict["txRate"] = rate
        }
        if let channel = iface.channel {
            dict["channel"] = channel
        }
        dict["traffic"] = [
            "bytesIn": iface.bytesIn,
            "bytesOut": iface.bytesOut,
            "packetsIn": iface.packetsIn,
            "packetsOut": iface.packetsOut,
            "errorsIn": iface.errorsIn,
            "errorsOut": iface.errorsOut,
            "collisions": iface.collisions,
        ]
        if !iface.ipv4Addresses.isEmpty {
            dict["ipv4"] = iface.ipv4Addresses.map { addr -> [String: Any] in
                var d: [String: Any] = ["address": addr.address, "cidr": addr.cidr]
                if let b = addr.broadcast { d["broadcast"] = b }
                return d
            }
        }
        if !iface.ipv6Addresses.isEmpty {
            dict["ipv6"] = iface.ipv6Addresses.map { addr -> [String: Any] in
                [
                    "address": addr.address,
                    "prefixLength": addr.prefixLength,
                    "scope": addr.scopeLabel.isEmpty ? "global" : addr.scopeLabel,
                ]
            }
        }
        return dict
    }

    private static func toJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Formatting Helpers

    private static func formatBytes(_ bytes: UInt64) -> String {
        if bytes == 0 { return "0B" }
        if bytes < 1024 { return "\(bytes)B" }
        let units = ["K", "M", "G", "T"]
        var value = Double(bytes) / 1024
        var i = 0
        while value >= 1024 && i < units.count - 1 {
            value /= 1024
            i += 1
        }
        if value >= 100 { return "\(Int(value))\(units[i])" }
        return String(format: "%.1f%@", value, units[i])
    }

    private static func formatBytesLong(_ bytes: UInt64) -> String {
        if bytes == 0 { return "0 B" }
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1024
        var i = 0
        while value >= 1024 && i < units.count - 1 {
            value /= 1024
            i += 1
        }
        return String(format: "%.1f %@", value, units[i])
    }

    private static func formatBitrate(_ bps: UInt64) -> String {
        if bps >= 1_000_000_000 {
            let gbps = Double(bps) / 1_000_000_000
            return gbps == gbps.rounded() ? "\(Int(gbps)) Gbps" : String(format: "%.1f Gbps", gbps)
        }
        if bps >= 1_000_000 {
            let mbps = Double(bps) / 1_000_000
            return mbps == mbps.rounded() ? "\(Int(mbps)) Mbps" : String(format: "%.1f Mbps", mbps)
        }
        return "\(bps / 1000) Kbps"
    }

    private static func formatNumber(_ n: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static func signalQuality(_ rssi: Int) -> String {
        if rssi >= -50 { return "Excellent" }
        if rssi >= -60 { return "Good" }
        if rssi >= -70 { return "Fair" }
        if rssi >= -80 { return "Weak" }
        return "Poor"
    }

    private static func signalColor(_ rssi: Int) -> Color {
        if rssi >= -50 { return .green }
        if rssi >= -60 { return .yellow }
        if rssi >= -70 { return .orange }
        return .red
    }

    private static func signalFraction(_ rssi: Int) -> Double {
        // Map -100 dBm (worst) to 0.0, -20 dBm (best) to 1.0
        min(max(Double(rssi + 100) / 80.0, 0), 1)
    }
}
