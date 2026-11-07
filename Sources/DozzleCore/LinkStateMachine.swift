import Foundation

public enum ExitReason: String, Sendable, Equatable {
    case unreachableAtLaunch, graceExpired, authRequired, userQuit
}

public struct LinkPolicy: Sendable, Equatable {
    /// How long to keep retrying after the connection is lost before exiting.
    public var grace: TimeInterval
    /// No bytes for this long ⇒ the socket is dead or half-open (Dozzle pings every 20 s).
    public var stallTimeout: TimeInterval
    public var backoff: [TimeInterval]
    public var jitter: ClosedRange<Double>
    /// The server's `retry:` hint, used as a minimum delay.
    public var serverRetryFloor: TimeInterval

    public init(grace: TimeInterval = 120, stallTimeout: TimeInterval = 25,
                backoff: [TimeInterval] = [3, 6, 12, 24, 30],
                jitter: ClosedRange<Double> = 0...0.5, serverRetryFloor: TimeInterval = 0) {
        self.grace = grace
        self.stallTimeout = stallTimeout
        self.backoff = backoff.isEmpty ? [3] : backoff
        self.jitter = jitter
        self.serverRetryFloor = serverRetryFloor
    }
}

public enum LinkPhase: Sendable, Equatable {
    case preflight
    case connecting
    case live
    case lost(since: Date, attempt: Int)
    case sleeping
    case exited(ExitReason)

    public var isLive: Bool { self == .live }
}

public enum LinkDecision: Sendable, Equatable {
    case retry(after: TimeInterval)
    case exit(ExitReason)
}

/// All connection timing decisions, as a pure value type driven by explicit `now` values,
/// so backoff, stall detection and grace expiry are unit-testable without real clocks.
public struct LinkStateMachine: Sendable {
    public var policy: LinkPolicy
    public private(set) var phase: LinkPhase = .preflight
    public private(set) var lastActivity: Date?
    /// Last moment live data was flowing (for "stale since …").
    public private(set) var lastLive: Date?

    public init(policy: LinkPolicy = LinkPolicy()) { self.policy = policy }

    public var isExited: Bool { if case .exited = phase { return true } else { return false } }

    public var attempt: Int { if case .lost(_, let a) = phase { return a } else { return 0 } }

    public mutating func preflightFailed(auth: Bool) -> ExitReason {
        let r: ExitReason = auth ? .authRequired : .unreachableAtLaunch
        phase = .exited(r)
        return r
    }

    public mutating func attemptStarted(now: Date) {
        switch phase {
        case .preflight, .sleeping: phase = .connecting
        default: break
        }
        lastActivity = now
    }

    public mutating func activity(now: Date) {
        lastActivity = now
        if phase == .live { lastLive = now }
    }

    public mutating func becameLive(now: Date) {
        guard !isExited else { return }
        phase = .live
        lastActivity = now
        lastLive = now
    }

    public func isStalled(now: Date) -> Bool {
        guard let a = lastActivity else { return false }
        return now.timeIntervalSince(a) >= policy.stallTimeout
    }

    /// Called whenever a connection attempt or an established stream ends for any reason
    /// other than a deliberate disconnect (sleep, user reconnect).
    public mutating func attemptFailed(now: Date, auth: Bool, random: Double = 0) -> LinkDecision {
        if case .exited(let r) = phase { return .exit(r) }
        if auth {
            phase = .exited(.authRequired)
            return .exit(.authRequired)
        }
        let since: Date
        let attempt: Int
        if case .lost(let s, let a) = phase {
            since = s
            attempt = a + 1
        } else {
            since = now
            attempt = 1
        }
        let elapsed = now.timeIntervalSince(since)
        if elapsed >= policy.grace {
            phase = .exited(.graceExpired)
            return .exit(.graceExpired)
        }
        phase = .lost(since: since, attempt: attempt)
        let base = policy.backoff[min(attempt - 1, policy.backoff.count - 1)]
        let delay = max(base, policy.serverRetryFloor) + max(0, random)
        return .retry(after: min(delay, policy.grace - elapsed))
    }

    public mutating func checkGrace(now: Date) -> ExitReason? {
        if case .lost(let s, _) = phase, now.timeIntervalSince(s) >= policy.grace {
            phase = .exited(.graceExpired)
            return .graceExpired
        }
        return nil
    }

    public func graceRemaining(now: Date) -> TimeInterval? {
        if case .lost(let s, _) = phase { return max(0, policy.grace - now.timeIntervalSince(s)) }
        return nil
    }

    /// Deliberate disconnect: pauses the grace clock entirely.
    public mutating func willSleep() {
        guard !isExited else { return }
        phase = .sleeping
    }

    /// After wake, start over with a fresh grace window.
    public mutating func didWake(now: Date) {
        guard phase == .sleeping else { return }
        phase = .connecting
        lastActivity = now
    }

    public mutating func exit(_ r: ExitReason) { phase = .exited(r) }
}
