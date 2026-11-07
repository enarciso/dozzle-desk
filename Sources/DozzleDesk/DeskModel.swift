import AppKit
import Combine
import DozzleCore

/// User commands shared by the dropdown and the right-click menu.
struct DeskActions {
    var openDozzle: () -> Void
    var reconnect: () -> Void
    var setClickThrough: (Bool) -> Void
    var setOpacity: (Double) -> Void
    var setShowCard: (Bool) -> Void
    var resetPosition: () -> Void
    var changeURL: () -> Void
    var quit: () -> Void
}

@MainActor
final class DeskModel: ObservableObject {
    @Published private(set) var config: DeskConfig
    @Published private(set) var status: LinkStatus
    @Published var finalMessage: String?
    /// The closing message offers "Change URL…" (unreachable at launch, login required).
    @Published var offerChangeURL = false
    /// Solid background instead of a live blur (offscreen PNG rendering can't capture blur).
    var renderMode = false
    var open: (URL) -> Void = { _ in }
    var actions: DeskActions?
    @Published var clickThrough = false
    @Published var opacity: Double = 1
    /// false = dropdown-only mode.
    @Published var showCard = true
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

    /// Switching to another Dozzle: forget everything shown for the old one.
    func reset(config: DeskConfig) {
        self.config = config
        latest = nil
        finalMessage = nil
        offerChangeURL = false
        status = .initial(endpoint: config.displayHost)
    }

    func receive(_ s: LinkStatus) {
        latest = s
        if !displayPaused, s != status { status = s }
    }
}
