import Foundation

/// Settings resolved from (highest priority first) CLI flags, UserDefaults, defaults.
///
///   --url http://dozzle.lan:8080      Dozzle base URL for this launch (include the base path if Dozzle has one)
///   --grace 120                       seconds to keep retrying before exiting
///   --stall 25                        seconds of silence that count as a dead connection
///   --opacity 1.0                     panel opacity, 0.3–1.0
///   --no-card / --card                dropdown only / show the desktop card (this launch only)
///   --check URL                       test a Dozzle URL, print the result and exit
///   --render-png out.png              dev: render one frame to PNG and exit
///   --render-when live|lost           dev: which state to render (default live)
///   --render-delay 3                  dev: seconds to wait in that state before rendering
///
/// There is no built-in server address: without `--url` or a saved one, the app asks for it.
public struct DeskConfig: Sendable, Equatable {
    /// UserDefaults key for the saved Dozzle URL (written by the setup window).
    public static let urlKey = "url"

    public var baseURL: URL
    public var grace: TimeInterval
    public var stallTimeout: TimeInterval
    public var opacity: Double
    /// `--no-card` / `--card` override the saved "Show Desktop Card" choice for this launch.
    public var showCard: Bool?
    public var renderPNG: String?
    public var renderWhen: String
    public var renderDelay: TimeInterval
    /// Login, proxy credentials and headers for this server (from the Keychain; never in defaults).
    public var auth: ServerAuth = .none
    /// SHA-256 of a certificate the user chose to trust for this server (see CertificatePins).
    public var trustedCertificate: String?

    public init(baseURL: URL, grace: TimeInterval = 120, stallTimeout: TimeInterval = 25,
                opacity: Double = 1, renderPNG: String? = nil, renderWhen: String = "live",
                renderDelay: TimeInterval = 3) {
        self.baseURL = baseURL
        self.grace = grace
        self.stallTimeout = stallTimeout
        self.opacity = opacity
        self.renderPNG = renderPNG
        self.renderWhen = renderWhen
        self.renderDelay = renderDelay
    }

    /// The URL text the user asked for: `--url`, else the saved one. Not validated.
    public static func requestedURL(arguments: [String], defaults: UserDefaults = .standard) -> String? {
        flag("url", in: arguments) ?? defaults.string(forKey: urlKey)
    }

    /// nil when no usable Dozzle URL is configured yet (first launch, or a bad `--url`).
    public static func load(arguments: [String], defaults: UserDefaults = .standard) -> DeskConfig? {
        guard let url = requestedURL(arguments: arguments, defaults: defaults).flatMap(normalize) else { return nil }
        return load(arguments: arguments, defaults: defaults, baseURL: url)
    }

    /// All other settings, with an explicit server address.
    public static func load(arguments: [String], defaults: UserDefaults = .standard, baseURL: URL) -> DeskConfig {
        func number(_ name: String) -> Double? {
            if let s = flag(name, in: arguments), let d = Double(s) { return d }
            return defaults.object(forKey: name) == nil ? nil : defaults.double(forKey: name)
        }
        var config = DeskConfig(
            baseURL: baseURL,
            grace: max(5, number("grace") ?? 120),
            stallTimeout: max(5, number("stall") ?? 25),
            opacity: min(1, max(0.3, number("opacity") ?? 1)),
            renderPNG: flag("render-png", in: arguments),
            renderWhen: flag("render-when", in: arguments) ?? "live",
            renderDelay: max(0, Double(flag("render-delay", in: arguments) ?? "") ?? 3))
        if arguments.contains("--no-card") { config.showCard = false }
        if arguments.contains("--card") { config.showCard = true }
        return config
    }

    public static func flag(_ name: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: "--\(name)"), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    /// Like `normalize`, but `http://user:pass@host` is accepted and the credentials are handed
    /// back separately (for proxy basic auth) instead of being kept in the URL.
    public static func splitCredentials(_ raw: String) -> (url: URL, username: String, password: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard var parts = URLComponents(string: withScheme) else { return nil }
        let user = parts.user ?? "", password = parts.password ?? ""
        parts.user = nil
        parts.password = nil
        guard let stripped = parts.string, let url = normalize(stripped) else { return nil }
        return (url, user, password)
    }

    /// Accepts what people type: `dozzle.lan:8080`, `http://10.0.0.5:8080/`, `https://host/dozzle`.
    /// Adds `http://` when no scheme is given and drops trailing slashes. nil if it isn't an http(s) URL.
    public static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URLComponents(string: s), let host = u.host, !host.isEmpty,
              ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
              u.query == nil, u.fragment == nil, u.user == nil, u.password == nil,
              let url = u.url else { return nil }
        return url
    }

    private func endpoint(_ path: String) -> URL { URL(string: baseURL.absoluteString + path)! }

    public var healthURL: URL { endpoint("/healthcheck") }
    public var indexURL: URL { endpoint("/") }
    public var streamURL: URL { endpoint("/api/events/stream") }
    public var tokenURL: URL { endpoint("/api/token") }
    public func hostPage(_ id: String) -> URL { endpoint("/host/\(id)") }
    public func containerPage(_ id: String) -> URL { endpoint("/container/\(id)") }

    /// "dozzle.lan:8080" (plus the base path, if any)
    public var displayHost: String {
        let host = baseURL.host ?? baseURL.absoluteString
        let hostPort = baseURL.port.map { "\(host):\($0)" } ?? host
        let path = baseURL.path
        return path.isEmpty || path == "/" ? hostPort : hostPort + path
    }
}
