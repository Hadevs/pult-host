import Foundation
import Network
import Observation
import Security

/// The identity a client pairs with: a stable host id, the 256-bit key for
/// the encrypted port (kept in the Keychain), and the public address.
@Observable
final class RemoteAccess {
    let hostId: String
    @ObservationIgnored let psk: Data
    private(set) var publicIPv4: String?
    @ObservationIgnored private var refreshTimer: Timer?

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "hostId") {
            hostId = saved
        } else {
            hostId = UUID().uuidString
            defaults.set(hostId, forKey: "hostId")
        }
        if let saved = Keychain.loadKey() {
            psk = saved
        } else {
            var key = Data(count: 32)
            _ = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            Keychain.saveKey(key)
            psk = key
        }
    }

    /// Looks up the public IPv4 now and every 15 minutes.
    func startRefreshing() {
        refreshPublicIP()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            self?.refreshPublicIP()
        }
    }

    func pairInfo(name: String) -> PairInfo {
        let (lan, v6) = NetworkAddresses.reachable()
        return PairInfo(hostId: hostId, name: name, psk: psk, lan: lan,
                        publicV4: publicIPv4.map { [$0] } ?? [], v6: v6)
    }

    private func refreshPublicIP() {
        var request = URLRequest(url: URL(string: "https://api.ipify.org")!)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data, let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  IPv4Address(ip) != nil else { return }
            DispatchQueue.main.async { self?.publicIPv4 = ip }
        }.resume()
    }
}

/// The remote-access key, stored as a generic password.
private enum Keychain {
    private static let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "com.hadevs.pult.host",
        kSecAttrAccount: "remote-psk",
    ]

    static func loadKey() -> Data? {
        var lookup = query
        lookup[kSecReturnData] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let key = result as? Data, key.count == 32 else { return nil }
        return key
    }

    static func saveKey(_ key: Data) {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData] = key
        SecItemAdd(item as CFDictionary, nil)
    }
}
