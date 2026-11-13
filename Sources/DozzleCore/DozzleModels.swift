import Foundation

// Decodable views of Dozzle's JSON (internal/container/types.go, host.go, events.go).
// Only the fields the dashboard uses are decoded; every optional field decodes leniently so
// a schema change in a future Dozzle release degrades a value instead of dropping an event.

extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

public struct DzHost: Decodable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var nCPU: Int?
    public var memTotal: Double?
    public var diskTotal: Double?
    public var diskFree: Double?
    public var type: String?
    public var endpoint: String?
    public var available: Bool?
    public var removed: Bool?
    public var replacesId: String?

    enum CodingKeys: String, CodingKey {
        case id, name, nCPU, memTotal, diskTotal, diskFree, type, endpoint, available, removed, replacesId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.lenient(String.self, .name) ?? id
        nCPU = c.lenient(Int.self, .nCPU)
        memTotal = c.lenient(Double.self, .memTotal)
        diskTotal = c.lenient(Double.self, .diskTotal)
        diskFree = c.lenient(Double.self, .diskFree)
        type = c.lenient(String.self, .type)
        endpoint = c.lenient(String.self, .endpoint)
        available = c.lenient(Bool.self, .available)
        removed = c.lenient(Bool.self, .removed)
        replacesId = c.lenient(String.self, .replacesId)
    }
}

/// Columnar stats history. Float columns (cpu, memory) are plain; integer columns
/// (memoryUsage, …) are delta-encoded: first value absolute, the rest are differences.
public struct DzStatsHistory: Decodable, Sendable, Equatable {
    public var cpu: [Double]?
    public var memory: [Double]?
    public var memoryUsage: [Double]?

    enum CodingKeys: String, CodingKey { case cpu, memory, memoryUsage }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cpu = c.lenient([Double].self, .cpu)
        memory = c.lenient([Double].self, .memory)
        memoryUsage = c.lenient([Double].self, .memoryUsage)
    }

    /// Latest absolute memory usage in bytes (sum of the delta-encoded column).
    public var latestMemoryUsage: Double? { memoryUsage.map { $0.reduce(0, +) } }
}

public struct DzContainer: Decodable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var image: String?
    public var state: String
    public var health: String?
    public var host: String
    public var startedAt: String?
    public var stats: DzStatsHistory?
    public var labels: [String: String]?

    enum CodingKeys: String, CodingKey { case id, name, image, state, health, host, startedAt, stats, labels }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.lenient(String.self, .name) ?? id
        image = c.lenient(String.self, .image)
        state = c.lenient(String.self, .state) ?? "unknown"
        health = c.lenient(String.self, .health)
        host = c.lenient(String.self, .host) ?? ""
        startedAt = c.lenient(String.self, .startedAt)
        stats = c.lenient(DzStatsHistory.self, .stats)
        labels = c.lenient([String: String].self, .labels)
    }
}

public struct DzStat: Decodable, Sendable, Equatable {
    public var id: String
    public var cpu: Double
    public var memory: Double
    public var memoryUsage: Double

    enum CodingKeys: String, CodingKey { case id, cpu, memory, memoryUsage }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        cpu = c.lenient(Double.self, .cpu) ?? 0
        memory = c.lenient(Double.self, .memory) ?? 0
        memoryUsage = c.lenient(Double.self, .memoryUsage) ?? 0
    }
}

public struct DzHostMetrics: Decodable, Sendable, Equatable {
    public var id: String
    public var metricsAvailable: Bool?
    public var load1: Double?
    public var uptime: Double?
    public var diskTotal: Double?
    public var diskFree: Double?

    enum CodingKeys: String, CodingKey { case id, metricsAvailable, load1, uptime, diskTotal, diskFree }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        metricsAvailable = c.lenient(Bool.self, .metricsAvailable)
        load1 = c.lenient(Double.self, .load1)
        uptime = c.lenient(Double.self, .uptime)
        diskTotal = c.lenient(Double.self, .diskTotal)
        diskFree = c.lenient(Double.self, .diskFree)
    }
}

/// `container-event`: `{name: "die"|"start"|…, host, actorId, time}`.
public struct DzContainerEvent: Decodable, Sendable, Equatable {
    public var action: String
    public var host: String?
    public var actorId: String
    public var time: Date?

    enum CodingKeys: String, CodingKey { case name, host, actorId, time }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = c.lenient(String.self, .name) ?? ""
        host = c.lenient(String.self, .host)
        actorId = try c.decode(String.self, forKey: .actorId)
        if let s = c.lenient(String.self, .time) {
            time = DozzleDate.parse(s)
        } else if let n = c.lenient(Double.self, .time) {
            time = Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        } else {
            time = nil
        }
    }
}

public struct DzHealthEvent: Decodable, Sendable, Equatable {
    public var actorId: String
    public var health: String
}

public struct DzVersion: Decodable, Sendable, Equatable {
    public var version: String
}

/// The app config Dozzle embeds in its index page as `<script id="config__json">`.
/// Signed out, Dozzle redirects to its login page, whose config has no hosts but says how to sign in.
public struct DzIndexConfig: Decodable, Sendable, Equatable {
    public var version: String?
    public var authProvider: String?
    /// "server" (default), "swarm" or "k8s".
    public var mode: String?
    public var hosts: [DzHost]
    /// Login page only: whether Dozzle's username/password form can work.
    public var passwordLogin: Bool?
    /// Login page only: names of the external sign-in providers (GitHub, OIDC…).
    public var oauthProviders: [String]

    private struct Provider: Decodable { var name: String? }
    enum CodingKeys: String, CodingKey { case version, authProvider, mode, hosts, passwordLogin, oauthProviders }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenient(String.self, .version)
        authProvider = c.lenient(String.self, .authProvider)
        mode = c.lenient(String.self, .mode)
        hosts = c.lenient([DzHost].self, .hosts) ?? []
        passwordLogin = c.lenient(Bool.self, .passwordLogin)
        oauthProviders = (c.lenient([Provider].self, .oauthProviders) ?? []).compactMap(\.name)
    }

    /// "Swarm" / "Kubernetes" for display; nil for the ordinary server mode.
    public var modeLabel: String? {
        switch mode?.lowercased() {
        case "swarm": return "Swarm"
        case "k8s": return "Kubernetes"
        default: return nil
        }
    }

    public static func parse(html: String) -> DzIndexConfig? {
        guard let marker = html.range(of: "id=\"config__json\"") else { return nil }
        guard let open = html.range(of: ">", range: marker.upperBound..<html.endIndex) else { return nil }
        guard let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex) else { return nil }
        let json = html[open.upperBound..<close.lowerBound]
        return try? JSONDecoder().decode(DzIndexConfig.self, from: Data(json.utf8))
    }
}

/// Go RFC3339Nano timestamps (`2026-11-06T21:38:21.395328394Z`); zero time → nil.
public enum DozzleDate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parse(_ raw: String) -> Date? {
        if raw.isEmpty || raw.hasPrefix("0001-") { return nil }
        // Trim nanoseconds to milliseconds; ISO8601DateFormatter handles at most 3 digits reliably.
        var s = raw
        if let dot = s.firstIndex(of: "."), let t = s.firstIndex(of: "T"), dot > t {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            let digits = s[s.index(after: dot)..<end]
            let ms = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            s.replaceSubrange(dot..<end, with: "." + ms)
        }
        return withFraction.date(from: s) ?? plain.date(from: s)
    }
}
