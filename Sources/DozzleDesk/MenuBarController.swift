import AppKit
import DozzleCore
import SwiftUI

/// Menu bar item. Left-click: Control Center-style dropdown dashboard.
/// Right-click (or Control-click): the classic menu.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: DeskModel
    private let popover = NSPopover()
    private let menu = NSMenu()
    private let headerItem = NSMenuItem(title: "Connecting…", action: nil, keyEquivalent: "")
    private let clickThroughItem = NSMenuItem(title: "Click-through", action: nil, keyEquivalent: "")
    private var opacityItems: [NSMenuItem] = []
    private var lastHeader = ""
    private var lastTint: NSColor?

    init(model: DeskModel, endpoint: String) {
        self.model = model
        super.init()

        if let button = item.button {
            let img = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "DozzleDesk")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeading
            button.toolTip = "DozzleDesk — \(endpoint)\nClick for dashboard, right-click for menu"
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient          // closes when you click anywhere else
        popover.animates = true
        popover.appearance = NSAppearance(named: .vibrantDark)
        popover.delegate = self

        buildMenu()
    }

    // MARK: Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            closePopover()
            item.menu = menu
            sender.performClick(nil)   // shows the menu
            item.menu = nil            // so the next left-click reaches us again
        } else if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = item.button else { return }
        // Built fresh each time and released on close, so nothing renders while it's hidden.
        let controller = NSHostingController(rootView: DashboardView(model: model, style: .popover))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    // MARK: Right-click menu

    private func buildMenu() {
        menu.delegate = self
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("Open Dozzle", shortcut: "o") { $0.openDozzle() })
        menu.addItem(makeItem("Reconnect Now", shortcut: "r") { $0.reconnect() })
        menu.addItem(.separator())
        clickThroughItem.target = self
        clickThroughItem.action = #selector(toggleClickThrough)
        menu.addItem(clickThroughItem)

        let opacityMenu = NSMenu()
        for value in [1.0, 0.85, 0.7, 0.5] {
            let mi = NSMenuItem(title: "\(Int(value * 100))%", action: #selector(pickOpacity(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = value
            opacityMenu.addItem(mi)
            opacityItems.append(mi)
        }
        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)
        menu.addItem(makeItem("Reset Position", shortcut: "") { $0.resetPosition() })
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit DozzleDesk", shortcut: "q") { $0.quit() })
    }

    private final class ActionBox: NSObject {
        let run: (DeskActions) -> Void
        init(_ run: @escaping (DeskActions) -> Void) { self.run = run }
    }

    private func makeItem(_ title: String, shortcut: String, _ run: @escaping (DeskActions) -> Void) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: shortcut)
        mi.target = self
        mi.representedObject = ActionBox(run)
        return mi
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox, let actions = model.actions else { return }
        box.run(actions)
    }

    @objc private func toggleClickThrough() {
        model.actions?.setClickThrough(!model.clickThrough)
    }

    @objc private func pickOpacity(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        model.actions?.setOpacity(v)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        clickThroughItem.state = model.clickThrough ? .on : .off
        for mi in opacityItems {
            mi.state = abs((mi.representedObject as? Double ?? 0) - model.opacity) < 0.01 ? .on : .off
        }
    }

    // MARK: Status

    func update(_ status: LinkStatus) {
        let problems = status.snapshot?.problems.count ?? 0
        let header: String
        let tint: NSColor?
        switch status.phase {
        case .live:
            let n = status.snapshot?.counts.total ?? 0
            header = "Live · \(n) containers · \(problems == 0 ? "all good" : "\(problems) need attention")"
            tint = problems > 0 ? .systemOrange : nil
        case .preflight, .connecting:
            header = "Connecting to \(status.endpoint)…"
            tint = nil
        case .lost:
            header = "Connection lost · retrying"
            tint = .systemOrange
        case .sleeping:
            header = "Paused (sleep)"
            tint = nil
        case .exited:
            header = "Closing"
            tint = .systemRed
        }
        if header != lastHeader {
            headerItem.title = header
            lastHeader = header
        }
        if tint != lastTint {
            item.button?.contentTintColor = tint
            lastTint = tint
        }
        let title = status.phase.isLive && problems > 0 ? " \(problems)" : ""
        if item.button?.title != title { item.button?.title = title }
    }

    func remove() {
        closePopover()
        popover.contentViewController = nil
        NSStatusBar.system.removeStatusItem(item)
    }
}
