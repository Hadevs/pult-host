import CryptoKit
import Foundation
import Network
import Security

extension Pult {
    /// Connection parameters for both sides. With a key this is TLS 1.2
    /// restricted to a pre-shared-key cipher suite (the pattern of Apple's
    /// peer-to-peer sample): a peer without the 256-bit key can't even finish
    /// the handshake. Without a key it is plain TCP for the home network.
    static func parameters(psk: Data?) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.connectionTimeout = 8

        var tls: NWProtocolTLS.Options?
        if let psk {
            let options = NWProtocolTLS.Options()
            // TLS gets a derived key, never the stored secret itself.
            let derived = HMAC<SHA256>.authenticationCode(for: Data("Pult TLS v1".utf8), using: SymmetricKey(data: psk))
            let key = derived.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = Data("pult".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            let sec = options.securityProtocolOptions
            sec_protocol_options_add_pre_shared_key(sec, key as __DispatchData, identity as __DispatchData)
            sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
            sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
            sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
            tls = options
        }

        let params = NWParameters(tls: tls, tcp: tcp)
        params.serviceClass = .interactiveVideo
        return params
    }
}
