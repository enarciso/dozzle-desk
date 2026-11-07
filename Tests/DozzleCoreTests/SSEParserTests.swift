import Foundation
import Testing
@testable import DozzleCore

@Suite struct SSEParserTests {
    @Test func parsesNamedEventsAndRetry() {
        var p = SSEParser()
        let events = p.feed(Array("retry: 3000\n\nevent: server-version\ndata: {\"version\":\"v11.4.1\"}\n\n".utf8))
        #expect(events == [SSEEvent(event: "server-version", data: "{\"version\":\"v11.4.1\"}")])
        #expect(p.retryMillis == 3000)
    }

    @Test func handlesChunksSplitAnywhere() {
        let raw = Array("event: ping\ndata: {}\n\nevent: container-stat\ndata: {\"id\":\"a\"}\n\n".utf8)
        var p = SSEParser()
        var out: [SSEEvent] = []
        for chunk in stride(from: 0, to: raw.count, by: 3) {
            out += p.feed(raw[chunk..<min(chunk + 3, raw.count)])
        }
        #expect(out.map(\.event) == ["ping", "container-stat"])
        #expect(out[1].data == "{\"id\":\"a\"}")
    }

    @Test func joinsMultiLineDataAndHandlesCRLF() {
        var p = SSEParser()
        let out = p.feed(Array("event: x\r\ndata: one\r\ndata: two\r\n\r\n".utf8))
        #expect(out == [SSEEvent(event: "x", data: "one\ntwo")])
    }

    @Test func ignoresCommentsAndDefaultsEventName() {
        var p = SSEParser()
        let out = p.feed(Array(": keepalive\n\ndata: hi\n\n".utf8))
        #expect(out == [SSEEvent(event: "message", data: "hi")])
    }

    @Test func blankLineWithoutDataDispatchesNothing() {
        var p = SSEParser()
        #expect(p.feed(Array("event: lonely\n\n\n".utf8)).isEmpty)
    }

    @Test func dropsOversizedLineAndItsEventButRecovers() {
        var p = SSEParser(maxLineBytes: 16)
        let huge = "data: " + String(repeating: "x", count: 100)
        let out = p.feed(Array("event: big\n\(huge)\n\nevent: ok\ndata: 1\n\n".utf8))
        #expect(out == [SSEEvent(event: "ok", data: "1")])
        #expect(p.droppedLines == 1)
    }
}
