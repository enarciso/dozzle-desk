import AppKit
import DozzleCore
import SwiftUI
import os

private let log = Logger(subsystem: AppIdentity.id, category: "app")
private let showNotification = Notification.Name(AppIdentity.id + ".show")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let arguments = CommandLine.arguments
    /// nil until a Dozzle URL is known (first launch waits on the setup window).
    private var config: DeskConfig?
    private var model: DeskModel?
    private var panel: DesktopPanel?
    private var menuBar: MenuBarController?
    private var setup: SetupWindowController?
    private var link: DozzleLink?
    /// Bumped whenever a link is replaced, so late callbacks from the old one are ignored.
    private var linkGeneration = 0
    /// Set when the link has given up; the app closes unless the user picks another URL.
    private var exitReason: ExitReason?
    private var pendingExit: DispatchWorkItem?
    private var lock: InstanceLock?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var shuttingDown = false
    private var oneShot = false   // --check / --render-png: no UI, no lock

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()

        if let raw = DeskConfig.flag("check", in: arguments) {
            oneShot = true
            Task {
                let result = await DozzleProbe.check(raw)
                print("\(result.url?.absoluteString ?? raw): \(result.outcome.message)")
                exit(result.outcome.isOK ? 0 : 1)
            }
            return
        }

        if arguments.contains("--render-png") {
            oneShot = true
            guard let config = DeskConfig.load(arguments: arguments), let png = config.renderPNG else {
                FileHandle.standardError.write(Data("--render-png needs --url (or a saved URL)\n".utf8))
                exit(1)
            }
            RenderMode.run(config: config, model: DeskModel(config: config), output: png)
            return
        }

        guard let lock = InstanceLock.acquire() else {
            log.notice("another DozzleDesk is running; asking it to come forward")
            DistributedNotificationCenter.default().postNotificationName(
                showNotification, object: nil, userInfo: nil, deliverImmediately: true)
            exit(0)
        }
        self.lock = lock
        installMainMenu()
        observeSystem()

        if let config = DeskConfig.load(arguments: arguments) {
            begin(with: config)
        } else {
            if let bad = DeskConfig.flag("url", in: arguments) {
                log.error("ignoring invalid --url \(bad, privacy: .public)")
            }
            log.notice("no Dozzle URL configured; showing setup")
            showSetup()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shutdown(reason: .userQuit)
        return .terminateLater
    }

    // MARK: Startup

    /// Builds the card, menu bar item and actions, then connects. Runs once.
    private func begin(with config: DeskConfig) {
        self.config = config
        let defaults = UserDefaults.standard
        let model = DeskModel(config: config)
        self.model = model
        model.clickThrough = defaults.bool(forKey: "clickThrough")
        model.opacity = defaults.object(forKey: "opacity") == nil ? config.opacity : defaults.double(forKey: "opacity")
        model.showCard = config.showCard ?? (defaults.object(forKey: "showDesktopCard") as? Bool ?? true)
        if model.showCard { openPanel() }

        let menuBar = MenuBarController(model: model)
        menuBar.setEndpoint(config.displayHost)
        self.menuBar = menuBar

        // Opening a Dozzle page from the dropdown also closes the dropdown.
        model.open = { [weak menuBar] url in
            menuBar?.closePopover()
            NSWorkspace.shared.open(url)
        }
        model.actions = DeskActions(
            openDozzle: { [weak self] in
                guard let self, let config = self.config else { return }
                self.menuBar?.closePopover()
                NSWorkspace.shared.open(config.indexURL)
            },
            reconnect: { [weak self] in
                guard let link = self?.link else { return }
                Task { await link.reconnectNow() }
            },
            setClickThrough: { [weak self] on in
                self?.panel?.ignoresMouseEvents = on
                self?.model?.clickThrough = on
                UserDefaults.standard.set(on, forKey: "clickThrough")
            },
            setOpacity: { [weak self] value in
                self?.panel?.alphaValue = value
                self?.model?.opacity = value
                UserDefaults.standard.set(value, forKey: "opacity")
            },
            setShowCard: { [weak self] on in
                guard let self else { return }
                self.model?.showCard = on
                UserDefaults.standard.set(on, forKey: "showDesktopCard")
                if on { self.openPanel() } else { self.closePanel() }
            },
            resetPosition: { [weak self] in self?.panel?.resetPosition() },
            changeURL: { [weak self] in self?.showSetup() },
            quit: { [weak self] in self?.shutdown(reason: .userQuit) })

        startLink()
    }

    private func startLink() {
        guard let config, !shuttingDown else { return }
        linkGeneration += 1
        let generation = linkGeneration
        let link = DozzleLink(
            config: config,
            onStatus: { [weak self] status in
                Task { @MainActor in
                    guard let self, self.linkGeneration == generation else { return }
                    self.apply(status)
                }
            },
            onExit: { [weak self] reason in
                Task { @MainActor in
                    guard let self, self.linkGeneration == generation else { return }
                    self.linkExited(reason)
                }
            })
        self.link = link
        Task { await link.start() }
        log.info("watching \(config.baseURL.absoluteString, privacy: .public)")
    }

    private var lastPhase: LinkPhase?

    private func apply(_ status: LinkStatus) {
        if status.phase != lastPhase {
            log.notice("phase: \(String(describing: status.phase), privacy: .public)")
            lastPhase = status.phase
        }
        model?.receive(status)
        menuBar?.update(status)
    }

    // MARK: Choosing the Dozzle URL

    private func showSetup() {
        guard !shuttingDown else { return }
        if let setup {
            setup.bringForward()
            return
        }
        // Don't close underneath someone who is typing a new address.
        pendingExit?.cancel()
        pendingExit = nil
        menuBar?.closePopover()
        let initial = config?.baseURL.absoluteString ?? DeskConfig.requestedURL(arguments: arguments) ?? ""
        let controller = SetupWindowController(
            initialURL: initial,
            firstRun: config == nil,
            onConnect: { [weak self] url in
                self?.setup = nil
                self?.connect(to: url)
            },
            onCancel: { [weak self] in self?.setupCancelled() })
        setup = controller
        controller.show()
    }

    /// Saves the (already verified) URL and connects to it, replacing any current link.
    private func connect(to url: URL) {
        guard !shuttingDown else { return }
        UserDefaults.standard.set(url.absoluteString, forKey: DeskConfig.urlKey)
        let newConfig = DeskConfig.load(arguments: arguments, baseURL: url)
        log.notice("Dozzle URL set to \(url.absoluteString, privacy: .public)")
        guard let model else {
            begin(with: newConfig)
            return
        }
        pendingExit?.cancel()
        pendingExit = nil
        exitReason = nil
        lastPhase = nil
        config = newConfig
        model.reset(config: newConfig)
        menuBar?.setEndpoint(newConfig.displayHost)
        let old = link
        link = nil
        linkGeneration += 1   // silence the old link right away
        Task { @MainActor in
            if let old { await old.stop() }
            self.startLink()
        }
    }

    private func setupCancelled() {
        setup = nil
        if config == nil {
            shutdown(reason: .userQuit)        // first launch, nothing to show
        } else if let exitReason {
            shutdown(reason: exitReason)       // the link already gave up; close now
        }
    }

    // MARK: Desktop card

    /// Creates the card (restoring its saved position). No-op if it's already open.
    private func openPanel() {
        guard let model else { return }
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
        guard reason != .userQuit else { return shutdown(reason: reason) }
        exitReason = reason
        let host = config?.displayHost ?? "Dozzle"
        let delay: Double
        switch reason {
        case .graceExpired:
            model?.finalMessage = "Connection lost — closing DozzleDesk"
            delay = 3
        case .unreachableAtLaunch:
            model?.finalMessage = "Can't reach \(host) — closing"
            model?.offerChangeURL = true
            delay = 8
        case .authRequired:
            model?.finalMessage = "\(host) requires login — closing"
            model?.offerChangeURL = true
            delay = 8
        case .userQuit:
            return
        }
        // While the setup window is open, closing waits for the user to save or cancel.
        guard setup == nil else { return }
        // With the card turned off, bring it back just for the closing message, so the app
        // never disappears silently. The saved "card off" preference is left unchanged.
        openPanel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.shutdown(reason: reason) }
        }
        pendingExit = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// The one exit path: stop networking, drop observers, close UI, release the lock, exit 0.
    private func shutdown(reason: ExitReason) {
        guard !shuttingDown else { return }
        shuttingDown = true
        pendingExit?.cancel()
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
            setup?.dismiss()
            setup = nil
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

    // MARK: System

    /// An accessory app has no visible menu bar, but text fields still need ⌘C/⌘V/⌘A,
    /// which AppKit routes through the main menu.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit DozzleDesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
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
            MainActor.assumeIsolated { self?.model?.displayPaused = true }
        })
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model?.displayPaused = false }
        })
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: showNotification, object: nil, queue: .main) { [weak self] _ in
            // Launching again while running: bring the setup window or card forward,
            // or open the dropdown if the card is off.
            MainActor.assumeIsolated {
                guard let self else { return }
                if let setup = self.setup { setup.bringForward() }
                else if let panel = self.panel { panel.orderFrontRegardless() }
                else { self.menuBar?.showPopover() }
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
                    if let self, !self.oneShot { self.shutdown(reason: .userQuit) } else { exit(0) }
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
