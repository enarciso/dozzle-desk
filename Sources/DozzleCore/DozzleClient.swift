import Foundation

/// The HTTP side of talking to one Dozzle: one URLSession with the user's certificate pin,
/// every request decorated with their proxy credentials and headers, and Dozzle's own login
/// session (the `jwt` cookie from `POST /api/token`) kept in memory only.
///
/// Credentials go only to the configured server: redirects to any other scheme, host or port
/// are refused rather than followed.
public final class DozzleClient: @unchecked Sendable {
    public enum LoginResult: Sendable, Equatable {
        case ok
        /// Dozzle said the username or password is wrong.
        case rejected
        /// No password login here (auth off, OIDC/GitHub only, or not Dozzle). Carries the HTTP status.
        case unavailable(Int)
    }

    public let config: DeskConfig
    public var auth: ServerAuth { config.auth }
    let session: URLSession
    private let delegate: TrustDelegate
    private let lock = NSLock()
    private var jwt: String?

    public init(config: DeskConfig, configuration: URLSessionConfiguration) {
        self.config = config
        configuration.httpCookieStorage = nil     // the session cookie is handled explicitly below
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        var headers = configuration.httpAdditionalHeaders ?? [:]
        headers["User-Agent"] = "DozzleDesk/\(AppIdentity.version)"
        configuration.httpAdditionalHeaders = headers
        self.delegate = TrustDelegate(baseURL: config.baseURL, pinned: config.trustedCertificate)
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// The certificate refused on the most recent connection, if that's why it failed.
    public var rejectedCertificate: CertificateInfo? { delegate.rejectedCertificate }
    public var hasSession: Bool { lock.withLock { jwt != nil } }
    public func clearSession() { lock.withLock { jwt = nil } }
    public func invalidate() { session.invalidateAndCancel() }

    public func request(_ url: URL, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        for header in auth.headers { req.setValue(header.value, forHTTPHeaderField: header.name) }
        if let basic = auth.proxyAuthorization { req.setValue(basic, forHTTPHeaderField: "Authorization") }
        if let token = lock.withLock({ jwt }) {
            // As a cookie, not a bearer token: Authorization may already belong to the proxy.
            let existing = req.value(forHTTPHeaderField: "Cookie").map { $0 + "; " } ?? ""
            req.setValue(existing + "jwt=\(token)", forHTTPHeaderField: "Cookie")
        }
        return req
    }

    public func data(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: request(url, timeout: timeout))
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        adoptSessionCookie(from: http)
        return (data, http)
    }

    public func bytes(_ req: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else {
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }
        adoptSessionCookie(from: http)
        return (bytes, http)
    }

    /// Signs in with Dozzle's own login. The only non-GET request DozzleDesk makes; it changes
    /// nothing on the server.
    public func login(timeout: TimeInterval = 10) async throws -> LoginResult {
        guard auth.usesDozzleLogin else { return .unavailable(0) }
        var req = request(config.tokenURL, timeout: timeout)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Self.form(["username": auth.username, "password": auth.password]).utf8)
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200:
            clearSession()
            adoptSessionCookie(from: http)
            return hasSession ? .ok : .unavailable(200)
        case 401, 403:
            return .rejected
        default:
            return .unavailable(http.statusCode)
        }
    }

    /// Dozzle re-issues the cookie once a session is half way through its lifetime.
    private func adoptSessionCookie(from response: HTTPURLResponse) {
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { out, pair in
            if let k = pair.key as? String, let v = pair.value as? String { out[k] = v }
        }
        guard let url = response.url,
              let cookie = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).last(where: { $0.name == "jwt" })
        else { return }
        let expired = cookie.expiresDate.map { $0 <= Date() } ?? false
        lock.withLock { jwt = (cookie.value.isEmpty || expired) ? nil : cookie.value }
    }

    static func form(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }
}

extension TrustDelegate: URLSessionTaskDelegate {
    /// Follow redirects only within the same origin, so headers and cookies never leave it.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let from = response.url, let to = request.url,
              from.scheme?.lowercased() == to.scheme?.lowercased(),
              CertificatePins.serverKey(from) == CertificatePins.serverKey(to) else {
            return completionHandler(nil)
        }
        completionHandler(request)
    }
}
