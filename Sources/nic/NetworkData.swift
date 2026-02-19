import Darwin
import Foundation

// ioctl constants — macros not importable in Swift (struct sizing in preprocessor)
// _IOWR('i', N, T) = 0xC0000000 | (sizeof(T) << 16) | ('i' << 8) | N
private let _SIOCGIFMEDIA: UInt = 0xC02C_6938   // sizeof(ifmediareq) = 44
private let _SIOCGIFFLAGS: UInt = 0xC020_6911   // sizeof(ifreq) = 32
private let _IFM_ACTIVE: Int32 = 0x0002

struct IPv4Address: Sendable {
    let address: String
    let cidr: Int
    let broadcast: String?

    var displayAddress: String {
        "\(address)/\(cidr)"
    }
}

struct IPv6Address: Sendable {
    let address: String
    let prefixLength: Int

    var scope: IPv6Scope {
        if address.hasPrefix("fe80:") { return .linkLocal }
        if address.hasPrefix("fd") || address.hasPrefix("fc") { return .ula }
        return .global
    }

    var displayAddress: String {
        "\(address)/\(prefixLength)"
    }

    var scopeLabel: String {
        switch scope {
        case .linkLocal: return "link-local"
        case .ula: return "ULA"
        case .global: return ""
        }
    }
}

enum IPv6Scope: Int, Sendable, Comparable {
    case global = 0
    case ula = 1
    case linkLocal = 2

    static func < (lhs: IPv6Scope, rhs: IPv6Scope) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct InterfaceInfo: Sendable {
    let name: String
    let type: InterfaceType
    let isActive: Bool
    let mtu: Int
    let mac: String?
    let ipv4Addresses: [IPv4Address]
    let ipv6Addresses: [IPv6Address]
    let flags: UInt32
    let bytesIn: UInt64
    let bytesOut: UInt64
    let packetsIn: UInt64
    let packetsOut: UInt64
    let errorsIn: UInt64
    let errorsOut: UInt64
    let collisions: UInt64
    let linkSpeed: UInt64
    let ssid: String?
    let rssi: Int?
    let noise: Int?
    let txRate: Double?
    let channel: String?

    var bestIPv6: IPv6Address? {
        ipv6Addresses
            .sorted { $0.scope < $1.scope }
            .first
    }

    var flagDescriptions: [String] {
        var result: [String] = []
        if flags & UInt32(IFF_UP) != 0 { result.append("UP") }
        if flags & UInt32(IFF_BROADCAST) != 0 { result.append("BROADCAST") }
        if flags & UInt32(IFF_LOOPBACK) != 0 { result.append("LOOPBACK") }
        if flags & UInt32(IFF_POINTOPOINT) != 0 { result.append("POINTOPOINT") }
        if flags & UInt32(IFF_RUNNING) != 0 { result.append("RUNNING") }
        if flags & UInt32(IFF_MULTICAST) != 0 { result.append("MULTICAST") }
        return result
    }
}

enum NetworkData {
    static func collect() -> [InterfaceInfo] {
        var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrsPtr) == 0, let first = ifaddrsPtr else { return [] }
        defer { freeifaddrs(ifaddrsPtr) }

        struct RawData {
            var ipv4: [IPv4Address] = []
            var ipv6: [IPv6Address] = []
            var mac: String?
            var mtu: Int = 0
            var flags: UInt32 = 0
            var bytesIn: UInt64 = 0
            var bytesOut: UInt64 = 0
            var packetsIn: UInt64 = 0
            var packetsOut: UInt64 = 0
            var errorsIn: UInt64 = 0
            var errorsOut: UInt64 = 0
            var collisions: UInt64 = 0
            var linkSpeed: UInt64 = 0
        }

        var dataByName: [String: RawData] = [:]
        var bridgeMembers = Set<String>()

        detectBridgeMembers(&bridgeMembers)

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr {
            let name = String(cString: ifa.pointee.ifa_name)
            guard let addr = ifa.pointee.ifa_addr else {
                ptr = ifa.pointee.ifa_next
                continue
            }
            let family = Int32(addr.pointee.sa_family)

            if dataByName[name] == nil {
                dataByName[name] = RawData()
            }
            dataByName[name]!.flags = ifa.pointee.ifa_flags

            switch family {
            case AF_INET:
                let ip = socketAddressToString(addr, family: AF_INET)
                let cidr = netmaskToCIDR4(ifa.pointee.ifa_netmask)
                let bcast = ifa.pointee.ifa_dstaddr.map { socketAddressToString($0, family: AF_INET) }
                dataByName[name]!.ipv4.append(IPv4Address(address: ip, cidr: cidr, broadcast: bcast))

            case AF_INET6:
                let ip = socketAddressToString(addr, family: AF_INET6)
                let prefixLen = netmaskToPrefixLength6(ifa.pointee.ifa_netmask)
                dataByName[name]!.ipv6.append(IPv6Address(address: ip, prefixLength: prefixLen))

            case AF_LINK:
                addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { sdl in
                    if let ifaData = ifa.pointee.ifa_data {
                        let ifData = ifaData.assumingMemoryBound(to: if_data.self).pointee
                        dataByName[name]!.mtu = Int(ifData.ifi_mtu)
                        dataByName[name]!.bytesIn = UInt64(ifData.ifi_ibytes)
                        dataByName[name]!.bytesOut = UInt64(ifData.ifi_obytes)
                        dataByName[name]!.packetsIn = UInt64(ifData.ifi_ipackets)
                        dataByName[name]!.packetsOut = UInt64(ifData.ifi_opackets)
                        dataByName[name]!.errorsIn = UInt64(ifData.ifi_ierrors)
                        dataByName[name]!.errorsOut = UInt64(ifData.ifi_oerrors)
                        dataByName[name]!.collisions = UInt64(ifData.ifi_collisions)
                        dataByName[name]!.linkSpeed = UInt64(ifData.ifi_baudrate)
                    }
                    if sdl.pointee.sdl_alen > 0 {
                        dataByName[name]!.mac = extractMAC(sdl)
                    }
                }

            default:
                break
            }

            ptr = ifa.pointee.ifa_next
        }

        // Determine active status for each interface
        var activeStatus: [String: Bool] = [:]
        for (name, raw) in dataByName {
            activeStatus[name] = isInterfaceActive(name, ipv4: raw.ipv4, ipv6: raw.ipv6)
        }

        // Sort: active first, then alphabetically
        let sortedNames = dataByName.keys.sorted { a, b in
            let aActive = activeStatus[a] ?? false
            let bActive = activeStatus[b] ?? false
            if aActive != bActive { return aActive }
            return a.localizedStandardCompare(b) == .orderedAscending
        }

        return sortedNames.map { name in
            let raw = dataByName[name]!
            let type = InterfaceType.classify(name, ipv4: raw.ipv4.first?.address, bridgeMembers: bridgeMembers)
            let wifi = type == .wifi ? WiFiInfo.query(name) : nil
            return InterfaceInfo(
                name: name,
                type: type,
                isActive: activeStatus[name] ?? false,
                mtu: raw.mtu,
                mac: raw.mac,
                ipv4Addresses: raw.ipv4,
                ipv6Addresses: raw.ipv6,
                flags: raw.flags,
                bytesIn: raw.bytesIn,
                bytesOut: raw.bytesOut,
                packetsIn: raw.packetsIn,
                packetsOut: raw.packetsOut,
                errorsIn: raw.errorsIn,
                errorsOut: raw.errorsOut,
                collisions: raw.collisions,
                linkSpeed: raw.linkSpeed,
                ssid: wifi?.ssid,
                rssi: wifi?.rssi,
                noise: wifi?.noise,
                txRate: wifi?.transmitRate,
                channel: wifi?.channel
            )
        }
    }

    // MARK: - Address Conversion

    private static func socketAddressToString(_ addr: UnsafeMutablePointer<sockaddr>, family: Int32) -> String {
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = family == AF_INET
            ? socklen_t(MemoryLayout<sockaddr_in>.size)
            : socklen_t(MemoryLayout<sockaddr_in6>.size)
        getnameinfo(addr, len, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
        let result = hostname.withUnsafeBufferPointer { buf in
            String(cString: buf.baseAddress!)
        }
        // Strip zone ID (e.g. %en0)
        if let pct = result.firstIndex(of: "%") {
            return String(result[result.startIndex..<pct])
        }
        return result
    }

    // MARK: - Netmask Helpers

    private static func netmaskToCIDR4(_ mask: UnsafeMutablePointer<sockaddr>?) -> Int {
        guard let mask else { return 32 }
        return mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            let addr = UInt32(bigEndian: sin.pointee.sin_addr.s_addr)
            var bits = 0
            var m = addr
            while m & 0x8000_0000 != 0 {
                bits += 1
                m <<= 1
            }
            return bits
        }
    }

    private static func netmaskToPrefixLength6(_ mask: UnsafeMutablePointer<sockaddr>?) -> Int {
        guard let mask else { return 128 }
        return mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
            let bytes = withUnsafeBytes(of: sin6.pointee.sin6_addr) { Array($0) }
            var bits = 0
            for byte in bytes {
                if byte == 0xFF {
                    bits += 8
                } else {
                    var b = byte
                    while b & 0x80 != 0 {
                        bits += 1
                        b <<= 1
                    }
                    break
                }
            }
            return bits
        }
    }

    // MARK: - MAC Address

    private static func extractMAC(_ sdl: UnsafeMutablePointer<sockaddr_dl>) -> String {
        let nlen = Int(sdl.pointee.sdl_nlen)
        let alen = Int(sdl.pointee.sdl_alen)
        return withUnsafePointer(to: &sdl.pointee.sdl_data) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: nlen + alen) { data in
                (0..<alen).map { i in
                    String(format: "%02x", data[nlen + i])
                }.joined(separator: ":")
            }
        }
    }

    // MARK: - Media Status

    private static func isInterfaceActive(
        _ name: String, ipv4: [IPv4Address], ipv6: [IPv6Address]
    ) -> Bool {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        // Try SIOCGIFMEDIA first (works for physical interfaces)
        var ifmr = ifmediareq()
        setName(name, on: &ifmr.ifm_name)

        let mediaResult = withUnsafeMutablePointer(to: &ifmr) {
            ioctl(sock, _SIOCGIFMEDIA, $0)
        }

        if mediaResult == 0 {
            return ifmr.ifm_status & _IFM_ACTIVE != 0
        }

        // For virtual interfaces: active if UP|RUNNING AND has a routable address
        var ifr = ifreq()
        setName(name, on: &ifr.ifr_name)

        let flagsResult = withUnsafeMutablePointer(to: &ifr) {
            ioctl(sock, _SIOCGIFFLAGS, $0)
        }

        guard flagsResult == 0 else { return false }
        let flags = ifr.ifr_ifru.ifru_flags
        guard flags & Int16(IFF_UP) != 0, flags & Int16(IFF_RUNNING) != 0 else {
            return false
        }

        // Loopback is always active when up
        if flags & Int16(IFF_LOOPBACK) != 0 { return true }

        // Require at least one non-link-local address
        if !ipv4.isEmpty { return true }
        let hasRoutableIPv6 = ipv6.contains { $0.scope != .linkLocal }
        return hasRoutableIPv6
    }

    private static func setName<T>(_ name: String, on field: inout T) {
        withUnsafeMutableBytes(of: &field) { buf in
            let nameBytes = Array(name.utf8)
            let count = min(nameBytes.count, buf.count - 1)
            for i in 0..<count {
                buf[i] = nameBytes[i]
            }
        }
    }

    // MARK: - Bridge Members

    private static func detectBridgeMembers(_ members: inout Set<String>) {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        task.arguments = ["bridge0"]
        task.standardOutput = pipe
        task.standardError = Pipe()
        task.standardInput = nil

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return }
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("member:") {
                let parts = trimmed.split(separator: " ")
                if parts.count >= 2 {
                    members.insert(String(parts[1]))
                }
            }
        }
    }
}
