import Foundation
import Network

/// This Mac's own IP addresses, and how to classify an address.
enum NetworkAddresses {
    struct Entry {
        let interface: String
        let ip: String
        let isIPv6: Bool
    }

    /// Every address on an interface that is up, loopback excluded.
    static func all() -> [Entry] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }

        var entries: [Entry] = []
        var cursor = head
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            guard let sa = ifa.ifa_addr,
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            entries.append(Entry(interface: String(cString: ifa.ifa_name), ip: String(cString: host),
                                 isIPv6: sa.pointee.sa_family == UInt8(AF_INET6)))
        }
        return entries
    }

    /// Private, loopback, link-local, or Tailscale (100.64.0.0/10).
    static func isPrivate(_ a: IPv4Address) -> Bool {
        let b = [UInt8](a.rawValue)
        return b[0] == 10 || b[0] == 127
            || (b[0] == 172 && (16...31).contains(b[1]))
            || (b[0] == 192 && b[1] == 168)
            || (b[0] == 169 && b[1] == 254)
            || isTailscale(a)
    }

    static func isTailscale(_ a: IPv4Address) -> Bool {
        let b = [UInt8](a.rawValue)
        return b[0] == 100 && (64...127).contains(b[1])
    }

    /// Global unicast (2000::/3).
    static func isGlobal(_ a: IPv6Address) -> Bool {
        (0x20...0x3F).contains(a.rawValue.first ?? 0)
    }

    /// Private and Tailscale IPv4 plus global IPv6 addresses of this Mac:
    /// what a paired client should try.
    static func reachable() -> (lan: [String], v6: [String]) {
        var lan = Set<String>(), v6 = Set<String>()
        for entry in all() {
            if entry.isIPv6 {
                if let a = IPv6Address(entry.ip), isGlobal(a) { v6.insert(entry.ip) }
            } else if let a = IPv4Address(entry.ip), isPrivate(a) {
                lan.insert(entry.ip)
            }
        }
        return (lan.sorted(), v6.sorted())
    }

    /// True when `endpoint` is on one of this Mac's own networks: private
    /// IPv4, Tailscale, link-local or unique-local IPv6, or a global IPv6 in
    /// one of our /64 prefixes (the home network's own IPv6 range).
    static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a):
            return isPrivate(a)
        case .ipv6(let a):
            if let mapped = a.asIPv4 { return isPrivate(mapped) }
            let bytes = [UInt8](a.rawValue)
            if a.isLoopback || a.isLinkLocal || bytes[0] & 0xFE == 0xFC { return true }
            let ownPrefixes = reachable().v6.compactMap(IPv6Address.init).map { [UInt8]($0.rawValue.prefix(8)) }
            return ownPrefixes.contains(Array(bytes.prefix(8)))
        default:
            return false
        }
    }
}
