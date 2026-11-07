import Foundation
import Network
import os

/// What the UI needs to render, published at most once per second (plus on phase changes).
public struct LinkStatus: Sendable, Equatable {
    public var phase: LinkPhase
    public var snapshot: DashboardSnapshot?
    public var staleSince: Date?
    public var graceRemaining: TimeInterval?
    public var nextRetryIn: TimeInterval?
    public var networkAvailable: Bool
    public var endpoint: String

    public static func initial(endpoint: String) -> LinkStatus {
        LinkStatus(phase: .preflight, snapshot: nil, staleSince: nil, graceRemaining: nil,
                   nextRetryIn: nil, networkAvailable: true, endpoint: endpoint)
    }
}

enum LinkError: Error {
    case auth
    case http(Int)
    case unreachable(String)
    case stalled
    case ended
}

/// Owns the single connection to Dozzle: preflight, inventory fetch, SSE stream, watchdog,
/// reconnect/backoff, grace expiry, sleep/wake and network-path handling.
///
/// Read-only: it only ever issues GET requests.
public actor DozzleLink {
    private let config: DeskConfig
    private let session: URLSession
    private let log = Logger(subsystem: "com.narciso.dozzledesk", category: "link")
    private let onStatus: @Sendable (LinkStatus) -> Void
    private let onExit: @Sendable (ExitReason) -> Void

    private var machine: LinkStateMachine
    private var state = HomelabState()
    private var snapshot: DashboardSnapshot?
    private var dirty = false

    private var loopTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var attemptTask: Task<Void, Error>?
    private var nextAttemptAt: Date?
    private var interrupt = false
    private var deliberateDisconnect = false
    private var sleeping = false
    private var pathOK = true
    private var finished = false
    private var stopped = false
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.narciso.dozzledesk.path")

    public init(config: DeskConfig,
                onStatus: @escaping @Sendable (LinkStatus) -> Void,
                onExit: @escaping @Sendable (ExitReason) -> Void) {
        self.config = config
        self.onStatus = onStatus
        self.onExit = onExit
        self.machine = LinkStateMachine(policy: LinkPolicy(grace: config.grace, stallTimeout: config.stallTimeout))

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15          // idle timeout between packets
        cfg.timeoutIntervalForResource = 60 * 60 * 24 * 30
        cfg.waitsForConnectivity = false            // fail fast; we own the retry policy
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.httpAdditionalHeaders = ["User-Agent": "DozzleDesk/0.1"]
        self.session = URLSession(configuration: cfg)
    }

    // MARK: Lifecycle

    public func start() {
        guard loopTask == nil, !stopped else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            Task { await self?.pathChanged(ok) }
        }
        monitor.start(queue: monitorQueue)
        loopTask = Task { await self.run() }
        tickTask = Task { await self.tickLoop() }
    }

    /// Full teardown: cancels every task, closes sockets, stops the path monitor. Idempotent.
    public func stop() async {
        guard !stopped else { return }
        stopped = true
        finished = true
        attemptTask?.cancel()
        loopTask?.cancel()
        tickTask?.cancel()
        monitor.cancel()
        session.invalidateAndCancel()
        _ = await loopTask?.value
        _ = await tickTask?.value
        log.info("link stopped")
    }

    public func sleep() {
        guard !finished else { return }
        log.info("system sleeping: disconnecting deliberately")
        sleeping = true
        machine.willSleep()
        attemptTask?.cancel()
        publish()
    }

    public func wake() {
        guard !finished, sleeping else { return }
        log.info("system woke: reconnecting with a fresh grace window")
        sleeping = false
        machine.didWake(now: Date())
        nextAttemptAt = nil
        interrupt = true
        publish()
    }

    public func reconnectNow() {
        guard !finished, !sleeping else { return }
        if machine.phase.isLive {
            deliberateDisconnect = true
            attemptTask?.cancel()
        }
        nextAttemptAt = nil
        interrupt = true
    }

    private func pathChanged(_ ok: Bool) {
        guard ok != pathOK else { return }
        pathOK = ok
        log.info("network path \(ok ? "available" : "unavailable", privacy: .public)")
        if ok { interrupt = true }
        publish()
    }

    private func finish(_ reason: ExitReason) {
        guard !finished else { return }
        finished = true
        machine.exit(reason)
        attemptTask?.cancel()
        log.notice("exiting: \(reason.rawValue, privacy: .public)")
        publish()
        onExit(reason)
    }

    // MARK: Main loop

    private func run() async {
        publish()
        switch await probe(timeout: 5) {
        case .ok: break
        case .auth: finish(machine.preflightFailed(auth: true)); return
        case .failed(let why):
            log.error("preflight failed: \(why, privacy: .public)")
            finish(machine.preflightFailed(auth: false))
            return
        }

        while !Task.isCancelled && !finished {
            // Wait for the retry delay, but never while asleep or offline.
            while !finished {
                if Task.isCancelled { return }
                if sleeping || !pathOK {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                if interrupt { break }
                if let at = nextAttemptAt, Date() < at {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                break
            }
            if finished || Task.isCancelled { return }
            interrupt = false
            nextAttemptAt = nil
            deliberateDisconnect = false

            machine.attemptStarted(now: Date())
            publish()
            let task = Task { try await self.attempt() }
            attemptTask = task
            let result = await task.result
            attemptTask = nil
            if finished || Task.isCancelled { return }
            if sleeping { continue }
            if deliberateDisconnect {
                deliberateDisconnect = false
                continue
            }

            var isAuth = false
            if case .failure(let error) = result {
                isAuth = (error as? LinkError).map { if case .auth = $0 { return true } else { return false } } ?? false
                log.warning("connection ended: \(String(describing: error), privacy: .public)")
            }
            switch machine.attemptFailed(now: Date(), auth: isAuth, random: Double.random(in: machine.policy.jitter)) {
            case .exit(let reason):
                finish(reason)
                return
            case .retry(let delay):
                nextAttemptAt = Date().addingTimeInterval(delay)
                log.info("retry #\(self.machine.attempt) in \(delay, format: .fixed(precision: 1))s")
            }
            publish()
        }
    }

    private func tickLoop() async {
        while !Task.isCancelled && !finished {
            try? await Task.sleep(for: .seconds(1))
            if finished || Task.isCancelled { return }
            let now = Date()
            if let reason = machine.checkGrace(now: now) {
                finish(reason)
                return
            }
            state.sampleHistory(now: now)
            publish()
        }
    }

    // MARK: One connection attempt

    private enum ProbeResult { case ok, auth, failed(String) }

    private func probe(timeout: TimeInterval) async -> ProbeResult {
        var req = URLRequest(url: config.healthURL)
        req.timeoutInterval = timeout
        do {
            let (_, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: return .ok
            case 401, 403: return .auth
            default: return .failed("healthcheck HTTP \(code)")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func attempt() async throws {
        if case .lost = machine.phase {
            switch await probe(timeout: 5) {
            case .ok: break
            case .auth: throw LinkError.auth
            case .failed(let why): throw LinkError.unreachable(why)
            }
        }
        try Task.checkCancellation()

        // Host inventory lives in the index page's embedded config.
        var indexReq = URLRequest(url: config.indexURL)
        indexReq.timeoutInterval = 10
        let (html, indexResp) = try await session.data(for: indexReq)
        let indexCode = (indexResp as? HTTPURLResponse)?.statusCode ?? 0
        if indexCode == 401 || indexCode == 403 { throw LinkError.auth }
        guard indexCode == 200 else { throw LinkError.http(indexCode) }
        if let cfg = DzIndexConfig.parse(html: String(decoding: html, as: UTF8.self)) {
            state.setInventory(cfg)
            dirty = true
        }
        try Task.checkCancellation()

        var req = URLRequest(url: config.streamURL)
        req.timeoutInterval = 15
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (bytes, resp) = try await session.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 {
            bytes.task.cancel()
            throw LinkError.auth
        }
        guard code == 200 else {
            bytes.task.cancel()
            throw LinkError.http(code)
        }
        machine.activity(now: Date())
        let dataTask = bytes.task

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.consume(bytes) }
            group.addTask { try await self.watchdog(dataTask) }
            _ = try await group.next()
            group.cancelAll()
        }
        dataTask.cancel()
        throw LinkError.ended
    }

    private func consume(_ bytes: URLSession.AsyncBytes) async throws {
        var parser = SSEParser()
        var dropped = 0
        for try await byte in bytes {
            if let ev = parser.feed(byte) { handle(ev) }
            if byte == 0x0A {
                machine.activity(now: Date())
                if let ms = parser.retryMillis { machine.policy.serverRetryFloor = Double(ms) / 1000 }
                if parser.droppedLines != dropped {
                    dropped = parser.droppedLines
                    log.error("dropped an oversized SSE line (total \(dropped))")
                }
            }
        }
    }

    private func watchdog(_ task: URLSessionDataTask) async throws {
        while true {
            try await Task.sleep(for: .seconds(1))
            if machine.isStalled(now: Date()) {
                log.warning("no data for \(self.machine.policy.stallTimeout)s: treating connection as dead")
                task.cancel()
                throw LinkError.stalled
            }
        }
    }

    private func handle(_ ev: SSEEvent) {
        let now = Date()
        state.apply(ev, now: now)
        dirty = true
        if ev.event == "containers-changed", !machine.phase.isLive {
            machine.becameLive(now: now)
            log.info("live: \(self.state.containers.count) containers on \(self.state.hosts.count) hosts")
            publish()
        }
    }

    // MARK: Publishing

    private func publish() {
        let now = Date()
        if dirty, state.hasContainerList {
            snapshot = state.snapshot(now: now)
            dirty = false
        }
        let stale: Date? = machine.phase.isLive ? nil : machine.lastLive
        onStatus(LinkStatus(
            phase: machine.phase,
            snapshot: snapshot,
            staleSince: stale,
            graceRemaining: machine.graceRemaining(now: now),
            nextRetryIn: nextAttemptAt.map { max(0, $0.timeIntervalSince(now)) },
            networkAvailable: pathOK,
            endpoint: config.displayHost))
    }
}
