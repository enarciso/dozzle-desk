import Foundation

/// The lowest log level the logs panel shows. Lines Dozzle couldn't assign a level to
/// ("unknown": plain output with no level marker) count as Info.
public enum LogLevel: String, CaseIterable, Sendable {
    case error, warn, info, debug, trace

    public static let `default` = LogLevel.info

    public var title: String {
        switch self {
        case .error: return "Errors"
        case .warn: return "Warnings and Errors"
        case .info: return "Info and Above"
        case .debug: return "Debug and Above"
        case .trace: return "Everything (Trace)"
        }
    }

    /// Dozzle's level names this threshold asks for (`levels=` on the stream request).
    public var dozzleLevels: [String] {
        switch self {
        case .error: return ["fatal", "error"]
        case .warn: return ["fatal", "error", "warn"]
        case .info: return ["fatal", "error", "warn", "info", "unknown"]
        case .debug: return ["fatal", "error", "warn", "info", "unknown", "debug"]
        case .trace: return ["fatal", "error", "warn", "info", "unknown", "debug", "trace"]
        }
    }

    public func includes(_ severity: LogLine.Severity) -> Bool {
        dozzleLevels.contains(severity.rawValue)
    }
}

/// One log line as the panel shows it: already cleaned, flattened and shortened.
public struct LogLine: Sendable, Equatable, Identifiable {
    public enum Severity: String, Sendable {
        case fatal, error, warn, info, debug, trace, unknown

        init(dozzle raw: String?) {
            switch raw?.lowercased() {
            case "fatal", "panic", "critical", "crit", "emerg", "alert": self = .fatal
            case "error", "err": self = .error
            case "warn", "warning": self = .warn
            case "info", "notice": self = .info
            case "debug": self = .debug
            case "trace": self = .trace
            default: self = .unknown
            }
        }
    }

    /// Arrival order, unique for this run.
    public var id: Int
    public var time: Date
    /// Key of the container (the same form the dashboard uses for container pages).
    public var containerId: String
    public var containerName: String
    public var hostId: String
    public var severity: Severity
    public var stderr: Bool
    public var text: String
}

/// What the UI gets with each status: the newest lines and how fast they're coming.
public struct LogFeed: Sendable, Equatable {
    public var level: LogLevel
    /// Oldest first, at most `LogBuffer.shown` lines.
    public var lines: [LogLine]
    /// Lines per second over the last few seconds.
    public var rate: Double
    /// Hosts the panel is streaming from / should be.
    public var streaming: Int
    public var hosts: Int

    public init(level: LogLevel, lines: [LogLine] = [], rate: Double = 0, streaming: Int = 0, hosts: Int = 0) {
        self.level = level
        self.lines = lines
        self.rate = rate
        self.streaming = streaming
        self.hosts = hosts
    }
}

/// Recent lines across every container, oldest first and bounded. Lines from different
/// containers arrive slightly out of order (each container's backfill comes separately),
/// so they're inserted by timestamp. Repeats (the same line delivered again when a stream
/// restarts) are dropped.
public struct LogBuffer: Sendable {
    public static let shown = 12
    public let capacity: Int
    public private(set) var lines: [LogLine] = []
    private var seen: [String: Int] = [:]   // dedupe key → line id
    private var nextId = 0
    private var arrivals: [Date] = []

    public init(capacity: Int = 200) { self.capacity = max(Self.shown, capacity) }

    /// Adds a line. `key` identifies the same line across stream restarts.
    @discardableResult
    public mutating func add(_ line: LogLine, key: String, now: Date) -> Bool {
        guard seen[key] == nil else { return false }
        if lines.count >= capacity, let oldest = lines.first, line.time < oldest.time { return false }
        var l = line
        l.id = nextId
        nextId += 1
        // Binary search for the first line newer than this one (stable for equal times).
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= l.time { lo = mid + 1 } else { hi = mid }
        }
        lines.insert(l, at: lo)
        seen[key] = l.id
        if lines.count > capacity {
            let dropped = lines.removeFirst()
            seen = seen.filter { $0.value != dropped.id }
        }
        arrivals.append(now)
        return true
    }

    /// Keeps only the lines a new level threshold still shows.
    public mutating func filter(_ level: LogLevel) {
        lines.removeAll { !level.includes($0.severity) }
        let ids = Set(lines.map(\.id))
        seen = seen.filter { ids.contains($0.value) }
    }

    public mutating func removeAll() {
        lines.removeAll()
        seen.removeAll()
        arrivals.removeAll()
    }

    /// Lines per second over the last `window` seconds.
    public mutating func rate(now: Date, window: TimeInterval = 10) -> Double {
        let cutoff = now.addingTimeInterval(-window)
        if let i = arrivals.firstIndex(where: { $0 > cutoff }) { arrivals.removeFirst(i) } else { arrivals.removeAll() }
        return Double(arrivals.count) / window
    }

    public var newest: [LogLine] { Array(lines.suffix(Self.shown)) }
}

/// Dozzle's log-stream event (the default "message" SSE event of `/api/hosts/{id}/logs/stream`).
struct DzLogEvent: Decodable {
    var m: JSONValue?
    var ts: Double?
    var id: UInt64?
    var l: String?
    var s: String?
    var c: String?
}

/// Just enough of JSON to flatten structured log messages.
indirect enum JSONValue: Decodable, Equatable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([(String, JSONValue)])

    static func == (a: JSONValue, b: JSONValue) -> Bool { a.compact == b.compact }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        if let obj = try? decoder.container(keyedBy: Key.self) {
            // allKeys loses the original order; sort for a stable rendering.
            self = .object(try obj.allKeys.sorted { $0.stringValue < $1.stringValue }.map {
                ($0.stringValue, try obj.decode(JSONValue.self, forKey: $0))
            })
            return
        }
        if var arr = try? decoder.unkeyedContainer() {
            var items: [JSONValue] = []
            while !arr.isAtEnd { items.append(try arr.decode(JSONValue.self)) }
            self = .array(items)
            return
        }
        let v = try decoder.singleValueContainer()
        if v.decodeNil() { self = .null }
        else if let b = try? v.decode(Bool.self) { self = .bool(b) }
        else if let n = try? v.decode(Double.self) { self = .number(n) }
        else { self = .string(try v.decode(String.self)) }
    }

    var compact: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let a): return "[" + a.map(\.quoted).joined(separator: ",") + "]"
        case .object(let o): return "{" + o.map { "\($0.0)=\($0.1.quoted)" }.joined(separator: " ") + "}"
        }
    }

    private var quoted: String {
        if case .string(let s) = self, s.contains(" ") { return "\"\(s)\"" }
        return compact
    }

    /// The readable part of a log message: plain text as is, a JSON log's `msg`/`message`
    /// (followed by its other fields), and grouped multi-line messages joined.
    var logText: String {
        switch self {
        case .string(let s):
            return s
        case .array(let parts):
            return parts.map { part -> String in
                if case .object(let o) = part, let m = o.first(where: { $0.0 == "m" })?.1 { return m.logText }
                return part.logText
            }.joined(separator: " ⏎ ")
        case .object(let fields):
            let messageKeys = ["msg", "message", "MESSAGE", "Message", "log"]
            let levelKeys: Set<String> = ["level", "lvl", "severity", "LEVEL", "time", "ts", "timestamp", "@timestamp", "t"]
            if let (key, msg) = fields.first(where: { messageKeys.contains($0.0) }) {
                let rest = fields.filter { $0.0 != key && !levelKeys.contains($0.0) }
                    .map { "\($0.0)=\($0.1.quoted)" }
                return ([msg.logText] + rest).joined(separator: " ")
            }
            return fields.filter { !levelKeys.contains($0.0) }.map { "\($0.0)=\($0.1.quoted)" }.joined(separator: " ")
        default:
            return compact
        }
    }
}

public enum LogText {
    public static let maxLength = 300

    /// One display line: ANSI colors and other terminal control sequences removed, tabs and
    /// newlines turned into spaces, other control characters dropped, and cut to `maxLength`.
    public static func clean(_ raw: String, maxLength: Int = maxLength) -> String {
        var out = String.UnicodeScalarView()
        var it = raw.unicodeScalars.makeIterator()
        var count = 0
        var lastWasSpace = false
        while let c = it.next() {
            if c == "\u{1B}" {
                // CSI: ESC [ params… final(0x40–0x7E). OSC: ESC ] … BEL or ESC \. Others: ESC + one char.
                guard let next = it.next() else { break }
                if next == "[" {
                    while let p = it.next(), !(0x40...0x7E).contains(p.value) {}
                } else if next == "]" {
                    while let p = it.next(), p != "\u{07}", p != "\u{1B}" {}
                }
                continue
            }
            var s = c
            if c == "\t" || c == "\n" || c == "\r" { s = " " }
            else if c.value < 0x20 || (0x7F...0x9F).contains(c.value) { continue }
            if s == " " {
                if lastWasSpace { continue }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }
            out.append(s)
            count += 1
            if count >= maxLength {
                out.append("…")
                break
            }
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }
}

extension DzLogEvent {
    static let decoder = JSONDecoder()

    static func parse(_ data: String) -> DzLogEvent? {
        try? decoder.decode(DzLogEvent.self, from: Data(data.utf8))
    }

    var time: Date? { ts.map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) } }
    var text: String { LogText.clean(m?.logText ?? "") }
}

extension DeskConfig {
    /// `/api/hosts/{id}/logs/stream`: every running container on one host, plus containers that
    /// start later. `since` must be set, or Dozzle replays each container's whole history; the
    /// level list must be set too, or Dozzle treats the request as a filter that matches nothing.
    public func hostLogsURL(host: String, since: Date, level: LogLevel) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        let id = host.addingPercentEncoding(withAllowedCharacters: allowed) ?? host
        var parts = URLComponents(string: baseURL.absoluteString + "/api/hosts/\(id)/logs/stream")!
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        parts.queryItems = [URLQueryItem(name: "stdout", value: "1"), URLQueryItem(name: "stderr", value: "1"),
                            URLQueryItem(name: "since", value: f.string(from: since))]
            + level.dozzleLevels.map { URLQueryItem(name: "levels", value: $0) }
        // "+" in a time zone offset would read as a space; the formatter writes "Z", but be safe.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }
}
