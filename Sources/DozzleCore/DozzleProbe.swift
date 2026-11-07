import Foundation

/// The result of checking a URL the user typed.
public enum ProbeOutcome: Sendable, Equatable {
    case ok(version: String?, hosts: Int)
    case invalidURL
    case unreachable(String)
    /// Something answered, but it isn't Dozzle (or a login page / proxy is in the way).
    case notDozzle
    case authRequired
    case httpError(Int)

    public var isOK: Bool { if case .ok = self { return true } else { return false } }

    public var message: String {
        switch self {
        case .ok(let version, let hosts):
            let v = version.map { "Dozzle \($0)" } ?? "Dozzle"
            return "Found \(v) · \(hosts) host\(hosts == 1 ? "" : "s")"
        case .invalidURL:
            return "That isn't a valid http:// or https:// address."
        case .unreachable(let why):
            return why
        case .notDozzle:
            return "Something answered, but it isn't Dozzle. Check the port and base path, or whether a login page or proxy is in front of it."
        case .authRequired:
            return "This Dozzle requires login. DozzleDesk only supports Dozzle without authentication."
        case .httpError(let code):
            return "Dozzle answered with HTTP \(code)."
        }
    }
}

public struct ProbeResult: Sendable, Equatable {
    public var url: URL?
    public var outcome: ProbeOutcome
}

/// Checks that a URL points at a reachable Dozzle the app can stream from:
/// `/healthcheck` answers, `/` carries Dozzle's embedded config, and the event stream opens
/// without a login. GET requests only; the stream is closed as soon as its headers arrive.
public enum DozzleProbe {
    public static func check(_ raw: String, timeout: TimeInterval = 6) async -> ProbeResult {
        guard let url = DeskConfig.normalize(raw) else { return ProbeResult(url: nil, outcome: .invalidURL) }
        let config = DeskConfig(baseURL: url)

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 3
        cfg.waitsForConnectivity = false
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpAdditionalHeaders = ["User-Agent": "DozzleDesk/0.1"]
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        func result(_ o: ProbeOutcome) -> ProbeResult { ProbeResult(url: url, outcome: o) }

        do {
            let (_, health) = try await session.data(from: config.healthURL)
            switch (health as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: break
            case 401, 403: return result(.authRequired)
            case 404: return result(.notDozzle)
            case let code: return result(.httpError(code))
            }

            let (html, index) = try await session.data(from: config.indexURL)
            let indexCode = (index as? HTTPURLResponse)?.statusCode ?? 0
            if indexCode == 401 || indexCode == 403 { return result(.authRequired) }
            guard indexCode == 200, let dz = DzIndexConfig.parse(html: String(decoding: html, as: UTF8.self)) else {
                return result(.notDozzle)
            }

            var req = URLRequest(url: config.streamURL)
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let (bytes, stream) = try await session.bytes(for: req)
            bytes.task.cancel()
            switch (stream as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: return result(.ok(version: dz.version, hosts: dz.hosts.count))
            case 401, 403: return result(.authRequired)
            case 404: return result(.notDozzle)
            case let code: return result(.httpError(code))
            }
        } catch {
            return result(.unreachable(describe(error, host: url.host ?? raw)))
        }
    }

    static func describe(_ error: Error, host: String) -> String {
        guard let e = error as? URLError else { return error.localizedDescription }
        switch e.code {
        case .cannotFindHost, .dnsLookupFailed:
            return "Can't find a server named “\(host)”."
        case .cannotConnectToHost:
            return "\(host) refused the connection. Is Dozzle running on that port?"
        case .timedOut:
            return "\(host) didn't answer in time."
        case .notConnectedToInternet, .networkConnectionLost:
            return "This Mac isn't connected to a network."
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .secureConnectionFailed:
            return "\(host)'s HTTPS certificate isn't trusted by this Mac."
        case .appTransportSecurityRequiresSecureConnection:
            return "macOS blocked plain http:// to \(host). Use https://."
        default:
            return e.localizedDescription
        }
    }
}
