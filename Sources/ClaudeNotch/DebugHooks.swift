#if DEBUG
import AppKit

/// Debug builds only: drive the notch from outside and capture its window. Post the distributed
/// notification "ClaudeNotch.debug" with object:
/// expand | peek | collapse | detail[:id] | allow | deny | answer:<option> | denynote:<text> | reply:<text> |
/// capture:/tmp/prefix (view render) | shot:/tmp/x.png (window server) | film:/tmp/prefix,expand|collapse | measure
/// Only installed when the debug build runs with CLAUDENOTCH_DEBUG=1.
enum DebugHooks {
    private static var observer: NSObjectProtocol?

    static func install(controllers: @escaping () -> [NotchController], store: SessionStore, timer: TimerStore,
                        shelf: ShelfStore, app: AppActions) {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("ClaudeNotch.debug"), object: nil, queue: .main
        ) { note in
            guard let command = note.object as? String else { return }
            NSLog("ClaudeNotch debug: \(command)")
            let all = controllers()
            let first = store.sessions.first
            let target = store.sessions.first { $0.permission != nil } ?? first
            switch command {
            case "expand": all.forEach { $0.open() }
            case "hold": NotchController.debugHold = true
            case "release": NotchController.debugHold = false
            case "tab:claude": all.first?.select(.claude)
            case "tab:timer": all.first?.select(.timer)
            case "tab:shelf": all.first?.select(.shelf)
            case "pomodoro": timer.page = .pomodoro; timer.startFocus()
            case "pause": timer.pause()
            case "resume": timer.resume()
            case "skip": timer.skip()
            case "finish": timer.complete(silently: false)   // as if time ran out: alert + pop-up
            case "reset": timer.reset()
            case "droptarget": all.first?.openForDrop(); all.first?.model.dropTargeted = true
            case "history": shelf.setHistory(!shelf.historyOn)
            case "timer-state":
                NSLog("timer kind=\(timer.kind) run=\(timer.run) clock=\(timer.clock()) rounds=\(timer.focusRounds) awaiting=\(timer.awaitingFocus)")
            case "shelf-state":
                NSLog("shelf \(shelf.items.count) items: \(shelf.items.map { "\($0.kindLabel): \($0.title)" }) history=\(shelf.historyOn) allowed=\(shelf.historyAllowed)")
            case "collapse": all.forEach { $0.collapse() }
            case "peek": all.forEach { $0.peek() }
            case "allow": if let p = target?.permission { NSLog("allow → \(app.allow(p, always: false, answers: nil))") }
            case "deny": if let p = target?.permission { NSLog("deny → \(app.deny(p, note: "not now"))") }
            default:
                if command.hasPrefix("timer:"), let seconds = TimeInterval(command.dropFirst(6)) {
                    timer.page = .timer
                    timer.begin(.timer, seconds: seconds)
                } else if command.hasPrefix("shelf:") {
                    // shelf:text:<text> | shelf:file:<path> | shelf:image:<path> — dropped through the same path as a real drag.
                    let parts = command.split(separator: ":", maxSplits: 2).map(String.init)
                    guard parts.count == 3 else { return }
                    let pb = NSPasteboard(name: .init("ClaudeNotchDebugDrop"))
                    pb.clearContents()
                    switch parts[1] {
                    case "file": pb.writeObjects([URL(fileURLWithPath: parts[2]) as NSURL])
                    case "image": if let data = try? Data(contentsOf: URL(fileURLWithPath: parts[2])) { pb.setData(data, forType: .png) }
                    default: pb.setString(parts[2], forType: .string)
                    }
                    NSLog("drop → \(all.first?.drop(pb) ?? false)")
                } else if command.hasPrefix("detail") {
                    let id = command.hasPrefix("detail:") ? String(command.dropFirst(7)) : (target?.id ?? "")
                    if let s = store.sessions.first(where: { $0.id == id }) { all.first?.showDetail(s) }
                } else if command.hasPrefix("answer:"), let c = all.first, let s = target, let p = s.permission, let q = p.detail.questions.first {
                    c.model.picks[q.question] = [String(command.dropFirst(7))] // as if you clicked that option
                    c.answer(s, p)
                } else if command.hasPrefix("denynote:"), let c = all.first, let s = target, let p = s.permission {
                    c.model.note = String(command.dropFirst(9))
                    c.deny(s, p)
                } else if command.hasPrefix("reply:") {
                    let s = store.sessions.first { $0.canReply }
                    NSLog("reply → \(s.map { app.reply($0, text: String(command.dropFirst(6))) } ?? false)")
                } else if command.hasPrefix("film:"), let c = all.first {
                    // What the window server actually shows, frame by frame, while the notch opens or closes.
                    let parts = command.dropFirst(5).split(separator: ",")
                    let prefix = String(parts[0]), action = parts.count > 1 ? String(parts[1]) : "expand"
                    if action == "expand" { c.open() } else { c.collapse() }
                    for (i, ms) in [0, 30, 60, 100, 150, 220, 320, 450].enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(ms) / 1000) {
                            WindowShot.capture(c.panel, to: "\(prefix)-\(String(format: "%02d", i))-\(ms)ms.png")
                        }
                    }
                } else if command.hasPrefix("shot:"), let c = all.first {
                    WindowShot.capture(c.panel, to: String(command.dropFirst(5)))
                    NSLog("ClaudeNotch debug: shot \(command.dropFirst(5)) mode=\(c.model.mode)")
                } else if command == "measure", let c = all.first {
                    FrameProbe.run(on: c, open: c.model.mode == .collapsed)
                } else if command.hasPrefix("capture:") {
                    let prefix = String(command.dropFirst("capture:".count))
                    for (i, c) in all.enumerated() {
                        guard let view = c.panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                        view.cacheDisplay(in: view.bounds, to: rep)
                        let path = "\(prefix)-\(i).png"
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                        NSLog("ClaudeNotch debug: wrote \(path) mode=\(c.model.mode) ignoresMouse=\(c.panel.ignoresMouseEvents) key=\(c.panel.isKeyWindow) active=\(NSApp.isActive)")
                    }
                    for s in store.sessions {
                        NSLog("  [\(s.state)] \(s.title) status=\(s.status) outcome=\(s.outcome) ack=\(s.acknowledged) reply=\(s.canReply) perm=\(s.permission?.detail.summary ?? "-") | \(s.activity)")
                    }
                }
            }
        }
    }
}

/// Captures our own window as composited by the window server (no screen-recording permission is
/// needed for your own windows). The API is hidden from the current SDK, so it's looked up at runtime.
enum WindowShot {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let create: CreateImage? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
        .map { unsafeBitCast($0, to: CreateImage.self) }

    static func capture(_ window: NSWindow, to path: String) {
        // null rect, option "including window", image option "best resolution"
        guard let create, let image = create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 3)?.takeRetainedValue() else {
            NSLog("ClaudeNotch debug: window capture unavailable"); return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// Logs the notch's on-screen height at every display refresh during one open or close.
final class FrameProbe: NSObject {
    private static var current: FrameProbe?
    private var link: CADisplayLink?
    private var samples: [(t: CFTimeInterval, h: CGFloat)] = []
    private weak var layer: CAShapeLayer?
    private var start: CFTimeInterval = 0

    static func run(on controller: NotchController, open: Bool) {
        let probe = FrameProbe()
        probe.layer = controller.debugShapeLayer
        current = probe
        let link = controller.panel.contentView!.displayLink(target: probe, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        probe.link = link
        probe.start = CACurrentMediaTime()
        if open { controller.open() } else { controller.collapse() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { probe.finish() }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let h = layer?.presentation()?.path?.boundingBox.height ?? 0
        samples.append((link.timestamp, h))
    }

    private func finish() {
        link?.invalidate()
        let gaps = zip(samples.dropFirst(), samples).map { ($0.t - $1.t) * 1000 }
        let avg = gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count)
        let heights = samples.map { String(format: "%.0f", $0.h) }.joined(separator: " ")
        NSLog("ClaudeNotch probe: \(samples.count) frames, avg %.1f ms (%.0f fps), max gap %.1f ms", avg, avg > 0 ? 1000 / avg : 0, gaps.max() ?? 0)
        NSLog("ClaudeNotch probe heights: \(heights)")
        NSLog("ClaudeNotch probe screen max fps: \(NSScreen.main?.maximumFramesPerSecond ?? 0)")
        FrameProbe.current = nil
    }
}
#endif
