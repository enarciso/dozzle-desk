import AppKit
import DozzleCore
import SwiftUI

/// What the setup window hands back once the server checks out.
struct ServerChoice {
    var url: URL
    var auth: ServerAuth
    /// Fingerprint of a certificate the user chose to trust, if the server needed one.
    var trustedCertificate: String?
}

/// "Connect to Dozzle" window: shown on first launch and from "Change Dozzle URL…".
/// Nothing is accepted until DozzleProbe confirms it's a Dozzle the app can stream from
/// with these credentials.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model: SetupModel
    private let onConnect: (ServerChoice) -> Void
    private let onCancel: () -> Void
    private var task: Task<Void, Never>?
    private var finished = false

    init(initialURL: String, auth: ServerAuth, trustedCertificate: String?, firstRun: Bool,
         onConnect: @escaping (ServerChoice) -> Void, onCancel: @escaping () -> Void) {
        self.model = SetupModel(text: initialURL, auth: auth, trustedCertificate: trustedCertificate, firstRun: firstRun)
        self.onConnect = onConnect
        self.onCancel = onCancel
        self.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "DozzleDesk"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        let host = NSHostingController(rootView: SetupView(
            model: model,
            connect: { [weak self] in self?.check() },
            trustCertificate: { [weak self] in self?.trustCertificate() },
            cancel: { [weak self] in self?.window.performClose(nil) }))
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
    }

    func show() {
        window.center()
        bringForward()
    }

    func bringForward() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes without reporting a cancel (used during shutdown).
    func dismiss() {
        finished = true
        task?.cancel()
        window.close()
    }

    private func trustCertificate() {
        guard let cert = model.certificate else { return }
        model.trustedCertificate = cert.fingerprint
        model.certificate = nil
        check()
    }

    private func check() {
        guard model.state != .checking else { return }
        // http://user:pass@host → the address, plus proxy basic-auth credentials.
        if let split = DeskConfig.splitCredentials(model.text), !split.username.isEmpty {
            model.text = split.url.absoluteString
            model.proxyUsername = split.username
            model.proxyPassword = split.password
            model.showProxy = true
        }
        let auth: ServerAuth
        switch model.makeAuth() {
        case .failure(let problem):
            model.showProxy = true
            model.state = .failed(problem.message)
            return
        case .success(let a):
            auth = a
        }
        model.state = .checking
        let raw = model.text
        let pin = model.trustedCertificate
        task = Task { [weak self] in
            let result = await DozzleProbe.check(raw, auth: auth, trustedCertificate: pin)
            guard let self, !Task.isCancelled, !self.finished else { return }
            switch result.outcome {
            case .loginRequired, .loginRejected:
                self.model.showLogin = true
            case .proxyAuthRequired, .proxyDidNotIdentify:
                self.model.showProxy = true
            case .untrustedCertificate(let cert):
                self.model.certificate = cert
            default:
                break
            }
            guard result.outcome.isOK, let url = result.url else {
                self.model.state = .failed(result.outcome.message)
                return
            }
            self.model.state = .ok(result.outcome.message)
            try? await Task.sleep(for: .milliseconds(700))   // let the confirmation register
            guard !Task.isCancelled, !self.finished else { return }
            self.finished = true
            self.window.close()
            self.onConnect(ServerChoice(url: url, auth: auth, trustedCertificate: pin))
        }
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        guard !finished else { return }
        finished = true
        onCancel()
    }
}

@MainActor
final class SetupModel: ObservableObject {
    enum State: Equatable { case idle, checking, failed(String), ok(String) }
    @Published var text: String
    @Published var state: State = .idle
    @Published var username: String
    @Published var password: String
    @Published var proxyUsername: String
    @Published var proxyPassword: String
    @Published var headersText: String
    @Published var showLogin: Bool
    @Published var showProxy: Bool
    /// A certificate waiting for the user's decision.
    @Published var certificate: CertificateInfo?
    @Published var trustedCertificate: String?
    let firstRun: Bool

    init(text: String, auth: ServerAuth, trustedCertificate: String?, firstRun: Bool) {
        self.text = text
        self.username = auth.username
        self.password = auth.password
        self.proxyUsername = auth.proxyUsername
        self.proxyPassword = auth.proxyPassword
        self.headersText = HeaderText.format(auth.headers)
        self.showLogin = auth.usesDozzleLogin
        self.showProxy = auth.usesProxyAuth
        self.trustedCertificate = trustedCertificate
        self.firstRun = firstRun
    }

    func makeAuth() -> Result<ServerAuth, HeaderText.Problem> {
        let proxyUser = proxyUsername.trimmingCharacters(in: .whitespaces)
        return HeaderText.parse(headersText, proxyLogin: !proxyUser.isEmpty).map { headers in
            ServerAuth(username: username.trimmingCharacters(in: .whitespaces),
                       password: password,
                       proxyUsername: proxyUser,
                       proxyPassword: proxyPassword,
                       headers: headers)
        }
    }

    /// Any edit after a failed check clears the error.
    func edited() { if case .failed = state { state = .idle } }
}

private struct SetupView: View {
    @ObservedObject var model: SetupModel
    var connect: () -> Void
    var trustCertificate: () -> Void
    var cancel: () -> Void

    private var checking: Bool { model.state == .checking }
    private var empty: Bool { model.text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.firstRun ? "Connect to Dozzle" : "Change Dozzle server")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Enter the address you use to open Dozzle in your browser.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Dozzle URL", text: $model.text, prompt: Text(verbatim: "http://192.168.1.20:8080"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .onSubmit { if !empty { connect() } }
                .disabled(checking)
                .onChange(of: model.text) { model.edited() }

            DisclosureGroup(isExpanded: $model.showLogin) {
                VStack(alignment: .leading, spacing: 6) {
                    credentialFields(user: $model.username, password: $model.password)
                    caption("For Dozzle's built-in login (DOZZLE_AUTH_PROVIDER=simple). Saved in your Keychain.")
                }
                .padding(.top, 6)
            } label: {
                Text("Dozzle login").font(.system(size: 12, weight: .medium))
            }

            DisclosureGroup(isExpanded: $model.showProxy) {
                VStack(alignment: .leading, spacing: 6) {
                    credentialFields(user: $model.proxyUsername, password: $model.proxyPassword,
                                     userPrompt: "Proxy username")
                    TextEditor(text: $model.headersText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 52)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                        .disabled(checking)
                        .onChange(of: model.headersText) { model.edited() }
                    caption("Basic auth for a proxy in front of Dozzle, and extra headers, one per line, e.g. Authorization: Bearer … or CF-Access-Client-Id: … Saved in your Keychain.")
                }
                .padding(.top, 6)
            } label: {
                Text("Proxy & headers").font(.system(size: 12, weight: .medium))
            }

            if let cert = model.certificate {
                certificatePanel(cert)
            }

            status.frame(minHeight: 16, alignment: .topLeading)

            // verbatim: a plain string literal would turn the example address into a clickable link.
            Text(verbatim: "Add the base path if Dozzle runs under one, e.g. https://nas.lan/dozzle. DozzleDesk only reads from Dozzle and never changes anything.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(model.firstRun ? "Quit" : "Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(empty || checking)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func credentialFields(user: Binding<String>, password: Binding<String>,
                                  userPrompt: String = "Username") -> some View {
        HStack(spacing: 8) {
            TextField(userPrompt, text: user)
                .textContentType(.username)
                .onChange(of: user.wrappedValue) { model.edited() }
            SecureField("Password", text: password)
                .textContentType(.password)
                .onChange(of: password.wrappedValue) { model.edited() }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12))
        .disabled(checking)
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func certificatePanel(_ cert: CertificateInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(cert.replacesTrusted ? "Certificate changed" : "Untrusted certificate",
                  systemImage: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text(verbatim: "\(cert.subject) · \(cert.server)")
                .font(.system(size: 11, weight: .medium))
            Text(verbatim: cert.reason)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "SHA-256\n" + cert.displayFingerprint)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            caption("Trust it only if this matches your server's certificate, for example from: openssl x509 -noout -fingerprint -sha256 -in cert.pem. Only this exact certificate will be trusted, and only for this server.")
            HStack {
                Spacer()
                Button("Trust This Certificate", action: trustCertificate)
                    .disabled(checking)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.35)))
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .ok(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
        }
    }
}
