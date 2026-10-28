import AppKit
import Combine
import SwiftUI

/// Borderless panel that floats above the menu bar, on every Space and over full-screen apps.
final class NotchPanel: NSPanel {
    /// Only while a session's detail view is open (so you can type a reply).
    var allowsKey = false

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true // before `level`: setting this resets the level to .floating
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    // Never push the panel below the menu bar: it belongs over the notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class NotchHostingView: NSHostingView<NotchRootView> {
    var menuProvider: (() -> NSMenu)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

struct NotchGeometry {
    var hasNotch: Bool
    var width: CGFloat
    var height: CGFloat
    var midX: CGFloat
    var top: CGFloat

    init(screen: NSScreen) {
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            width = max(0, frame.width - left.width - right.width)
            height = screen.safeAreaInsets.top
            midX = frame.minX + left.width + width / 2
        } else {
            hasNotch = false
            width = 0
            let menuBar = frame.maxY - screen.visibleFrame.maxY
            height = menuBar > 4 ? menuBar : 24
            midX = frame.midX
        }
        top = frame.maxY
    }
}

/// What a display's notch needs from the app (shared hooks and sessions).
protocol AppActions: AnyObject {
    func jump(to session: ClaudeSession)
    func allow(_ request: PendingPermission, always: Bool, answers: [String: String]?) -> Bool
    func deny(_ request: PendingPermission, note: String) -> Bool
    func reply(_ session: ClaudeSession, text: String) -> Bool
    func acknowledge(_ ids: [String])
    func makeMenu() -> NSMenu
}

/// Owns the panel on one display and decides when it opens and closes.
final class NotchController: NotchActions {
    let screen: NSScreen
    let store: SessionStore
    let model: NotchModel
    let panel: NotchPanel
    private weak var app: AppActions?
    private let geometry: NotchGeometry
    private let shadowPad: CGFloat = 40

    private let container: NotchContainerView
    private var shownSize: CGSize = .zero
    private var bag = Set<AnyCancellable>()

    private var hoverStart: Date?
    private var leaveStart: Date?
    private var peekUntil: Date?
    private var peekArmed = false
    private var previousApp: NSRunningApplication?

    /// How long the pointer rests on the notch before it opens, how long it may wander off before it
    /// closes, and how long a pop-up stays.
    private static let hoverDelay: TimeInterval = 0.07
    private static let leaveDelay: TimeInterval = 0.22
    private static let peekDuration: TimeInterval = 4

    init(screen: NSScreen, store: SessionStore, app: AppActions) {
        self.screen = screen
        self.store = store
        self.app = app
        geometry = NotchGeometry(screen: screen)
        model = NotchModel(hasNotch: geometry.hasNotch, notchWidth: geometry.width, notchHeight: geometry.height)

        let maxBody = model.maxBodySize
        let size = NSSize(width: maxBody.width + 2 * shadowPad, height: maxBody.height + shadowPad)
        let frame = NSRect(x: geometry.midX - size.width / 2, y: geometry.top - size.height, width: size.width, height: size.height)
        panel = NotchPanel(frame: frame)

        let host = NotchHostingView(rootView: NotchRootView(store: store, model: model))
        host.sizingOptions = []
        host.menuProvider = { [weak app] in app?.makeMenu() ?? NSMenu() }
        container = NotchContainerView(frame: NSRect(origin: .zero, size: size), host: host)
        panel.contentView = container
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        model.actions = self

        // The shape follows the mode and the session list; Core Animation does the moving.
        reshape(mode: model.mode, sessions: store.sessions, animated: false)
        model.$mode.combineLatest(store.$sessions)
            .sink { [weak self] mode, sessions in self?.reshape(mode: mode, sessions: sessions, animated: true) }
            .store(in: &bag)
    }

    private func reshape(mode: NotchModel.Mode, sessions: [ClaudeSession], animated: Bool) {
        let size = model.bodySize(sessions, mode: mode)
        guard size != shownSize || !animated else { return }
        let opening = size.width * size.height > shownSize.width * shownSize.height
        shownSize = size
        let bounds = container.bounds
        let body = CGRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height, width: size.width, height: size.height)
        let open = mode != .collapsed
        container.setShape(body: body, topRadius: open ? 14 : 7, bottomRadius: open ? 24 : 10,
                           growing: opening, raised: open, animated: animated)
    }

    #if DEBUG
    var debugShapeLayer: CAShapeLayer? { container.debugShapeLayer }
    #endif

    /// Re-check the pointer once a hover or leave delay has passed (mouse events alone may not come).
    private func recheck(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.01) { [weak self] in
            self?.update(mouse: NSEvent.mouseLocation)
        }
    }

    func teardown() {
        collapse()
        panel.orderOut(nil)
    }

    /// The black body on screen, in global coordinates.
    private var bodyRect: NSRect {
        let size = model.bodySize(store.sessions)
        return NSRect(x: geometry.midX - size.width / 2, y: geometry.top - size.height, width: size.width, height: size.height)
    }

    private var detailID: String? {
        if case .detail(let id) = model.mode { return id }
        return nil
    }

    // MARK: - Pointer and keyboard

    func update(mouse p: NSPoint, now: Date = Date()) {
        let body = bodyRect
        let inside: Bool
        if body.width <= 0 {
            inside = false
        } else if model.isOpen {
            inside = body.insetBy(dx: -8, dy: -8).contains(p)
        } else {
            // Slightly generous so a flick to the top edge still counts.
            inside = NSRect(x: body.minX - 4, y: body.minY - 2, width: body.width + 8, height: body.height + 4).contains(p)
        }
        panel.ignoresMouseEvents = !inside

        switch model.mode {
        case .collapsed:
            if inside {
                if hoverStart == nil { hoverStart = now; recheck(after: Self.hoverDelay) }
                if let start = hoverStart, now.timeIntervalSince(start) >= Self.hoverDelay { open() }
            } else {
                hoverStart = nil
            }
        case .peek:
            if NotchModel.peekList(store.sessions).isEmpty { return collapse() }
            // A peek that pops up under a resting pointer must not grab its clicks:
            // it only becomes interactive once the pointer has left and comes back.
            if !peekArmed {
                if !inside { peekArmed = true }
                panel.ignoresMouseEvents = true
            } else if inside {
                return open()
            }
            // A notification: a few seconds, then back into the notch. The coloured dot stays until you look.
            if let until = peekUntil, now >= until { collapse() }
        case .expanded:
            if inside {
                leaveStart = nil
            } else {
                if leaveStart == nil { leaveStart = now; recheck(after: Self.leaveDelay) }
                if let start = leaveStart, now.timeIntervalSince(start) >= Self.leaveDelay { collapse() }
            }
        case .detail:
            break // pinned: closes with Esc, ✕, or a click outside
        }
    }

    /// A click anywhere on screen (outside our panel, while we listen globally).
    func mouseDown(at p: NSPoint) {
        guard detailID != nil, !bodyRect.insetBy(dx: -4, dy: -4).contains(p) else { return }
        collapse(restoreFocus: false) // the click itself brings its app forward
    }

    func keyDown(_ event: NSEvent) -> Bool {
        guard detailID != nil, event.keyCode == 53 else { return false } // Esc
        back()
        return true
    }

    // MARK: - Modes

    func open() {
        guard model.mode != .expanded else { return }
        model.mode = .expanded
        leaveStart = nil
        peekUntil = nil
    }

    func peek() {
        guard model.mode == .collapsed || model.mode == .peek else { return }
        model.mode = .peek
        peekUntil = Date().addingTimeInterval(Self.peekDuration)
        peekArmed = !bodyRect.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
        recheck(after: Self.peekDuration)
    }

    func collapse(restoreFocus: Bool = true) {
        leaveDetail(restoreFocus: restoreFocus)
        model.mode = .collapsed
        hoverStart = nil
        leaveStart = nil
        peekUntil = nil
    }

    private func leaveDetail(restoreFocus: Bool) {
        guard let id = detailID else { return }
        // Reading a finished session counts as seeing it; questions and errors stay until you act.
        if let s = store.sessions.first(where: { $0.id == id }), s.state == .done { app?.acknowledge([id]) }
        model.resetInput()
        guard panel.allowsKey else { return }
        panel.allowsKey = false
        if restoreFocus, NSApp.isActive {
            if let previous = previousApp, !previous.isTerminated { previous.activate() } else { NSApp.deactivate() }
        }
        previousApp = nil
    }

    // MARK: - NotchActions

    func showDetail(_ s: ClaudeSession) {
        if detailID == nil {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        }
        model.resetInput()
        model.mode = .detail(s.id)
        // Become key so you can type; give focus back when the detail closes.
        panel.allowsKey = true
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func back() {
        leaveDetail(restoreFocus: true)
        model.mode = .expanded
        leaveStart = nil
    }

    func close() {
        collapse()
    }

    func open(_ s: ClaudeSession) {
        app?.acknowledge([s.id])
        collapse(restoreFocus: false)
        app?.jump(to: s)
    }

    func allow(_ s: ClaudeSession, _ request: PendingPermission, always: Bool) {
        guard model.canAnswer(request) else { return }
        let answers = request.detail.kind == .question ? collectedAnswers(request) : nil
        let ok = app?.allow(request, always: always, answers: answers) ?? false
        finish(ok ? (request.detail.kind == .plan ? "Plan approved" : "Allowed") : "Already answered elsewhere")
    }

    func deny(_ s: ClaudeSession, _ request: PendingPermission) {
        guard model.canAnswer(request) else { return }
        let ok = app?.deny(request, note: model.note) ?? false
        let done = [PermissionDetail.Kind.plan: "Sent back to planning", .question: "Skipped"][request.detail.kind] ?? "Denied"
        finish(ok ? done : "Already answered elsewhere")
    }

    func answer(_ s: ClaudeSession, _ request: PendingPermission) {
        allow(s, request, always: false)
    }

    func reply(_ s: ClaudeSession, text: String) {
        let ok = app?.reply(s, text: text) ?? false
        if ok { app?.acknowledge([s.id]) }
        finish(ok ? "Sent to Claude" : "This session isn't waiting for a reply anymore")
    }

    func dismiss(_ s: ClaudeSession) {
        app?.acknowledge([s.id])
    }

    func clearAll() {
        app?.acknowledge(store.sessions.filter { $0.needsAttention && $0.permission == nil && $0.status == "idle" }.map(\.id))
    }

    func newSession() {
        collapse(restoreFocus: false)
        Jumper.newSession()
    }

    func showMenu() {
        guard let view = panel.contentView, let menu = app?.makeMenu() else { return }
        let point = view.convert(panel.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    private func collectedAnswers(_ request: PendingPermission) -> [String: String] {
        var answers: [String: String] = [:]
        for q in request.detail.questions {
            let own = (model.other[q.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let picked = (model.picks[q.question] ?? []).joined(separator: ", ")
            answers[q.question] = own.isEmpty ? picked : own
        }
        return answers
    }

    /// Show what happened for a moment, then go back to the list.
    private func finish(_ message: String) {
        if detailID == nil { return } // quick action from the list: the row updates by itself
        model.flash = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, self.detailID != nil else { return }
            self.back()
        }
    }
}
