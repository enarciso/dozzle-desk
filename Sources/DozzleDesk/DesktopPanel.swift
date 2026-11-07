import AppKit
import Combine
import SwiftUI

/// Borderless, transparent, non-activating panel pinned just above the desktop icons:
/// below every normal window, on every Space, never in ⌘-Tab or Mission Control cycling.
final class DesktopPanel: NSPanel {
    private static let autosaveName = "DozzleDeskPanel"
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var hostView: FirstMouseHostingView<DashboardView>?
    private var modelObserver: AnyCancellable?

    init(model: DeskModel, opacity: Double) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = true
        alphaValue = opacity
        animationBehavior = .none

        let host = FirstMouseHostingView(rootView: DashboardView(model: model))
        host.sizingOptions = [.intrinsicContentSize] // report size; don't constrain the window
        contentView = host
        hostView = host

        // After every model change, size the panel to the SwiftUI content's ideal size.
        modelObserver = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fitToContent() } }
        }
        model.dragChanged = { [weak self] in self?.dragMoved() }
        model.dragEnded = { [weak self] in self?.dragFinished() }

        if !setFrameUsingName(Self.autosaveName) || !isOnSomeScreen {
            resetPosition()
        }
        setFrameAutosaveName(Self.autosaveName)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var isOnSomeScreen: Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    private func fitToContent() {
        guard let hostView else { return }
        fit(hostView.intrinsicContentSize)
    }

    /// Resize to the SwiftUI content, keeping the top edge fixed.
    private func fit(_ size: CGSize) {
        let w = ceil(size.width), h = ceil(size.height)
        guard w > 0, h > 0, abs(frame.width - w) > 0.5 || abs(frame.height - h) > 0.5 else { return }
        var f = frame
        let top = f.maxY
        f.size = NSSize(width: w, height: h)
        f.origin.y = top - h
        setFrame(f, display: true)
    }

    func resetPosition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        setFrameTopLeftPoint(NSPoint(x: vf.maxX - frame.width - 24, y: vf.maxY - 24))
        saveFrame(usingName: Self.autosaveName)
    }

    // Manual dragging (a non-key, non-activating panel can't rely on title-bar dragging).
    private func dragMoved() {
        let mouse = NSEvent.mouseLocation
        if dragStartMouse == nil {
            dragStartMouse = mouse
            dragStartOrigin = frame.origin
        }
        guard let m0 = dragStartMouse, let o0 = dragStartOrigin else { return }
        setFrameOrigin(NSPoint(x: o0.x + mouse.x - m0.x, y: o0.y + mouse.y - m0.y))
    }

    private func dragFinished() {
        dragStartMouse = nil
        dragStartOrigin = nil
        saveFrame(usingName: Self.autosaveName)
    }
}

/// Lets the first click on a background (non-key) panel land on the button under it.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: Content) { super.init(rootView: rootView) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}
