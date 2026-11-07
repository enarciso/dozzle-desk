import AppKit
import DozzleCore
import SwiftUI

/// Dev tool: `DozzleDesk --render-png out.png [--render-when live|lost] [--render-delay 3] [--render-popover]`
/// connects for real, waits until the requested state, renders one frame offscreen, exits.
/// No window, no menu bar item, no lock.
@MainActor
enum RenderMode {
    private static var link: DozzleLink?
    private static var scheduled = false

    static func run(config: DeskConfig, model: DeskModel, output: String) {
        model.renderMode = true
        let link = DozzleLink(
            config: config,
            onStatus: { status in
                Task { @MainActor in
                    model.receive(status)
                    let matches: Bool
                    switch status.phase {
                    case .live: matches = config.renderWhen == "live" && status.snapshot != nil
                    case .lost: matches = config.renderWhen == "lost"
                    default: matches = false
                    }
                    if matches, !scheduled {
                        scheduled = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + config.renderDelay) {
                            MainActor.assumeIsolated { render(model: model, to: output) }
                        }
                    }
                }
            },
            onExit: { reason in
                Task { @MainActor in
                    model.finalMessage = "exit: \(reason.rawValue)"
                    if !scheduled {
                        scheduled = true
                        render(model: model, to: output)
                    }
                }
            })
        self.link = link
        Task { await link.start() }
    }

    private static func render(model: DeskModel, to path: String) {
        let style: DashboardStyle = CommandLine.arguments.contains("--render-popover") ? .popover : .desktop
        let renderer = ImageRenderer(content: DashboardView(model: model, style: style))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) (\(Int(image.size.width))×\(Int(image.size.height)) pt)")
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            exit(1)
        }
        Task {
            await link?.stop()
            exit(0)
        }
    }
}
