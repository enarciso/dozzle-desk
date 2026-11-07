import AppKit
import DozzleCore
import SwiftUI
import os

private let log = Logger(subsystem: "com.narciso.dozzledesk", category: "app")
private let showNotification = Notification.Name("com.narciso.dozzledesk.show")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config = DeskConfig.load(arguments: CommandLine.arguments)
    private lazy var model = DeskModel(config: config)
    private var panel: DesktopPanel?
    private var menuBar: MenuBarController?
    private var link: DozzleLink?
    private var lock: InstanceLock?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var shuttingDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()

        if let png = config.renderPNG {
            RenderMode.run(config: config, model: model, output: png)
            return
        }

        guard let lock = InstanceLock.acquire() else {
            log.notice("another DozzleDesk is running; asking it to come forward")
            DistributedNotificationCenter.default().postNotificationName(
                showNotification, object: nil, userInfo: nil, deliverImmediately: true)
            exit(0)
        }
        self.lock = lock

        let defaults = UserDefaults.standard
        model.clickThrough = defaults.bool(forKey: "clickThrough")
        model.opacity = defaults.object(forKey: "opacity") == nil ? config.opacity : defaults.double(forKey: "opacity")
        model.showCard = config.showCard ?? (defaults.object(forKey: "showDesktopCard") as? Bool ?? true)
        if model.showCard { openPanel() }

        let menuBar = MenuBarController(model: model, endpoint: config.displayHost)
        self.menuBar = menuBar

        // Opening a Dozzle page from the dropdown also closes the dropdown.
        model.open = { [weak menuBar] url in
            menuBar?.closePopover()
            NSWorkspace.shared.open(url)
        }
        model.actions = DeskActions(
            openDozzle: { [weak self, config] in
                self?.menuBar?.closePopover()
                NSWorkspace.shared.open(config.indexURL)
            },
            reconnect: { [weak self] in
                guard let link = self?.link else { return }
                Task { await link.reconnectNow() }
            },
            setClickThrough: { [weak self] on in
                self?.panel?.ignoresMouseEvents = on
                self?.model.clickThrough = on
                UserDefaults.standard.set(on, forKey: "clickThrough")
            },
            setOpacity: { [weak self] value in
                self?.panel?.alphaValue = value
                self?.model.opacity = value
                UserDefaults.standard.set(value, forKey: "opacity")
            },
            setShowCard: { [weak self] on in
                guard let self else { return }
                self.model.showCard = on
                UserDefaults.standard.set(on, forKey: "showDesktopCard")
                if on { self.openPanel() } else { self.closePanel() }
            },
            resetPosition: { [weak self] in self?.panel?.resetPosition() },
            quit: { [weak self] in self?.shutdown(reason: .userQuit) })

        observeSystem()

        let link = DozzleLink(
            config: config,
            onStatus: { [weak self] status in Task { @MainActor in self?.apply(status) } },
            onExit: { [weak self] reason in Task { @MainActor in self?.linkExited(reason) } })
        self.link = link
        Task { await link.start() }
        log.info("started; watching \(self.config.baseURL.absoluteString, privacy: .public)")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shutdown(reason: .userQuit)
        return .terminateLater
    }

    private var lastPhase: LinkPhase?

    private func apply(_ status: LinkStatus) {
        if status.phase != lastPhase {
            log.notice("phase: \(String(describing: status.phase), privacy: .public)")
            lastPhase = status.phase
        }
        model.receive(status)
        menuBar?.update(status)
    }

    // MARK: Desktop card

    /// Creates the card (restoring its saved position). No-op if it's already open.
    private func openPanel() {
        guard panel == nil else {
            panel?.orderFrontRegardless()
            return
        }
        let panel = DesktopPanel(model: model, opacity: model.opacity)
        panel.ignoresMouseEvents = model.clickThrough
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Fully closes the card (not just hides it), so it does no layout or drawing work.
    private func closePanel() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    private func linkExited(_ reason: ExitReason) {
        // With the card turned off, bring it back just for the closing message, so the app
        // never disappears silently. The saved "card off" preference is left unchanged.
        if reason != .userQuit { openPanel() }
        switch reason {
        case .userQuit:
            shutdown(reason: reason)
        case .graceExpired:
            model.finalMessage = "Connection lost — closing DozzleDesk"
            after(3) { self.shutdown(reason: reason) }
        case .unreachableAtLaunch:
            model.finalMessage = "Can't reach \(config.displayHost) — closing"
            after(5) { self.shutdown(reason: reason) }
        case .authRequired:
            model.finalMessage = "Dozzle requires login — closing"
            after(5) { self.shutdown(reason: reason) }
        }
    }

    private func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { body() } }
    }

    /// The one exit path: stop networking, drop observers, close UI, release the lock, exit 0.
    private func shutdown(reason: ExitReason) {
        guard !shuttingDown else { return }
        shuttingDown = true
        log.notice("shutting down (\(reason.rawValue, privacy: .public))")
        Task { @MainActor in
            if let link { await link.stop() }
            self.link = nil
            let ws = NSWorkspace.shared.notificationCenter
            workspaceObservers.forEach { ws.removeObserver($0) }
            workspaceObservers.removeAll()
            distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
            distributedObservers.removeAll()
            signalSources.forEach { $0.cancel() }
            panel?.orderOut(nil)
            panel?.close()
            panel = nil
            menuBar?.remove()
            menuBar = nil
            lock?.release()
            lock = nil
            exit(0)
        }
    }

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let link = self?.link else { return }
                Task { await link.sleep() }
            }
        })
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let link = self?.link else { return }
                Task { await link.wake() }
            }
        })
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.displayPaused = true }
        })
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.displayPaused = false }
        })
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: showNotification, object: nil, queue: .main) { [weak self] _ in
            // Launching again while running: bring the card forward, or open the dropdown if the card is off.
            MainActor.assumeIsolated {
                guard let self else { return }
                if let panel = self.panel { panel.orderFrontRegardless() } else { self.menuBar?.showPopover() }
            }
        })
    }

    /// Ctrl-C / `kill` take the same clean shutdown path as Quit.
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    if let self, self.config.renderPNG == nil { self.shutdown(reason: .userQuit) } else { exit(0) }
                }
            }
            src.resume()
            signalSources.append(src)
        }
    }
}

/// Single-instance guard: an advisory `flock`, released automatically if the process dies.
final class InstanceLock {
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    /// Returns nil only when another instance holds the lock. If the lock file can't be
    /// created at all, runs unguarded rather than refusing to start.
    static func acquire() -> InstanceLock? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return InstanceLock(fd: -1)
        }
        let dir = base.appendingPathComponent("DozzleDesk", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return InstanceLock(fd: -1) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        return InstanceLock(fd: fd)
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }
}
