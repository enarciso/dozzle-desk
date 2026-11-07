import Foundation
import Testing
@testable import DozzleCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

@Suite struct LinkStateMachineTests {
    func liveMachine(grace: TimeInterval = 120) -> LinkStateMachine {
        var m = LinkStateMachine(policy: LinkPolicy(grace: grace, stallTimeout: 25, jitter: 0...0))
        m.attemptStarted(now: t0)
        m.becameLive(now: t0)
        return m
    }

    @Test func backoffScheduleThenCap() {
        var m = liveMachine(grace: 1000)
        var delays: [TimeInterval] = []
        var now: TimeInterval = 10
        for _ in 0..<7 {
            guard case .retry(let d) = m.attemptFailed(now: at(now), auth: false) else {
                Issue.record("expected retry"); return
            }
            delays.append(d)
            now += d
        }
        #expect(delays == [3, 6, 12, 24, 30, 30, 30])
        #expect(m.attempt == 7)
    }

    @Test func serverRetryIsAFloor() {
        var m = liveMachine()
        m.policy.serverRetryFloor = 5
        #expect(m.attemptFailed(now: at(1), auth: false) == .retry(after: 5))
    }

    @Test func graceExpiresAtTwoMinutesAndDelaysAreClamped() {
        var m = liveMachine(grace: 120)
        #expect(m.attemptFailed(now: at(0), auth: false) == .retry(after: 3))
        #expect(m.graceRemaining(now: at(30)) == 90)
        // 110 s into the outage the backoff (6) is clamped to the 10 s left.
        #expect(m.attemptFailed(now: at(110), auth: false) == .retry(after: 6))
        #expect(m.attemptFailed(now: at(118), auth: false) == .retry(after: 2))
        #expect(m.checkGrace(now: at(119.9)) == nil)
        #expect(m.checkGrace(now: at(120)) == .graceExpired)
        #expect(m.phase == .exited(.graceExpired))
        // Once exited, it stays exited.
        #expect(m.attemptFailed(now: at(121), auth: false) == .exit(.graceExpired))
    }

    @Test func failureAfterGraceExitsImmediately() {
        var m = liveMachine(grace: 120)
        _ = m.attemptFailed(now: at(0), auth: false)
        #expect(m.attemptFailed(now: at(125), auth: false) == .exit(.graceExpired))
    }

    @Test func reconnectResetsTheGraceWindow() {
        var m = liveMachine(grace: 120)
        _ = m.attemptFailed(now: at(0), auth: false)
        _ = m.attemptFailed(now: at(100), auth: false)
        m.becameLive(now: at(105))
        #expect(m.phase == .live)
        #expect(m.graceRemaining(now: at(110)) == nil)
        #expect(m.attemptFailed(now: at(200), auth: false) == .retry(after: 3)) // attempt #1 again
        #expect(m.phase == .lost(since: at(200), attempt: 1))
    }

    @Test func authFailureExitsWithoutRetrying() {
        var m = liveMachine()
        #expect(m.attemptFailed(now: at(1), auth: true) == .exit(.authRequired))
    }

    @Test func stallDetection() {
        var m = liveMachine()
        m.activity(now: at(10))
        #expect(!m.isStalled(now: at(34)))
        #expect(m.isStalled(now: at(35)))
        #expect(m.lastLive == at(10))
    }

    @Test func sleepPausesGraceAndWakeStartsFresh() {
        var m = liveMachine(grace: 120)
        _ = m.attemptFailed(now: at(0), auth: false)
        m.willSleep()
        #expect(m.phase == .sleeping)
        #expect(m.checkGrace(now: at(10_000)) == nil) // lid closed overnight: no exit
        m.didWake(now: at(10_000))
        #expect(m.phase == .connecting)
        #expect(m.attemptFailed(now: at(10_001), auth: false) == .retry(after: 3))
        #expect(m.graceRemaining(now: at(10_001)) == 120)
    }

    @Test func preflightFailure() {
        var m = LinkStateMachine()
        #expect(m.preflightFailed(auth: false) == .unreachableAtLaunch)
        #expect(m.isExited)
        var m2 = LinkStateMachine()
        #expect(m2.preflightFailed(auth: true) == .authRequired)
    }

    private func fresh() -> UserDefaults { UserDefaults(suiteName: "dozzledesk-tests-\(UUID())")! }

    @Test func configParsing() {
        let c = DeskConfig.load(arguments: ["x", "--url", "dozzle.lan:8080/", "--grace", "2"], defaults: fresh())
        #expect(c?.baseURL.absoluteString == "http://dozzle.lan:8080")
        #expect(c?.grace == 5) // clamped minimum
        #expect(c?.streamURL.absoluteString == "http://dozzle.lan:8080/api/events/stream")
        #expect(c?.displayHost == "dozzle.lan:8080")
        #expect(DeskConfig.load(arguments: ["x", "--no-card", "--url", "h"], defaults: fresh())?.showCard == false)
        #expect(DeskConfig.load(arguments: ["x", "--card", "--url", "h"], defaults: fresh())?.showCard == true)
        #expect(DeskConfig.load(arguments: ["x", "--url", "h"], defaults: fresh())?.showCard == nil)
    }

    @Test func noBuiltInServer() {
        // Nothing configured: the app must ask rather than guess an address.
        #expect(DeskConfig.load(arguments: ["x"], defaults: fresh()) == nil)
        #expect(DeskConfig.load(arguments: ["x", "--url", "not a url"], defaults: fresh()) == nil)
    }

    @Test func savedURLAndFlagPrecedence() {
        let d = fresh()
        d.set("https://nas.lan/dozzle/", forKey: DeskConfig.urlKey)
        let saved = DeskConfig.load(arguments: ["x"], defaults: d)
        #expect(saved?.baseURL.absoluteString == "https://nas.lan/dozzle")
        #expect(saved?.healthURL.absoluteString == "https://nas.lan/dozzle/healthcheck")
        #expect(saved?.containerPage("abc").absoluteString == "https://nas.lan/dozzle/container/abc")
        #expect(saved?.displayHost == "nas.lan/dozzle")
        #expect(saved?.grace == 120)
        #expect(saved?.stallTimeout == 25)
        // --url wins for this launch only.
        #expect(DeskConfig.load(arguments: ["x", "--url", "10.0.0.9:9999"], defaults: d)?.displayHost == "10.0.0.9:9999")
        #expect(DeskConfig.requestedURL(arguments: ["x"], defaults: d) == "https://nas.lan/dozzle/")
    }

    @Test func normalizeWhatPeopleType() {
        #expect(DeskConfig.normalize("  192.168.1.20:8080  ")?.absoluteString == "http://192.168.1.20:8080")
        #expect(DeskConfig.normalize("HTTPS://Dozzle.example.com//")?.absoluteString == "HTTPS://Dozzle.example.com")
        #expect(DeskConfig.normalize("http://[::1]:8080")?.absoluteString == "http://[::1]:8080")
        #expect(DeskConfig.normalize("") == nil)
        #expect(DeskConfig.normalize("ftp://host") == nil)
        #expect(DeskConfig.normalize("http://") == nil)
        #expect(DeskConfig.normalize("http://host:8080/?x=1") == nil)
        #expect(DeskConfig.normalize("http://user:pw@host") == nil)
        #expect(DeskConfig.normalize("my server") == nil)
    }
}
