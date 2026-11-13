import CryptoKit
import Foundation
import Security

/// A server certificate macOS didn't trust, as shown to the user before they choose to trust it.
public struct CertificateInfo: Sendable, Equatable {
    /// "host:port" the certificate was presented for.
    public var server: String
    public var subject: String
    /// Uppercase hex SHA-256 of the leaf certificate (DER), no separators.
    public var fingerprint: String
    /// Why macOS rejected it, in its own words (self-signed, expired, wrong name…).
    public var reason: String
    /// True when a different certificate was trusted for this server before.
    public var replacesTrusted: Bool

    /// "AB:CD:…" in two lines of 16 bytes, the way certificate viewers show it.
    public var displayFingerprint: String { CertificatePins.display(fingerprint) }
}

/// Certificates the user explicitly trusted, one per server ("host:port" → SHA-256).
/// Pinning a single certificate is narrower than trusting a CA or turning checks off:
/// a different certificate for the same server is still refused.
public enum CertificatePins {
    public static let defaultsKey = "trustedCertificates"

    public static func serverKey(_ url: URL) -> String {
        let host = (url.host ?? "").lowercased()
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        return "\(host):\(port)"
    }

    public static func pin(for url: URL, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: defaultsKey) as? [String: String])?[serverKey(url)]
    }

    public static func setPin(_ fingerprint: String?, for url: URL, defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        all[serverKey(url)] = fingerprint
        defaults.set(all, forKey: defaultsKey)
    }

    public static func fingerprint(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }

    public static func display(_ hex: String) -> String {
        let pairs = stride(from: 0, to: hex.count, by: 2).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: 2, limitedBy: hex.endIndex)!])
        }
        let half = (pairs.count + 1) / 2
        return [pairs.prefix(half), pairs.dropFirst(half)].map { $0.joined(separator: ":") }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// URLSession delegate that applies normal certificate checks, except that a certificate the
/// user pinned for this exact server is accepted. Only challenges for `server` are touched.
final class TrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let server: String
    private let pinned: String?
    private let lock = NSLock()
    private var rejected: CertificateInfo?

    init(baseURL: URL, pinned: String?) {
        self.server = CertificatePins.serverKey(baseURL)
        self.pinned = pinned
    }

    /// The last certificate refused for this server, if any.
    var rejectedCertificate: CertificateInfo? { lock.withLock { rejected } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust,
              "\(space.host.lowercased()):\(space.port)" == server else {
            return completionHandler(.performDefaultHandling, nil)
        }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            return completionHandler(.performDefaultHandling, nil)
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }
        let fingerprint = CertificatePins.fingerprint(of: leaf)
        if fingerprint == pinned {
            return completionHandler(.useCredential, URLCredential(trust: trust))
        }
        let reason = error.map { CFErrorCopyDescription($0) as String } ?? "The certificate isn't trusted."
        let info = CertificateInfo(server: server,
                                   subject: (SecCertificateCopySubjectSummary(leaf) as String?) ?? server,
                                   fingerprint: fingerprint, reason: reason, replacesTrusted: pinned != nil)
        lock.withLock { rejected = info }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
