import AppKit
import Combine
import DozzleCore

/// User commands shared by the dropdown and the right-click menu.
struct DeskActions {
    var openDozzle: () -> Void
    var reconnect: () -> Void
    var setClickThrough: (Bool) -> Void
    var setOpacity: (Double) -> Void
    var resetPosition: () -> Void
    var quit: () -> Void
}

@MainActor
final class DeskModel: ObservableObject {
    let config: DeskConfig
    @Published private(set) var status: LinkStatus
    @Published var finalMessage: String?
    /// Solid background instead of a live blur (offscreen PNG rendering can't capture blur).
    var renderMode = false
    var open: (URL) -> Void = { _ in }
    var actions: DeskActions?
    @Published var clickThrough = false
    @Published var opacity: Double = 1
    var dragChanged: (() -> Void)?
    var dragEnded: (() -> Void)?

    /// While displays sleep, keep draining the stream but skip SwiftUI updates.
    var displayPaused = false {
        didSet { if !displayPaused, let latest { status = latest } }
    }
    private var latest: LinkStatus?

    init(config: DeskConfig) {
        self.config = config
        self.status = .initial(endpoint: config.displayHost)
    }

    func receive(_ s: LinkStatus) {
        latest = s
        if !displayPaused, s != status { status = s }
    }
}
