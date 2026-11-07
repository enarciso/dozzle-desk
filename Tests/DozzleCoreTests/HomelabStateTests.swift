import Foundation
import Testing
@testable import DozzleCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func ev(_ name: String, _ json: String) -> SSEEvent { SSEEvent(event: name, data: json) }

private let indexHTML = """
<html><head><script type="application/json" id="config__json">
{"authProvider":"none","version":"v11.4.1","hosts":[
 {"name":"narciso-linux","id":"H1","nCPU":8,"memTotal":16000000000,"type":"local","available":true},
 {"name":"bastion","id":"H2","nCPU":2,"memTotal":2000000000,"type":"agent","available":false}]}
</script></head></html>
"""

private let containersJSON = """
[{"id":"aaaaaaaaaaaa","name":"web","state":"running","health":"healthy","host":"H1",
  "startedAt":"2026-11-06T21:38:21.395328394Z",
  "stats":{"cpu":[1,2,40],"memory":[5,6,7],"memoryUsage":[1000,500,-200]}},
 {"id":"bbbbbbbbbbbb","name":"db","state":"running","health":"unhealthy","host":"H1","stats":{"cpu":[8]}},
 {"id":"cccccccccccc","name":"migrate","state":"exited","host":"H2","startedAt":"0001-01-01T00:00:00Z"},
 {"id":"dddddddddddd","name":"cache","state":"running","host":"H2"}]
"""

@Suite struct HomelabStateTests {
    func seeded() -> HomelabState {
        var s = HomelabState()
        s.setInventory(DzIndexConfig.parse(html: indexHTML)!)
        let ok1 = s.apply(ev("containers-changed", containersJSON), now: t0)
        #expect(ok1)
        return s
    }

    @Test func parsesIndexConfig() {
        let cfg = DzIndexConfig.parse(html: indexHTML)
        #expect(cfg?.version == "v11.4.1")
        #expect(cfg?.hosts.map(\.name) == ["narciso-linux", "bastion"])
        #expect(DzIndexConfig.parse(html: "<html></html>") == nil)
    }

    @Test func seedsFromContainerListIncludingDeltaEncodedMemory() {
        let s = seeded()
        let web = s.containers["aaaaaaaaaaaa"]!
        #expect(web.cpu == 40)
        #expect(web.memPct == 7)
        #expect(web.memUsage == 1300) // 1000 + 500 - 200
        #expect(web.startedAt != nil)
        #expect(s.containers["cccccccccccc"]?.startedAt == nil) // Go zero time
        #expect(s.hasContainerList)
    }

    @Test func liveStatsUpdateAndHostCPU() {
        var s = seeded()
        s.apply(ev("container-stat", #"{"id":"aaaaaaaaaaaa","cpu":12.5,"memory":9,"memoryUsage":4096}"#), now: t0)
        #expect(s.containers["aaaaaaaaaaaa"]?.cpu == 12.5)
        #expect(s.containers["aaaaaaaaaaaa"]?.memUsage == 4096)
        // (12.5 + 8) / 8 cores
        #expect(s.hostCPUPercent("H1") == 20.5 / 8)
        // Unknown container stats are ignored, not an error.
        let ok2 = s.apply(ev("container-stat", #"{"id":"zzzzzzzzzzzz","cpu":1}"#), now: t0)
        #expect(ok2)
    }

    @Test func snapshotCountsAndProblems() {
        let snap = seeded().snapshot(now: t0)
        #expect(snap.counts.total == 4)
        #expect(snap.counts.running == 3)
        #expect(snap.counts.healthy == 1)
        #expect(snap.counts.unhealthy == 1)
        #expect(snap.counts.exited == 1)
        // Critical first: bastion unreachable + db unhealthy. A one-off exited job is not a problem.
        #expect(snap.problems.map(\.id).sorted() == ["host-H2", "unhealthy-bbbbbbbbbbbb"])
        #expect(snap.problems.allSatisfy { $0.severity == .critical })
        #expect(snap.hosts.map(\.name) == ["bastion", "narciso-linux"])
        #expect(snap.topCPU.first?.name == "web")
        #expect(snap.topMemory.first?.name == "web")
    }

    @Test func healthAndLifecycleEvents() {
        var s = seeded()
        s.apply(ev("container-health", #"{"actorId":"bbbbbbbbbbbb","health":"healthy"}"#), now: t0)
        #expect(s.containers["bbbbbbbbbbbb"]?.health == "healthy")

        // Full 64-char actor IDs map onto 12-char keys.
        let full = "aaaaaaaaaaaa" + String(repeating: "f", count: 52)
        s.apply(ev("container-event", #"{"name":"die","actorId":"\#(full)","host":"H1"}"#), now: t0)
        #expect(s.containers["aaaaaaaaaaaa"]?.state == "exited")
        var snap = s.snapshot(now: t0.addingTimeInterval(30))
        #expect(snap.problems.contains { $0.id == "exited-aaaaaaaaaaaa" && $0.severity == .warning })

        s.apply(ev("container-event", #"{"name":"start","actorId":"\#(full)","host":"H1"}"#), now: t0.addingTimeInterval(5))
        snap = s.snapshot(now: t0.addingTimeInterval(30))
        #expect(snap.problems.contains { $0.id == "restarted-aaaaaaaaaaaa" })

        // Restart warnings age out of the 10-minute window.
        s.apply(ev("ping", "{}"), now: t0.addingTimeInterval(700))
        snap = s.snapshot(now: t0.addingTimeInterval(700))
        #expect(!snap.problems.contains { $0.id == "restarted-aaaaaaaaaaaa" })

        s.apply(ev("container-event", #"{"name":"destroy","actorId":"dddddddddddd"}"#), now: t0)
        #expect(s.containers["dddddddddddd"] == nil)
    }

    @Test func hostUpdatesMetricsAndRemoval() {
        var s = seeded()
        s.apply(ev("host-metrics", #"{"id":"H1","metricsAvailable":true,"load1":1.5,"diskFree":42}"#), now: t0)
        #expect(s.hosts["H1"]?.load1 == 1.5)
        #expect(s.hosts["H1"]?.diskFree == 42)

        s.apply(ev("update-host", #"{"id":"H2","name":"bastion","available":true}"#), now: t0)
        #expect(s.hosts["H2"]?.available == true)

        // An agent restart gets a new ID; containers follow it.
        s.apply(ev("update-host", #"{"id":"H3","name":"bastion","replacesId":"H2","available":true}"#), now: t0)
        #expect(s.hosts["H2"] == nil)
        #expect(s.containers["dddddddddddd"]?.hostId == "H3")

        s.apply(ev("update-host", #"{"id":"H3","name":"bastion","removed":true}"#), now: t0)
        #expect(s.hosts["H3"] == nil)
    }

    @Test func historyIsSampledAndBounded() {
        var s = HomelabState(historyCapacity: 3, historyInterval: 5)
        s.setInventory(DzIndexConfig.parse(html: indexHTML)!)
        s.apply(ev("containers-changed", containersJSON), now: t0)
        for i in 0..<20 { s.sampleHistory(now: t0.addingTimeInterval(Double(i))) } // 0,5,10,15 → 4 samples
        #expect(s.hosts["H1"]?.cpuHistory.values.count == 3)
    }

    @Test func undecodableAndUnknownEventsAreRejectedSafely() {
        var s = seeded()
        let ok3 = s.apply(ev("containers-changed", "not json"), now: t0)
        #expect(!ok3)
        #expect(s.containers.count == 4) // previous snapshot kept
        let ok4 = s.apply(ev("brand-new-event", "{}"), now: t0)
        #expect(!ok4)
    }

    @Test func goNanosecondDates() {
        let d = DozzleDate.parse("2026-11-06T21:38:21.395328394Z")
        #expect(d != nil)
        #expect(abs(d!.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) - 0.395) < 0.001)
        #expect(DozzleDate.parse("2026-11-06T21:38:21Z") != nil)
        #expect(DozzleDate.parse("0001-01-01T00:00:00Z") == nil)
    }
}
