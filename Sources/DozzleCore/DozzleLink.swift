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
    /// The logs panel's lines; nil while the panel is off.
    public var logs: LogFeed?

    public static func initial(endpoint: String) -> LinkStatus {
        LinkStatus(phase: .preflight, snapshot: nil, staleSince: nil, graceRemaining: nil,
                   nextRetryIn: nil, networkAvailable: true, endpoint: endpoint, logs: nil)
    }
}

enum LinkError: Error {
    case auth
    case certificate
    case http(Int)
    case unreachable(String)
    case stalled
    case ended
}

/// Owns the single connection to Dozzle: preflight, inventory fetch, SSE stream, watchdog,
/// reconnect/backoff, grace expiry, sleep/wake and network-path handling.
///
/// Read-only: GET requests, plus `POST /api/token` to sign in when Dozzle's own login is used.
public actor DozzleLink {
    private let config: DeskConfig
    private let client: DozzleClient
    private let log = Logger(subsystem: AppIdentity.id, category: "link")
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
    private let monitorQueue = DispatchQueue(label: AppIdentity.id + ".path")

    // Logs panel: one log stream per host, only while it's on, visible and the link is live.
    /// At most this many hosts are tailed at once (each one is a long-lived connection).
    public static let maxLogHosts = 12
    /// Seconds of recent lines fetched when a log stream (re)starts, so the panel isn't empty.
    private static let logBackfill: TimeInterval = 30
    private var logLevel: LogLevel?
    private var logsVisible = true
    private var logTasks: [String: Task<Void, Never>] = [:]
    private var logStreaming: Set<String> = []
    private var logs = LogBuffer()
    private var logsReceived = 0

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
        cfg.httpMaximumConnectionsPerHost = 2 + Self.maxLogHosts   // events + requests + log streams
        self.client = DozzleClient(config: config, configuration: cfg)
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
        if logLevel != nil { log.info("logs panel received \(self.logsReceived) lines") }
        stopLogStreams()
        client.invalidate()
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
        reconcileLogs()
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
        reconcileLogs()
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
            if client.rejectedCertificate != nil { finish(.certificateRejected); return }
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
                // A certificate that stopped matching won't fix itself by retrying.
                if case .certificate? = error as? LinkError {
                    finish(.certificateRejected)
                    return
                }
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
            reconcileLogs()
            publish()
        }
    }

    // MARK: One connection attempt

    private enum ProbeResult { case ok, auth, failed(String) }

    private func probe(timeout: TimeInterval) async -> ProbeResult {
        do {
            let (_, resp) = try await client.data(config.healthURL, timeout: timeout)
            switch resp.statusCode {
            case 200: return .ok
            case 401, 403: return .auth
            default: return .failed("healthcheck HTTP \(resp.statusCode)")
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
        let (html, indexResp) = try await authorized { try await self.client.data(self.config.indexURL, timeout: 10) }
        guard indexResp.statusCode == 200 else { throw LinkError.http(indexResp.statusCode) }
        if let cfg = DzIndexConfig.parse(html: String(decoding: html, as: UTF8.self)) {
            state.setInventory(cfg)
            dirty = true
        }
        try Task.checkCancellation()

        let (bytes, resp) = try await authorized {
            var req = self.client.request(self.config.streamURL, timeout: 15)
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (bytes, resp) = try await self.client.bytes(req)
            if resp.statusCode != 200 { bytes.task.cancel() }
            return (bytes, resp)
        }
        guard resp.statusCode == 200 else { throw LinkError.http(resp.statusCode) }
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

    /// Runs a request with Dozzle's login: signs in first if there's no session yet, and once
    /// more if the session was refused (expired or Dozzle restarted). A refusal after a fresh
    /// sign-in, or a rejected password, is final: no retry loop against a login.
    private func authorized<T>(_ send: @Sendable () async throws -> (T, HTTPURLResponse)) async throws -> (T, HTTPURLResponse) {
        func refused(_ r: HTTPURLResponse) -> Bool {
            r.statusCode == 401 || r.statusCode == 403 || DozzleProbe.isLoginPage(r)
        }
        do {
            if config.auth.usesDozzleLogin && !client.hasSession { try await signIn() }
            var result = try await send()
            if refused(result.1) && config.auth.usesDozzleLogin {
                log.info("session refused; signing in again")
                client.clearSession()
                try await signIn()
                result = try await send()
            }
            if refused(result.1) { throw LinkError.auth }
            return result
        } catch let error as URLError where client.rejectedCertificate != nil {
            log.error("certificate rejected: \(error.localizedDescription, privacy: .public)")
            throw LinkError.certificate
        }
    }

    private func signIn() async throws {
        switch try await client.login() {
        case .ok: log.info("signed in to Dozzle")
        case .rejected: throw LinkError.auth
        case .unavailable(let code): log.info("no password login here (HTTP \(code)); continuing without")
        }
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
            reconcileLogs()
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
            endpoint: config.displayHost,
            logs: logLevel.map { LogFeed(level: $0, lines: logs.newest, rate: logs.rate(now: now),
                                         streaming: logStreaming.count, hosts: logTasks.count) }))
    }

    // MARK: Logs panel

    /// Turns the logs panel on at a level threshold, or off (nil). Changing the level restarts
    /// the log streams and keeps the lines the new level still shows.
    public func setLogs(_ level: LogLevel?) {
        guard level != logLevel else { return }
        let wasOn = logLevel != nil
        logLevel = level
        stopLogStreams()
        if let level, wasOn { logs.filter(level) } else { logs.removeAll() }
        reconcileLogs()
        publish()
    }

    /// Whether anything shows the panel right now (card on, or dropdown open, and displays awake).
    /// Log streams only run while it's visible.
    public func setLogsVisible(_ visible: Bool) {
        guard visible != logsVisible else { return }
        logsVisible = visible
        reconcileLogs()
    }

    private func stopLogStreams() {
        logTasks.values.forEach { $0.cancel() }
        logTasks.removeAll()
        logStreaming.removeAll()
    }

    /// Starts or stops per-host log streams to match what should run now.
    private func reconcileLogs() {
        var want: [String] = []
        if let level = logLevel, logsVisible, machine.phase.isLive, !sleeping, !finished, !stopped {
            want = Array(state.hosts.values.filter(\.available).map(\.id).sorted().prefix(Self.maxLogHosts))
            for id in want where logTasks[id] == nil {
                logTasks[id] = Task { await self.streamLogs(host: id, level: level) }
            }
        }
        for (id, task) in logTasks where !want.contains(id) {
            task.cancel()
            logTasks[id] = nil
            logStreaming.remove(id)
        }
    }

    /// Tails one host's logs until cancelled, reconnecting with a backoff. Never signs in by
    /// itself: the main stream keeps the Dozzle session fresh, and a refused log request just
    /// waits for the next try.
    private func streamLogs(host: String, level: LogLevel) async {
        var failures = 0
        while !Task.isCancelled {
            do {
                let url = config.hostLogsURL(host: host, since: Date().addingTimeInterval(-Self.logBackfill), level: level)
                // Quiet hosts can go a while between lines; Dozzle pings, but give it room.
                var req = client.request(url, timeout: 120)
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                let (bytes, resp) = try await client.bytes(req)
                let task = bytes.task
                guard resp.statusCode == 200 else {
                    task.cancel()
                    throw LinkError.http(resp.statusCode)
                }
                logStreaming.insert(host)
                log.info("log stream for \(host, privacy: .public) connected")
                try await withTaskCancellationHandler {
                    var parser = SSEParser(maxLineBytes: 256 * 1024)
                    for try await byte in bytes {
                        guard let ev = parser.feed(byte) else { continue }
                        failures = 0
                        if ev.event == "message" { addLog(ev, host: host) }
                    }
                } onCancel: {
                    task.cancel()
                }
                throw LinkError.ended
            } catch {
                if Task.isCancelled { break }
                log.info("log stream for \(host, privacy: .public) ended: \(String(describing: error), privacy: .public)")
            }
            logStreaming.remove(host)
            failures += 1
            let delay = [2.0, 5, 10, 30][min(failures, 4) - 1]
            try? await Task.sleep(for: .seconds(delay))
        }
        logStreaming.remove(host)
    }

    private func addLog(_ ev: SSEEvent, host: String) {
        guard let level = logLevel, let e = DzLogEvent.parse(ev.data) else { return }
        let severity = LogLine.Severity(dozzle: e.l)
        // Dozzle filters by level already; this covers a stream still closing after a level change.
        guard level.includes(severity) else { return }
        let text = e.text
        guard !text.isEmpty else { return }
        let raw = e.c ?? ""
        let key = HomelabState.key(raw)
        let container = state.containers[key]
        let line = LogLine(id: 0, time: e.time ?? Date(), containerId: key,
                           containerName: container?.name ?? String(raw.prefix(12)),
                           hostId: container?.hostId ?? host, severity: severity,
                           stderr: e.s == "stderr", text: text)
        logsReceived += 1
        logs.add(line, key: "\(raw)|\(e.ts ?? 0)|\(e.id ?? 0)|\(text)", now: Date())
    }
}
