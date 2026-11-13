import Foundation
import Security

/// How DozzleDesk proves who it is to a Dozzle server and anything in front of it.
/// Every field is optional; an empty value means "not used". Stored only in the Keychain.
public struct ServerAuth: Codable, Sendable, Equatable {
    /// Dozzle's own login (`DOZZLE_AUTH_PROVIDER=simple`): exchanged for a session at `/api/token`.
    public var username: String
    public var password: String
    /// HTTP basic auth at a reverse proxy (Caddy `basic_auth`, nginx `auth_basic`, Traefik `basicAuth`).
    public var proxyUsername: String
    public var proxyPassword: String
    /// Extra headers sent with every request: a bearer token, Cloudflare Access service-token
    /// headers, or whatever the proxy in front of Dozzle expects.
    public var headers: [HTTPHeader]

    public init(username: String = "", password: String = "", proxyUsername: String = "",
                proxyPassword: String = "", headers: [HTTPHeader] = []) {
        self.username = username
        self.password = password
        self.proxyUsername = proxyUsername
        self.proxyPassword = proxyPassword
        self.headers = headers
    }

    public static let none = ServerAuth()

    public var usesDozzleLogin: Bool { !username.isEmpty }
    public var usesProxyLogin: Bool { !proxyUsername.isEmpty }
    public var usesHeaders: Bool { !headers.isEmpty }
    public var usesProxyAuth: Bool { usesProxyLogin || usesHeaders }
    public var isEmpty: Bool { !usesDozzleLogin && !usesProxyAuth }

    /// The `Authorization` value for proxy basic auth, if configured.
    var proxyAuthorization: String? {
        guard usesProxyLogin else { return nil }
        return "Basic " + Data("\(proxyUsername):\(proxyPassword)".utf8).base64EncodedString()
    }
}

public struct HTTPHeader: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Parses the "one `Name: value` per line" text the setup window collects.
public enum HeaderText {
    public enum Problem: Error, Equatable, Sendable {
        case malformed(line: Int)
        case invalidName(String)
        case reserved(String)
        case duplicateAuthorization

        public var message: String {
            switch self {
            case .malformed(let line): return "Header line \(line) needs to look like Name: value."
            case .invalidName(let name): return "“\(name)” isn't a valid header name."
            case .reserved(let name): return "DozzleDesk sets “\(name)” itself, so it can't be added as a header."
            case .duplicateAuthorization:
                return "Use either a proxy username and password or an Authorization header, not both."
            }
        }
    }

    /// Headers URLSession or DozzleDesk own; overriding them breaks the connection or the session.
    static let reserved: Set<String> = [
        "host", "content-length", "content-type", "connection", "transfer-encoding", "upgrade",
        "accept", "accept-encoding", "cache-control", "te", "trailer", "keep-alive", "proxy-connection",
    ]
    private static let tokenCharacters = CharacterSet(
        charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    public static func parse(_ text: String, proxyLogin: Bool = false) -> Result<[HTTPHeader], Problem> {
        var out: [HTTPHeader] = []
        // "\r\n" is a single Character in Swift, so normalize line endings before splitting.
        let unixText = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for (i, raw) in unixText.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else { return .failure(.malformed(line: i + 1)) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.unicodeScalars.allSatisfy(tokenCharacters.contains) else {
                return .failure(name.isEmpty ? .malformed(line: i + 1) : .invalidName(name))
            }
            guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                return .failure(.malformed(line: i + 1))
            }
            if reserved.contains(name.lowercased()) { return .failure(.reserved(name)) }
            if proxyLogin && name.lowercased() == "authorization" { return .failure(.duplicateAuthorization) }
            out.append(HTTPHeader(name: name, value: value))
        }
        return .success(out)
    }

    public static func format(_ headers: [HTTPHeader]) -> String {
        headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }
}

// MARK: - Storage

/// Where per-server credentials live. The app uses the Keychain; tests use memory.
public protocol CredentialStore: Sendable {
    func load(for server: URL) -> ServerAuth
    func save(_ auth: ServerAuth, for server: URL) throws
    func delete(for server: URL)
}

public struct MemoryCredentialStore: CredentialStore {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var items: [String: ServerAuth] = [:]
    }
    private let box = Box()
    public init() {}
    public func load(for server: URL) -> ServerAuth {
        box.lock.withLock { box.items[server.absoluteString] ?? .none }
    }
    public func save(_ auth: ServerAuth, for server: URL) throws {
        box.lock.withLock { box.items[server.absoluteString] = auth.isEmpty ? nil : auth }
    }
    public func delete(for server: URL) {
        box.lock.withLock { box.items[server.absoluteString] = nil }
    }
}

/// One generic-password item per Dozzle address, in the login keychain.
public struct KeychainCredentialStore: CredentialStore {
    public struct Failure: Error, CustomStringConvertible {
        public var status: OSStatus
        public var description: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    private let service: String
    public init(service: String = AppIdentity.id + ".server") { self.service = service }

    private func query(_ server: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: server.absoluteString]
    }

    public func load(for server: URL) -> ServerAuth {
        var q = query(server)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let auth = try? JSONDecoder().decode(ServerAuth.self, from: data) else { return .none }
        return auth
    }

    public func save(_ auth: ServerAuth, for server: URL) throws {
        guard !auth.isEmpty else { return delete(for: server) }
        let data = try JSONEncoder().encode(auth)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query(server) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(server)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "DozzleDesk: \(server.host ?? server.absoluteString)"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func delete(for server: URL) {
        SecItemDelete(query(server) as CFDictionary)
    }
}

// MARK: - Environment (scripting and `--check`)

extension ServerAuth {
    /// `DOZZLEDESK_USERNAME`, `DOZZLEDESK_PASSWORD`, `DOZZLEDESK_PROXY_USERNAME`,
    /// `DOZZLEDESK_PROXY_PASSWORD` and `DOZZLEDESK_HEADERS` (one `Name: value` per line).
    /// nil when none are set; they then replace the saved credentials for that run.
    public static func fromEnvironment(_ env: [String: String]) -> Result<ServerAuth, HeaderText.Problem>? {
        let keys = ["USERNAME", "PASSWORD", "PROXY_USERNAME", "PROXY_PASSWORD", "HEADERS"].map { "DOZZLEDESK_" + $0 }
        guard keys.contains(where: { env[$0] != nil }) else { return nil }
        let proxyUser = env["DOZZLEDESK_PROXY_USERNAME"] ?? ""
        return HeaderText.parse(env["DOZZLEDESK_HEADERS"] ?? "", proxyLogin: !proxyUser.isEmpty).map {
            ServerAuth(username: env["DOZZLEDESK_USERNAME"] ?? "", password: env["DOZZLEDESK_PASSWORD"] ?? "",
                       proxyUsername: proxyUser, proxyPassword: env["DOZZLEDESK_PROXY_PASSWORD"] ?? "",
                       headers: $0)
        }
    }

    /// `DOZZLEDESK_CERT_SHA256`: a certificate fingerprint to trust for that run (colons optional).
    public static func certificateFromEnvironment(_ env: [String: String]) -> String? {
        env["DOZZLEDESK_CERT_SHA256"].map { $0.replacingOccurrences(of: ":", with: "").uppercased() }
    }
}
