import Foundation

/// Fixed-capacity history of samples (oldest first).
public struct RingBuffer: Sendable, Equatable {
    public let capacity: Int
    public private(set) var values: [Double] = []

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    public mutating func append(_ v: Double) {
        values.append(v)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
}

public struct ContainerState: Sendable, Equatable {
    public var id: String
    public var name: String
    public var image: String?
    public var state: String
    public var health: String?
    public var hostId: String
    public var startedAt: Date?
    public var cpu: Double = 0
    public var memPct: Double = 0
    public var memUsage: Double = 0
}

public struct HostState: Sendable, Equatable {
    public var id: String
    public var name: String
    public var nCPU: Int?
    public var memTotal: Double?
    public var diskTotal: Double?
    public var diskFree: Double?
    public var type: String?
    public var available: Bool
    public var load1: Double?
    public var cpuHistory: RingBuffer
}

/// Pure reducer over Dozzle's `/api/events/stream`. No I/O, no clocks: callers pass `now`.
public struct HomelabState: Sendable {
    public private(set) var version: String?
    public private(set) var hosts: [String: HostState] = [:]
    public private(set) var containers: [String: ContainerState] = [:]
    /// Recent `die` timestamps per container, pruned to `deathWindow`.
    public private(set) var deaths: [String: [Date]] = [:]
    public private(set) var hasContainerList = false

    public var historyCapacity: Int
    public var historyInterval: TimeInterval
    public var deathWindow: TimeInterval
    private var lastHistorySample: Date?

    public init(historyCapacity: Int = 60, historyInterval: TimeInterval = 5, deathWindow: TimeInterval = 600) {
        self.historyCapacity = historyCapacity
        self.historyInterval = historyInterval
        self.deathWindow = deathWindow
    }

    /// Dozzle uses 12-char short IDs in stats; Docker events may carry the full 64-char ID.
    static func key(_ id: String) -> String { String(id.prefix(12)) }

    private static let decoder = JSONDecoder()
    private func decode<T: Decodable>(_ type: T.Type, _ data: String) -> T? {
        try? Self.decoder.decode(type, from: Data(data.utf8))
    }

    // MARK: Inventory

    public mutating func setInventory(_ config: DzIndexConfig) {
        if let v = config.version { version = v }
        for h in config.hosts { upsertHost(h) }
    }

    private mutating func upsertHost(_ h: DzHost) {
        if let old = h.replacesId, old != h.id {
            let previous = hosts.removeValue(forKey: old)
            for (k, c) in containers where c.hostId == old { containers[k]?.hostId = h.id }
            if hosts[h.id] == nil, let previous { hosts[h.id] = previous }
        }
        if h.removed == true {
            hosts.removeValue(forKey: h.id)
            return
        }
        var s = hosts[h.id] ?? HostState(
            id: h.id, name: h.name, type: h.type, available: true,
            cpuHistory: RingBuffer(capacity: historyCapacity))
        s.id = h.id
        s.name = h.name
        s.nCPU = h.nCPU ?? s.nCPU
        s.memTotal = h.memTotal ?? s.memTotal
        s.diskTotal = h.diskTotal ?? s.diskTotal
        s.diskFree = h.diskFree ?? s.diskFree
        s.type = h.type ?? s.type
        s.available = h.available ?? s.available
        hosts[h.id] = s
    }

    private mutating func ensureHost(_ id: String) {
        guard !id.isEmpty, hosts[id] == nil else { return }
        hosts[id] = HostState(
            id: id, name: String(id.prefix(8)), available: true,
            cpuHistory: RingBuffer(capacity: historyCapacity))
    }

    private func makeContainer(_ c: DzContainer, previous: ContainerState?) -> ContainerState {
        var s = ContainerState(
            id: Self.key(c.id), name: c.name, image: c.image, state: c.state, health: c.health,
            hostId: c.host, startedAt: c.startedAt.flatMap(DozzleDate.parse))
        if let stats = c.stats {
            s.cpu = stats.cpu?.last ?? previous?.cpu ?? 0
            s.memPct = stats.memory?.last ?? previous?.memPct ?? 0
            s.memUsage = stats.latestMemoryUsage ?? previous?.memUsage ?? 0
        } else if let previous {
            s.cpu = previous.cpu
            s.memPct = previous.memPct
            s.memUsage = previous.memUsage
        }
        return s
    }

    // MARK: Events

    /// Applies one SSE event. Returns false for unknown or undecodable events.
    @discardableResult
    public mutating func apply(_ ev: SSEEvent, now: Date) -> Bool {
        switch ev.event {
        case "server-version":
            guard let v = decode(DzVersion.self, ev.data) else { return false }
            version = v.version

        case "containers-changed":
            guard let list = decode([DzContainer].self, ev.data) else { return false }
            var next: [String: ContainerState] = [:]
            next.reserveCapacity(list.count)
            for c in list {
                let k = Self.key(c.id)
                next[k] = makeContainer(c, previous: containers[k])
                ensureHost(c.host)
            }
            containers = next
            deaths = deaths.filter { next[$0.key] != nil }
            hasContainerList = true

        case "container-updated":
            guard let c = decode(DzContainer.self, ev.data) else { return false }
            let k = Self.key(c.id)
            containers[k] = makeContainer(c, previous: containers[k])
            ensureHost(c.host)

        case "container-stat":
            guard let s = decode(DzStat.self, ev.data) else { return false }
            let k = Self.key(s.id)
            guard containers[k] != nil else { return true }
            containers[k]?.cpu = s.cpu
            containers[k]?.memPct = s.memory
            containers[k]?.memUsage = s.memoryUsage

        case "container-health":
            guard let h = decode(DzHealthEvent.self, ev.data) else { return false }
            containers[Self.key(h.actorId)]?.health = h.health

        case "container-event":
            guard let e = decode(DzContainerEvent.self, ev.data) else { return false }
            let k = Self.key(e.actorId)
            let at = e.time ?? now
            switch e.action {
            case "die":
                containers[k]?.state = "exited"
                containers[k]?.cpu = 0
                if containers[k] != nil { deaths[k, default: []].append(at) }
            case "start":
                containers[k]?.state = "running"
                containers[k]?.startedAt = at
            case "destroy":
                containers.removeValue(forKey: k)
                deaths.removeValue(forKey: k)
            case "pause":
                containers[k]?.state = "paused"
            case "unpause":
                containers[k]?.state = "running"
            default:
                break
            }

        case "update-host":
            guard let h = decode(DzHost.self, ev.data) else { return false }
            upsertHost(h)

        case "host-metrics":
            guard let m = decode(DzHostMetrics.self, ev.data), var h = hosts[m.id] else { return true }
            if m.metricsAvailable != false { h.load1 = m.load1 ?? h.load1 }
            h.diskTotal = m.diskTotal ?? h.diskTotal
            h.diskFree = m.diskFree ?? h.diskFree
            hosts[m.id] = h

        case "ping", "auto-prune", "container-update":
            break

        default:
            return false
        }
        pruneDeaths(now: now)
        return true
    }

    private mutating func pruneDeaths(now: Date) {
        guard !deaths.isEmpty else { return }
        let cutoff = now.addingTimeInterval(-deathWindow)
        for (k, times) in deaths {
            let kept = times.filter { $0 >= cutoff }
            deaths[k] = kept.isEmpty ? nil : kept
        }
    }

    // MARK: Derived values

    /// Sum of container CPU on a host as a share of the host's total capacity (Dozzle reports
    /// container CPU where 100% = one core).
    public func hostCPUPercent(_ hostId: String) -> Double? {
        guard let host = hosts[hostId] else { return nil }
        let sum = containers.values.lazy.filter { $0.hostId == hostId && $0.state == "running" }
            .reduce(0) { $0 + $1.cpu }
        guard let n = host.nCPU, n > 0 else { return nil }
        return min(100, max(0, sum / Double(n)))
    }

    /// Appends one CPU sample per host every `historyInterval` seconds.
    public mutating func sampleHistory(now: Date) {
        if let last = lastHistorySample, now.timeIntervalSince(last) < historyInterval { return }
        guard hasContainerList else { return }
        lastHistorySample = now
        for id in hosts.keys {
            if let pct = hostCPUPercent(id) { hosts[id]?.cpuHistory.append(pct) }
        }
    }

    public func snapshot(now: Date) -> DashboardSnapshot {
        let cutoff = now.addingTimeInterval(-deathWindow)
        var counts = DashboardSnapshot.Counts()
        var problems: [DashboardSnapshot.Problem] = []
        var perHostRunning: [String: Int] = [:]
        var perHostTotal: [String: Int] = [:]
        var perHostMem: [String: Double] = [:]

        for c in containers.values {
            counts.total += 1
            perHostTotal[c.hostId, default: 0] += 1
            switch c.state {
            case "running":
                counts.running += 1
                perHostRunning[c.hostId, default: 0] += 1
                perHostMem[c.hostId, default: 0] += c.memUsage
            case "exited": counts.exited += 1
            case "paused": counts.paused += 1
            case "restarting": counts.restarting += 1
            default: break
            }
            if c.health == "healthy" { counts.healthy += 1 }
            if c.health == "unhealthy" { counts.unhealthy += 1 }

            let hostName = hosts[c.hostId]?.name ?? String(c.hostId.prefix(8))
            let recentDeaths = (deaths[c.id] ?? []).filter { $0 >= cutoff }
            if c.health == "unhealthy" {
                problems.append(.init(id: "unhealthy-\(c.id)", severity: .critical,
                                      title: "\(c.name) is unhealthy", detail: hostName,
                                      hostId: c.hostId, containerId: c.id, since: nil))
            }
            if c.state == "dead" {
                problems.append(.init(id: "dead-\(c.id)", severity: .critical,
                                      title: "\(c.name) is dead", detail: hostName,
                                      hostId: c.hostId, containerId: c.id, since: nil))
            } else if c.state == "restarting" {
                problems.append(.init(id: "restarting-\(c.id)", severity: .warning,
                                      title: "\(c.name) is restarting", detail: hostName,
                                      hostId: c.hostId, containerId: c.id, since: recentDeaths.last))
            } else if !recentDeaths.isEmpty {
                if c.state == "running" {
                    let n = recentDeaths.count
                    problems.append(.init(id: "restarted-\(c.id)", severity: .warning,
                                          title: "\(c.name) restarted \(n)× in \(Int(deathWindow / 60)) min",
                                          detail: hostName, hostId: c.hostId, containerId: c.id,
                                          since: recentDeaths.last))
                } else if c.state == "exited" {
                    problems.append(.init(id: "exited-\(c.id)", severity: .warning,
                                          title: "\(c.name) exited", detail: hostName,
                                          hostId: c.hostId, containerId: c.id, since: recentDeaths.last))
                }
            }
        }

        var hostRows: [DashboardSnapshot.Host] = []
        for h in hosts.values {
            if !h.available {
                problems.append(.init(id: "host-\(h.id)", severity: .critical,
                                      title: "\(h.name) unreachable",
                                      detail: "Dozzle can't reach this host",
                                      hostId: h.id, containerId: nil, since: nil))
            }
            hostRows.append(.init(
                id: h.id, name: h.name, available: h.available, isLocal: h.type == "local",
                nCPU: h.nCPU, cpuPercent: hostCPUPercent(h.id), cpuHistory: h.cpuHistory.values,
                load1: h.load1, memUsed: perHostMem[h.id] ?? 0, memTotal: h.memTotal,
                diskFree: h.diskFree, diskTotal: h.diskTotal,
                running: perHostRunning[h.id] ?? 0, total: perHostTotal[h.id] ?? 0))
        }
        hostRows.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        problems.sort {
            $0.severity != $1.severity ? $0.severity.rawValue > $1.severity.rawValue : $0.title < $1.title
        }

        let running = containers.values.filter { $0.state == "running" }
        func row(_ c: ContainerState) -> DashboardSnapshot.ContainerRow {
            .init(id: c.id, hostId: c.hostId, name: c.name,
                  hostName: hosts[c.hostId]?.name ?? String(c.hostId.prefix(8)),
                  cpu: c.cpu, memPercent: c.memPct, memUsage: c.memUsage)
        }
        let topCPU = running.sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.name < $1.name }.prefix(5).map(row)
        let topMem = running.sorted { $0.memUsage != $1.memUsage ? $0.memUsage > $1.memUsage : $0.name < $1.name }
            .prefix(5).map(row)

        return DashboardSnapshot(version: version, generatedAt: now, hosts: hostRows, counts: counts,
                                 problems: problems, topCPU: topCPU, topMemory: topMem)
    }
}

/// Immutable view model handed to the UI (≤ 1 per second).
public struct DashboardSnapshot: Sendable, Equatable {
    public struct Host: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var available: Bool
        public var isLocal: Bool
        public var nCPU: Int?
        public var cpuPercent: Double?
        public var cpuHistory: [Double]
        public var load1: Double?
        public var memUsed: Double
        public var memTotal: Double?
        public var diskFree: Double?
        public var diskTotal: Double?
        public var running: Int
        public var total: Int
    }

    public struct Counts: Sendable, Equatable {
        public var total = 0, running = 0, healthy = 0, unhealthy = 0, exited = 0, paused = 0, restarting = 0
        public init() {}
    }

    public enum Severity: Int, Sendable { case warning = 1, critical = 2 }

    public struct Problem: Sendable, Equatable, Identifiable {
        public var id: String
        public var severity: Severity
        public var title: String
        public var detail: String
        public var hostId: String?
        public var containerId: String?
        public var since: Date?
    }

    public struct ContainerRow: Sendable, Equatable, Identifiable {
        public var id: String
        public var hostId: String
        public var name: String
        public var hostName: String
        public var cpu: Double
        public var memPercent: Double
        public var memUsage: Double
    }

    public var version: String?
    public var generatedAt: Date
    public var hosts: [Host]
    public var counts: Counts
    public var problems: [Problem]
    public var topCPU: [ContainerRow]
    public var topMemory: [ContainerRow]
}
