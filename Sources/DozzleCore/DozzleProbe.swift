import Foundation

/// The result of checking a URL the user typed.
public enum ProbeOutcome: Sendable, Equatable {
    case ok(version: String?, mode: String?, hosts: Int)
    case invalidURL
    case unreachable(String)
    /// Something answered, but it isn't Dozzle (or a login page / proxy is in the way).
    case notDozzle
    /// Dozzle's own login is on and no username was given.
    case loginRequired
    /// Dozzle's own login refused the username or password.
    case loginRejected
    /// Dozzle only signs in through external providers (GitHub, OIDC), which an app can't use.
    case loginUnsupported(providers: [String])
    /// A proxy in front of Dozzle wants credentials (none given, or the ones given were refused).
    case proxyAuthRequired(rejected: Bool)
    /// Dozzle runs in forward-proxy mode and nothing in front of it identified the user.
    case proxyDidNotIdentify
    /// The event stream refused us for a reason none of the above explains.
    case authRequired
    /// HTTPS certificate macOS doesn't trust; the user can choose to trust this one certificate.
    case untrustedCertificate(CertificateInfo)
    case httpError(Int)

    public var isOK: Bool { if case .ok = self { return true } else { return false } }

    public var message: String {
        switch self {
        case .ok(let version, let mode, let hosts):
            let v = version.map { "Dozzle \($0)" } ?? "Dozzle"
            let m = mode.map { " (\($0))" } ?? ""
            return "Found \(v)\(m) · \(hosts) host\(hosts == 1 ? "" : "s")"
        case .invalidURL:
            return "That isn't a valid http:// or https:// address."
        case .unreachable(let why):
            return why
        case .notDozzle:
            return "Something answered, but it isn't Dozzle. Check the port and base path, or whether a login page or proxy is in front of it."
        case .loginRequired:
            return "This Dozzle has its own login. Enter your Dozzle username and password."
        case .loginRejected:
            return "Dozzle didn't accept that username and password."
        case .loginUnsupported(let providers):
            let via = providers.isEmpty ? "an external provider" : providers.joined(separator: " or ")
            return "This Dozzle signs in only through \(via), which DozzleDesk can't use. It works with Dozzle's username and password login, or with a proxy that signs you in through headers."
        case .proxyAuthRequired(let rejected):
            return rejected
                ? "The proxy in front of Dozzle didn't accept those credentials or headers."
                : "A proxy in front of Dozzle wants you to sign in. Add its username and password, or the headers it expects, under Proxy & headers."
        case .proxyDidNotIdentify:
            return "Dozzle expects the proxy in front of it to say who you are, and nothing did. Add the headers your proxy needs under Proxy & headers, or connect through the proxy's address."
        case .authRequired:
            return "Dozzle refused the event stream (HTTP 401). Check the login, proxy headers and the user's permissions."
        case .untrustedCertificate(let cert):
            return cert.replacesTrusted
                ? "\(cert.server) now presents a different HTTPS certificate from the one you trusted."
                : "\(cert.server)'s HTTPS certificate isn't trusted by this Mac."
        case .httpError(let code):
            return "Dozzle answered with HTTP \(code)."
        }
    }
}

public struct ProbeResult: Sendable, Equatable {
    public var url: URL?
    public var outcome: ProbeOutcome
}

/// Checks that a URL points at a Dozzle the app can stream from, with the given credentials:
/// `/healthcheck` answers, the login (if any) works, `/` carries Dozzle's embedded config, and
/// the event stream opens. The stream is closed as soon as its headers arrive.
public enum DozzleProbe {
    public static func check(_ raw: String, auth: ServerAuth = .none, trustedCertificate: String? = nil,
                             timeout: TimeInterval = 6) async -> ProbeResult {
        guard let url = DeskConfig.normalize(raw) else { return ProbeResult(url: nil, outcome: .invalidURL) }
        var config = DeskConfig(baseURL: url)
        config.auth = auth
        config.trustedCertificate = trustedCertificate

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 4
        cfg.waitsForConnectivity = false
        let client = DozzleClient(config: config, configuration: cfg)
        defer { client.invalidate() }
        return ProbeResult(url: url, outcome: await outcome(client, timeout: timeout))
    }

    static func outcome(_ client: DozzleClient, timeout: TimeInterval) async -> ProbeOutcome {
        let config = client.config, auth = client.auth
        do {
            // Dozzle answers /healthcheck without a login, so a 401 here comes from a proxy.
            let (_, health) = try await client.data(config.healthURL, timeout: timeout)
            switch health.statusCode {
            case 200: break
            case 401, 403: return .proxyAuthRequired(rejected: auth.usesProxyAuth)
            // A redirect we didn't follow points somewhere else: a sign-in portal (Authelia, Authentik…).
            case 300..<400: return .proxyAuthRequired(rejected: auth.usesProxyAuth)
            case 404: return .notDozzle
            case let code: return .httpError(code)
            }

            if auth.usesDozzleLogin {
                if case .rejected = try await client.login(timeout: timeout) { return .loginRejected }
            }

            let (html, index) = try await client.data(config.indexURL, timeout: timeout)
            if index.statusCode == 401 || index.statusCode == 403 {
                // Forward-proxy mode answers a request with no identity headers this way.
                return String(decoding: html, as: UTF8.self).contains("Unauthorized user")
                    ? .proxyDidNotIdentify : .proxyAuthRequired(rejected: auth.usesProxyAuth)
            }
            if (300..<400).contains(index.statusCode) { return .proxyAuthRequired(rejected: auth.usesProxyAuth) }
            guard index.statusCode == 200, let dz = DzIndexConfig.parse(html: String(decoding: html, as: UTF8.self)) else {
                return .notDozzle
            }
            if isLoginPage(index) {
                if dz.passwordLogin == false { return .loginUnsupported(providers: dz.oauthProviders) }
                return auth.usesDozzleLogin ? .loginRejected : .loginRequired
            }

            var req = client.request(config.streamURL, timeout: timeout)
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let (bytes, stream) = try await client.bytes(req)
            bytes.task.cancel()
            switch stream.statusCode {
            case 200: return .ok(version: dz.version, mode: dz.modeLabel, hosts: dz.hosts.count)
            case 401, 403: return auth.usesDozzleLogin ? .loginRejected : .authRequired
            case 404: return .notDozzle
            case let code: return .httpError(code)
            }
        } catch {
            if let cert = client.rejectedCertificate { return .untrustedCertificate(cert) }
            return .unreachable(describe(error, host: config.baseURL.host ?? config.displayHost))
        }
    }

    /// Signed out, Dozzle redirects `/` to `<base>/login`.
    static func isLoginPage(_ response: HTTPURLResponse) -> Bool {
        response.url?.path.hasSuffix("/login") ?? false
    }

    static func describe(_ error: Error, host: String) -> String {
        guard let e = error as? URLError else { return error.localizedDescription }
        switch e.code {
        case .cannotFindHost, .dnsLookupFailed:
            return "Can't find a server named “\(host)”."
        case .cannotConnectToHost:
            return "\(host) refused the connection. Is Dozzle running on that port?"
        case .timedOut:
            return "\(host) didn't answer in time."
        case .notConnectedToInternet, .networkConnectionLost:
            return "This Mac isn't connected to a network."
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .secureConnectionFailed:
            return "\(host)'s HTTPS certificate isn't trusted by this Mac."
        case .appTransportSecurityRequiresSecureConnection:
            return "macOS blocked plain http:// to \(host). Use https://."
        case .httpTooManyRedirects:
            return "\(host) kept redirecting. Check the base path."
        default:
            return e.localizedDescription
        }
    }
}
