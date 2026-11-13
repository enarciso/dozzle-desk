import Foundation
import Testing
@testable import DozzleCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func ev(_ name: String, _ json: String) -> SSEEvent { SSEEvent(event: name, data: json) }

@Suite struct HeaderTextTests {
    @Test func parsesHeadersSkippingBlanksAndComments() throws {
        let text = """
        # Cloudflare Access service token
        CF-Access-Client-Id: abc.access
        CF-Access-Client-Secret:  s3cr3t:with:colons \r

        X-Remote-User: me
        """
        let headers = try HeaderText.parse(text).get()
        #expect(headers == [HTTPHeader(name: "CF-Access-Client-Id", value: "abc.access"),
                            HTTPHeader(name: "CF-Access-Client-Secret", value: "s3cr3t:with:colons"),
                            HTTPHeader(name: "X-Remote-User", value: "me")])
        #expect(HeaderText.format(headers).components(separatedBy: "\n").count == 3)
    }

    @Test func rejectsWhatWouldBreakTheConnection() {
        #expect(HeaderText.parse("no colon here") == .failure(.malformed(line: 1)))
        #expect(HeaderText.parse("ok: 1\n: value") == .failure(.malformed(line: 2)))
        #expect(HeaderText.parse("Bad Name: x") == .failure(.invalidName("Bad Name")))
        #expect(HeaderText.parse("Host: evil.example") == .failure(.reserved("Host")))
        #expect(HeaderText.parse("content-length: 5") == .failure(.reserved("content-length")))
        #expect(HeaderText.parse("X-Bell: a\u{07}b") == .failure(.malformed(line: 1)))
        #expect(HeaderText.parse("Authorization: Bearer t", proxyLogin: true) == .failure(.duplicateAuthorization))
        #expect((try? HeaderText.parse("Authorization: Bearer t").get())?.first?.value == "Bearer t")
    }
}

@Suite struct ServerAuthTests {
    @Test func flagsAndBasicHeader() {
        #expect(ServerAuth.none.isEmpty)
        let auth = ServerAuth(proxyUsername: "admin", proxyPassword: "p@ss:word")
        #expect(auth.usesProxyAuth && !auth.usesDozzleLogin)
        #expect(auth.proxyAuthorization == "Basic " + Data("admin:p@ss:word".utf8).base64EncodedString())
        #expect(ServerAuth(username: "me", password: "x").usesDozzleLogin)
        #expect(ServerAuth(headers: [HTTPHeader(name: "X", value: "1")]).usesProxyAuth)
    }

    @Test func memoryStoreRoundTripsAndForgetsEmpty() throws {
        let store = MemoryCredentialStore()
        let url = URL(string: "https://nas.lan/dozzle")!
        let auth = ServerAuth(username: "me", password: "pw", headers: [HTTPHeader(name: "X-A", value: "b")])
        try store.save(auth, for: url)
        #expect(store.load(for: url) == auth)
        #expect(store.load(for: URL(string: "https://other.lan")!) == .none)
        try store.save(.none, for: url)
        #expect(store.load(for: url) == .none)
    }

    @Test func urlCredentialsMoveOutOfTheURL() throws {
        let split = try #require(DeskConfig.splitCredentials("admin:p%40ss@nas.lan:8080/dozzle/"))
        #expect(split.url.absoluteString == "http://nas.lan:8080/dozzle")
        #expect(split.username == "admin")
        #expect(split.password == "p@ss")
        #expect(DeskConfig.splitCredentials("https://nas.lan")?.username == "")
        // The saved URL itself never carries credentials.
        #expect(DeskConfig.normalize("http://admin:pw@nas.lan") == nil)
        #expect(DeskConfig(baseURL: URL(string: "http://nas.lan/dozzle")!).tokenURL.absoluteString
                == "http://nas.lan/dozzle/api/token")
    }

    @Test func formEncodingEscapesEverythingButUnreserved() {
        #expect(DozzleClient.form(["username": "me", "password": "a b&c=d+é"])
                == "password=a%20b%26c%3Dd%2B%C3%A9&username=me")
    }
}

@Suite struct CertificatePinTests {
    @Test func serverKeysIncludeDefaultPorts() {
        #expect(CertificatePins.serverKey(URL(string: "https://NAS.lan/dozzle")!) == "nas.lan:443")
        #expect(CertificatePins.serverKey(URL(string: "http://nas.lan")!) == "nas.lan:80")
        #expect(CertificatePins.serverKey(URL(string: "https://10.0.0.5:8443")!) == "10.0.0.5:8443")
    }

    @Test func pinsArePerServer() {
        let defaults = UserDefaults(suiteName: "pins-\(UUID().uuidString)")!
        let a = URL(string: "https://a.lan:8443")!, b = URL(string: "https://b.lan:8443")!
        CertificatePins.setPin("AA", for: a, defaults: defaults)
        #expect(CertificatePins.pin(for: a, defaults: defaults) == "AA")
        #expect(CertificatePins.pin(for: b, defaults: defaults) == nil)
        CertificatePins.setPin(nil, for: a, defaults: defaults)
        #expect(CertificatePins.pin(for: a, defaults: defaults) == nil)
    }

    @Test func fingerprintDisplayIsColonSeparatedInTwoLines() {
        let hex = String(repeating: "AB", count: 32)
        let lines = CertificatePins.display(hex).components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[0] == Array(repeating: "AB", count: 16).joined(separator: ":"))
    }
}

@Suite struct DozzleModesTests {
    @Test func loginPageConfigSaysHowToSignIn() throws {
        let html = """
        <script type="application/json" id="config__json">{"base":"","passwordLogin":false,
        "oauthProviders":[{"name":"GitHub","loginUrl":"/api/auth/github","icon":"github"}]}</script>
        """
        let cfg = try #require(DzIndexConfig.parse(html: html))
        #expect(cfg.hosts.isEmpty)
        #expect(cfg.passwordLogin == false)
        #expect(cfg.oauthProviders == ["GitHub"])
        let swarm = try #require(DzIndexConfig.parse(html: #"<script id="config__json">{"mode":"swarm","hosts":[]}</script>"#))
        #expect(swarm.modeLabel == "Swarm")
        #expect(DzIndexConfig.parse(html: #"<script id="config__json">{"mode":"server","hosts":[]}</script>"#)?.modeLabel == nil)
    }

    @Test func dockerIDsKeyByShortFormOthersStayWhole() {
        #expect(HomelabState.key(String(repeating: "a1", count: 32)) == "a1a1a1a1a1a1")
        #expect(HomelabState.key("kube-system:coredns-5d78c9869d-abcde:coredns")
                == "kube-system:coredns-5d78c9869d-abcde:coredns")
        #expect(HomelabState.key("web") == "web")
    }

    /// Kubernetes mode: hosts are nodes (id = node name) and containers are pod containers.
    @Test func kubernetesPodsInOneNamespaceStaySeparate() {
        var s = HomelabState()
        s.setInventory(DzIndexConfig.parse(html: """
        <script id="config__json">{"mode":"k8s","version":"v11.4.2","hosts":[
          {"name":"node-1","id":"node-1","nCPU":4,"memTotal":8000000000,"type":"k8s","available":true}]}</script>
        """)!)
        let pods = """
        [{"id":"kube-system:coredns-5d78c9869d-abcde:coredns","name":"coredns","state":"running","host":"node-1"},
         {"id":"kube-system:metrics-server-7f8d-xyz:metrics-server","name":"metrics-server","state":"running","host":"node-1"},
         {"id":"apps:web-6c9f-qwe:web","name":"web","state":"restarting","host":"node-1"}]
        """
        let applied = s.apply(ev("containers-changed", pods), now: t0)
        #expect(applied)
        _ = s.apply(ev("container-stat", #"{"id":"kube-system:coredns-5d78c9869d-abcde:coredns","cpu":12.5,"memory":1,"memoryUsage":50000000}"#), now: t0)
        let snap = s.snapshot(now: t0)
        #expect(snap.counts.total == 3)
        #expect(snap.counts.running == 2)
        #expect(snap.topCPU.first?.name == "coredns")
        #expect(snap.problems.contains { $0.title == "web is restarting" && $0.detail == "node-1" })
        #expect(snap.hosts.first?.running == 2)
    }
}

/// Answers DozzleClient's requests in-process, like a tiny Dozzle with simple auth.
final class StubDozzle: URLProtocol {
    nonisolated(unsafe) static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.seen.append(request)
        let url = request.url!
        var status = 200
        var headers = ["Content-Type": "text/plain"]
        switch (request.httpMethod ?? "GET", url.path) {
        case ("POST", "/api/token"):
            headers["Set-Cookie"] = "jwt=tok123; Path=/; HttpOnly"
        case ("GET", "/api/events/stream"):
            status = (request.value(forHTTPHeaderField: "Cookie") ?? "").contains("jwt=tok123") ? 200 : 401
        default:
            status = 404
        }
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct DozzleClientTests {
    @Test func signsInAndSendsTheSessionAsACookieAlongsideProxyAuth() async throws {
        StubDozzle.seen = []
        var config = DeskConfig(baseURL: URL(string: "http://dozzle.test")!)
        config.auth = ServerAuth(username: "me", password: "pw", proxyUsername: "proxy", proxyPassword: "pp",
                                 headers: [HTTPHeader(name: "Cookie", value: "authelia_session=s1"),
                                           HTTPHeader(name: "X-Extra", value: "1")])
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubDozzle.self]
        let client = DozzleClient(config: config, configuration: cfg)
        defer { client.invalidate() }

        let (_, before) = try await client.data(config.streamURL, timeout: 5)
        #expect(before.statusCode == 401)
        #expect(try await client.login() == .ok)
        #expect(client.hasSession)
        let (_, after) = try await client.data(config.streamURL, timeout: 5)
        #expect(after.statusCode == 200)

        let last = try #require(StubDozzle.seen.last)
        #expect(last.value(forHTTPHeaderField: "Cookie") == "authelia_session=s1; jwt=tok123")
        #expect(last.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
        #expect(last.value(forHTTPHeaderField: "X-Extra") == "1")
        client.clearSession()
        #expect(!client.hasSession)
    }
}

@Suite struct EnvironmentCredentialTests {
    @Test func environmentOverridesOnlyWhenSet() throws {
        #expect(ServerAuth.fromEnvironment(["HOME": "/x"]) == nil)
        let auth = try #require(try ServerAuth.fromEnvironment([
            "DOZZLEDESK_USERNAME": "me", "DOZZLEDESK_PASSWORD": "pw",
            "DOZZLEDESK_HEADERS": "X-A: 1\nX-B: 2"])?.get())
        #expect(auth.username == "me" && auth.headers.count == 2)
        #expect(ServerAuth.fromEnvironment(["DOZZLEDESK_HEADERS": "Host: x"]) == .failure(.reserved("Host")))
        #expect(ServerAuth.certificateFromEnvironment(["DOZZLEDESK_CERT_SHA256": "ab:cd"]) == "ABCD")
    }
}
