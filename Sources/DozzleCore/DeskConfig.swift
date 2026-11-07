import Foundation

/// Settings resolved from (highest priority first) CLI flags, UserDefaults, defaults.
///
///   --url http://narciso-linux:9900   Dozzle base URL (include DOZZLE_BASE path if set)
///   --grace 120                       seconds to keep retrying before exiting
///   --stall 25                        seconds of silence that count as a dead connection
///   --opacity 1.0                     panel opacity, 0.3–1.0
///   --no-card / --card                dropdown only / show the desktop card (this launch only)
///   --render-png out.png              dev: render one frame to PNG and exit
///   --render-when live|lost           dev: which state to render (default live)
///   --render-delay 3                  dev: seconds to wait in that state before rendering
public struct DeskConfig: Sendable, Equatable {
    public static let defaultURL = "http://narciso-linux:9900"

    public var baseURL: URL
    public var grace: TimeInterval
    public var stallTimeout: TimeInterval
    public var opacity: Double
    /// `--no-card` / `--card` override the saved "Show Desktop Card" choice for this launch.
    public var showCard: Bool?
    public var renderPNG: String?
    public var renderWhen: String
    public var renderDelay: TimeInterval

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

    public static func load(arguments: [String], defaults: UserDefaults = .standard) -> DeskConfig {
        func flag(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: "--\(name)"), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        func number(_ name: String) -> Double? {
            if let s = flag(name), let d = Double(s) { return d }
            return defaults.object(forKey: name) == nil ? nil : defaults.double(forKey: name)
        }
        let rawURL = flag("url") ?? defaults.string(forKey: "url") ?? defaultURL
        let url = normalize(rawURL) ?? URL(string: defaultURL)!
        var config = DeskConfig(
            baseURL: url,
            grace: max(5, number("grace") ?? 120),
            stallTimeout: max(5, number("stall") ?? 25),
            opacity: min(1, max(0.3, number("opacity") ?? 1)),
            renderPNG: flag("render-png"),
            renderWhen: flag("render-when") ?? "live",
            renderDelay: max(0, Double(flag("render-delay") ?? "") ?? 3))
        if arguments.contains("--no-card") { config.showCard = false }
        if arguments.contains("--card") { config.showCard = true }
        return config
    }

    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), u.host != nil, ["http", "https"].contains(u.scheme ?? "") else { return nil }
        return u
    }

    private func endpoint(_ path: String) -> URL { URL(string: baseURL.absoluteString + path)! }

    public var healthURL: URL { endpoint("/healthcheck") }
    public var indexURL: URL { endpoint("/") }
    public var streamURL: URL { endpoint("/api/events/stream") }
    public func hostPage(_ id: String) -> URL { endpoint("/host/\(id)") }
    public func containerPage(_ id: String) -> URL { endpoint("/container/\(id)") }

    /// "narciso-linux:9900"
    public var displayHost: String {
        let host = baseURL.host ?? baseURL.absoluteString
        return baseURL.port.map { "\(host):\($0)" } ?? host
    }
}
