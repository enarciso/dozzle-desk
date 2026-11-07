import Foundation

/// One dispatched Server-Sent Event.
public struct SSEEvent: Sendable, Equatable {
    public var event: String
    public var data: String
    public var id: String?

    public init(event: String, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Incremental, byte-at-a-time SSE parser (WHATWG event-stream format).
///
/// `URLSession.AsyncBytes.lines` collapses blank lines, which SSE needs for dispatch,
/// so the stream is parsed at the byte level. Memory is bounded: any single line longer
/// than `maxLineBytes` is discarded (and the event it belongs to is skipped).
public struct SSEParser: Sendable {
    public let maxLineBytes: Int
    /// Last `retry:` value sent by the server, in milliseconds.
    public private(set) var retryMillis: Int?
    /// Number of lines discarded for exceeding `maxLineBytes`.
    public private(set) var droppedLines = 0
    public private(set) var lastEventId: String?

    private var line: [UInt8] = []
    private var overflow = false
    private var eventName = ""
    private var dataLines: [String] = []
    private var eventCorrupt = false

    /// Dozzle's largest line (the initial `containers-changed` list) is ~400 KB for ~50
    /// containers; 8 MB leaves ample headroom while still bounding memory.
    public init(maxLineBytes: Int = 8 * 1024 * 1024) {
        self.maxLineBytes = maxLineBytes
        line.reserveCapacity(4096)
    }

    /// Feeds one byte. Returns an event when a blank line completes one.
    public mutating func feed(_ byte: UInt8) -> SSEEvent? {
        if byte == 0x0A { return endLine() }
        if overflow { return nil }
        if line.count >= maxLineBytes {
            overflow = true
            line.removeAll(keepingCapacity: false)
            return nil
        }
        line.append(byte)
        return nil
    }

    public mutating func feed<S: Sequence>(_ bytes: S) -> [SSEEvent] where S.Element == UInt8 {
        var out: [SSEEvent] = []
        for b in bytes {
            if let e = feed(b) { out.append(e) }
        }
        return out
    }

    private mutating func endLine() -> SSEEvent? {
        if overflow {
            overflow = false
            droppedLines += 1
            eventCorrupt = true
            return nil
        }
        if line.last == 0x0D { line.removeLast() }
        defer { line.removeAll(keepingCapacity: line.count <= 1 << 20) }

        if line.isEmpty { return dispatch() }
        if line.first == 0x3A { return nil } // ":" comment

        let text = String(decoding: line, as: UTF8.self)
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        case "id": if !value.contains("\0") { lastEventId = String(value) }
        case "retry": if let ms = Int(value), ms >= 0 { retryMillis = ms }
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventName = ""
            dataLines.removeAll()
            eventCorrupt = false
        }
        if eventCorrupt || dataLines.isEmpty { return nil }
        return SSEEvent(
            event: eventName.isEmpty ? "message" : eventName,
            data: dataLines.joined(separator: "\n"),
            id: lastEventId
        )
    }
}
