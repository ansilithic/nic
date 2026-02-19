import CoreWLAN

enum InterfaceType: String, Sendable, Encodable {
    case wifi = "Wi-Fi"
    case ethernet = "Ethernet"
    case loopback = "Loopback"
    case tailscale = "Tailscale"
    case tunnel = "Tunnel"
    case thunderboltBridge = "Thunderbolt Bridge"
    case vmBridge = "VM Bridge"
    case vmEthernet = "VM Ethernet"
    case airdrop = "AirDrop"
    case lowLatencyWLAN = "Low Latency WLAN"
    case anpi = "ANPI"
    case hotspot = "Hotspot"
    case thunderbolt = "Thunderbolt"
    case unknown = "Unknown"

    static func classify(_ name: String, ipv4: String?, bridgeMembers: Set<String>) -> InterfaceType {
        if name.hasPrefix("lo") {
            return .loopback
        }
        if name.hasPrefix("awdl") {
            return .airdrop
        }
        if name.hasPrefix("llw") {
            return .lowLatencyWLAN
        }
        if name.hasPrefix("anpi") {
            return .anpi
        }
        if name.hasPrefix("ap") {
            return .hotspot
        }
        if name.hasPrefix("vmenet") {
            return .vmEthernet
        }
        if name.hasPrefix("gif") || name.hasPrefix("stf") {
            return .tunnel
        }
        if name.hasPrefix("utun") {
            if let ip = ipv4, ip.hasPrefix("100.") {
                return .tailscale
            }
            return .tunnel
        }
        if name.hasPrefix("bridge") {
            if name == "bridge0" {
                return .thunderboltBridge
            }
            return .vmBridge
        }
        if name.hasPrefix("en") {
            if isWiFiInterface(name) {
                return .wifi
            }
            if bridgeMembers.contains(name) {
                return .thunderbolt
            }
            return .ethernet
        }
        return .unknown
    }

    private static func isWiFiInterface(_ name: String) -> Bool {
        let client = CWWiFiClient.shared()
        if let iface = client.interface(withName: name) {
            return iface.interfaceName != nil
        }
        return false
    }
}

struct WiFiInfo: Sendable {
    let ssid: String?
    let rssi: Int
    let noise: Int
    let transmitRate: Double
    let channel: String?

    static func query(_ name: String) -> WiFiInfo? {
        let client = CWWiFiClient.shared()
        guard let iface = client.interface(withName: name) else { return nil }
        guard iface.interfaceName != nil else { return nil }

        var channelStr: String?
        if let ch = iface.wlanChannel() {
            let band: String
            switch ch.channelBand {
            case .band2GHz: band = "2.4 GHz"
            case .band5GHz: band = "5 GHz"
            case .band6GHz: band = "6 GHz"
            case .bandUnknown: band = "Unknown"
            @unknown default: band = "Unknown"
            }
            let width: String
            switch ch.channelWidth {
            case .width20MHz: width = "20 MHz"
            case .width40MHz: width = "40 MHz"
            case .width80MHz: width = "80 MHz"
            case .width160MHz: width = "160 MHz"
            case .widthUnknown: width = ""
            @unknown default: width = ""
            }
            channelStr = "\(ch.channelNumber) (\(band)\(width.isEmpty ? "" : ", \(width)"))"
        }

        return WiFiInfo(
            ssid: iface.ssid(),
            rssi: iface.rssiValue(),
            noise: iface.noiseMeasurement(),
            transmitRate: iface.transmitRate(),
            channel: channelStr
        )
    }
}
