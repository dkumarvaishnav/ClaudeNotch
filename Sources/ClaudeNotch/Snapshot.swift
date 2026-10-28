#if DEBUG
import AppKit
import SwiftUI

/// Off-screen render of each notch state, for checking the design without screen-recording access.
@MainActor
enum Snapshot {
    static func render(to dir: URL) {
        Spark.staticRendering = true
        let store = SessionStore()
        store.refreshNow()
        // Let the main-queue publish from the poll land.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        let geometry = screen.map(NotchGeometry.init) ?? NotchGeometry(fallback: true)
        print("sessions: \(store.sessions.count), notch: \(geometry.hasNotch) \(geometry.width)x\(geometry.height)")
        for s in store.sessions {
            print(" - [\(s.state)] \(s.title) | \(s.project) | \(s.activity)")
        }

        let modes: [(String, NotchModel.Mode)] = [
            ("collapsed", .collapsed),
            ("expanded", .expanded),
            ("peek", .peek),
            ("detail", .detail(store.sessions.first { $0.status == "idle" }?.id ?? store.sessions.first?.id ?? "")),
        ]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, mode) in modes {
            let model = NotchModel(hasNotch: geometry.hasNotch, notchWidth: geometry.width, notchHeight: geometry.height)
            model.mode = mode
            let size = model.maxBodySize
            let view = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(white: 0.55), Color(white: 0.35)], startPoint: .top, endPoint: .bottom)
                NotchRootView(store: store, model: model)
            }
            .frame(width: size.width + 80, height: size.height + 40)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                print("could not render \(name)")
                continue
            }
            let url = dir.appendingPathComponent("notch-\(name).png")
            try? png.write(to: url)
            print("wrote \(url.path)")
        }
    }
}

extension NotchGeometry {
    init(fallback: Bool) {
        hasNotch = true
        width = 185
        height = 32
        midX = 0
        top = 0
    }
}
#endif
