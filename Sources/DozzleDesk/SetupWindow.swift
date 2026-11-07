import AppKit
import DozzleCore
import SwiftUI

/// "Connect to Dozzle" window: shown on first launch and from "Change Dozzle URL…".
/// The URL is only accepted after DozzleProbe confirms it's a Dozzle the app can stream from.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model: SetupModel
    private let onConnect: (URL) -> Void
    private let onCancel: () -> Void
    private var task: Task<Void, Never>?
    private var finished = false

    init(initialURL: String, firstRun: Bool,
         onConnect: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
        self.model = SetupModel(text: initialURL, firstRun: firstRun)
        self.onConnect = onConnect
        self.onCancel = onCancel
        self.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "DozzleDesk"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        let host = NSHostingController(rootView: SetupView(
            model: model,
            connect: { [weak self] in self?.check() },
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

    private func check() {
        guard model.state != .checking else { return }
        model.state = .checking
        let raw = model.text
        task = Task { [weak self] in
            let result = await DozzleProbe.check(raw)
            guard let self, !Task.isCancelled, !self.finished else { return }
            guard result.outcome.isOK, let url = result.url else {
                self.model.state = .failed(result.outcome.message)
                return
            }
            self.model.state = .ok(result.outcome.message)
            try? await Task.sleep(for: .milliseconds(700))   // let the confirmation register
            guard !Task.isCancelled, !self.finished else { return }
            self.finished = true
            self.window.close()
            self.onConnect(url)
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
    let firstRun: Bool

    init(text: String, firstRun: Bool) {
        self.text = text
        self.firstRun = firstRun
    }
}

private struct SetupView: View {
    @ObservedObject var model: SetupModel
    var connect: () -> Void
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
                .onChange(of: model.text) { if case .failed = model.state { model.state = .idle } }

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
        .frame(width: 440)
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
