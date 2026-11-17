import Foundation
import Testing
@testable import DozzleCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func line(_ text: String, at offset: TimeInterval, _ severity: LogLine.Severity = .info) -> LogLine {
    LogLine(id: 0, time: t0.addingTimeInterval(offset), containerId: "c", containerName: "web",
            hostId: "H", severity: severity, stderr: false, text: text)
}

@Suite struct LogLevelTests {
    @Test func thresholdsIncludeEverythingMoreSevere() {
        #expect(LogLevel.default == .info)
        #expect(LogLevel.error.dozzleLevels == ["fatal", "error"])
        #expect(LogLevel.info.includes(.unknown))       // plain output counts as info
        #expect(!LogLevel.warn.includes(.unknown))
        #expect(!LogLevel.info.includes(.debug))
        #expect(LogLevel.trace.dozzleLevels.count == 7)  // every level Dozzle knows
        #expect(LogLine.Severity(dozzle: "WARNING") == .warn)
        #expect(LogLine.Severity(dozzle: nil) == .unknown)
    }

    @Test func streamURLAlwaysCarriesSinceAndLevels() throws {
        let config = DeskConfig(baseURL: URL(string: "https://nas.lan/dozzle")!)
        let url = config.hostLogsURL(host: "node 1", since: t0, level: .warn)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.path == "/dozzle/api/hosts/node 1/logs/stream")
        #expect(url.absoluteString.contains("/api/hosts/node%201/logs/stream"))
        let items = parts.queryItems ?? []
        #expect(items.first { $0.name == "since" }?.value == "2027-01-15T08:00:00Z")
        #expect(items.filter { $0.name == "levels" }.map(\.value) == ["fatal", "error", "warn"])
        #expect(items.contains { $0.name == "stdout" } && items.contains { $0.name == "stderr" })
    }
}

@Suite struct LogBufferTests {
    @Test func keepsLinesInTimeOrderWithoutRepeats() {
        var b = LogBuffer(capacity: 20)
        let r1 = b.add(line("b", at: 2), key: "b", now: t0)
        #expect(r1)
        let r2 = b.add(line("a", at: 1), key: "a", now: t0)
        #expect(r2)   // a late backfill line
        let r3 = b.add(line("c", at: 3), key: "c", now: t0)
        #expect(r3)
        let r4 = b.add(line("b", at: 2), key: "b", now: t0)
        #expect(!r4)  // same line after a stream restart
        #expect(b.lines.map(\.text) == ["a", "b", "c"])
        #expect(Set(b.lines.map(\.id)).count == 3)
    }

    @Test func staysBoundedAndForgetsDroppedLines() {
        var b = LogBuffer(capacity: 12)
        for i in 0..<30 { b.add(line("\(i)", at: Double(i)), key: "\(i)", now: t0) }
        #expect(b.lines.count == 12)
        #expect(b.lines.first?.text == "18")
        let r5 = b.add(line("old", at: 1), key: "old", now: t0)
        #expect(!r5)   // older than everything kept
        #expect(b.newest.count == LogBuffer.shown)
    }

    @Test func levelChangeKeepsWhatTheNewLevelShows() {
        var b = LogBuffer()
        b.add(line("e", at: 1, .error), key: "e", now: t0)
        b.add(line("i", at: 2, .info), key: "i", now: t0)
        b.add(line("u", at: 3, .unknown), key: "u", now: t0)
        b.filter(.warn)
        #expect(b.lines.map(\.text) == ["e"])
        let r6 = b.add(line("i", at: 2, .info), key: "i", now: t0)
        #expect(r6)   // may come back later
    }

    @Test func rateCountsRecentArrivals() {
        var b = LogBuffer()
        for i in 0..<20 { b.add(line("\(i)", at: Double(i)), key: "\(i)", now: t0.addingTimeInterval(Double(i))) }
        #expect(b.rate(now: t0.addingTimeInterval(19), window: 10) == 1.0)
        #expect(b.rate(now: t0.addingTimeInterval(100), window: 10) == 0)
    }
}

@Suite struct LogTextTests {
    @Test func stripsTerminalCodesAndControlCharacters() {
        #expect(LogText.clean("\u{1B}[1;32mINFO\u{1B}[0m  ready\tnow\r\n") == "INFO ready now")
        #expect(LogText.clean("\u{1B}]0;title\u{07}hi\u{00}!") == "hi!")
        #expect(LogText.clean(String(repeating: "x", count: 500)).count == LogText.maxLength + 1)
    }

    @Test func flattensDozzleMessageShapes() throws {
        let plain = try #require(DzLogEvent.parse(#"{"m":"hello","ts":1800000000123,"l":"info","s":"stdout","c":"abc"}"#))
        #expect(plain.text == "hello")
        #expect(plain.time == Date(timeIntervalSince1970: 1_800_000_000.123))
        let json = try #require(DzLogEvent.parse(#"{"m":{"level":"warn","msg":"disk low","free":"2 GB","pct":4},"ts":1,"l":"warn"}"#))
        #expect(json.text == #"disk low free="2 GB" pct=4"#)
        let group = try #require(DzLogEvent.parse(#"{"m":[{"m":"Traceback:"},{"m":"  File x"}],"l":"error"}"#))
        #expect(group.text == "Traceback: ⏎ File x")
        let noMsg = try #require(DzLogEvent.parse(#"{"m":{"a":1,"b":true}}"#))
        #expect(noMsg.text == "a=1 b=true")
    }
}
