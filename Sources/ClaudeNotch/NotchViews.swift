import SwiftUI

enum Palette {
    static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)   // Claude orange: working
    static let yellow = Color(red: 1.0, green: 0.80, blue: 0.25)       // needs you
    static let red = Color(red: 1.0, green: 0.40, blue: 0.38)          // error
    static let green = Color(red: 0.32, green: 0.83, blue: 0.53)       // done
    static let idle = Color.white.opacity(0.32)

    static func color(_ state: SessionState) -> Color {
        switch state {
        case .needsInput: return yellow
        case .error: return red
        case .done: return green
        case .working: return claude
        case .idle: return idle
        }
    }
}

/// What the views ask their display's controller to do.
protocol NotchActions: AnyObject {
    func showDetail(_ s: ClaudeSession)
    func back()
    func close()
    func open(_ s: ClaudeSession)
    // Each carries the request the view showed, so a click can only answer what you saw.
    func allow(_ s: ClaudeSession, _ request: PendingPermission, always: Bool)
    func deny(_ s: ClaudeSession, _ request: PendingPermission)
    func answer(_ s: ClaudeSession, _ request: PendingPermission)
    func reply(_ s: ClaudeSession, text: String)
    func dismiss(_ s: ClaudeSession)
    func clearAll()
    func newSession()
    func showMenu()
    func select(_ tab: NotchModel.Tab)
}

// MARK: - Model (one per display)

final class NotchModel: ObservableObject {
    enum Mode: Equatable { case collapsed, peek, timerPeek, expanded, detail(String) }
    enum Tab: String { case claude, timer, shelf }

    @Published var mode: Mode = .collapsed
    @Published var tab: Tab = .claude
    @Published var dropTargeted = false              // a drag is over the open shelf
    @Published var timerEvent: TimerStore.Finish?    // what the timer pop-up is about
    @Published var hoveredRow: String?
    // Detail view input.
    @Published var draft = ""
    @Published var note = ""                       // deny reason / plan feedback
    @Published var picks: [String: [String]] = [:] // question → chosen option labels
    @Published var other: [String: String] = [:]  // question → your own answer
    @Published var flash: String?                  // "Allowed" etc.
    /// Requests that have been on screen long enough to be answered (see `arm`).
    @Published private(set) var armed = Set<String>()
    private var arming = Set<String>()

    weak var actions: NotchActions?

    let hasNotch: Bool
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let timer: TimerStore
    let shelf: ShelfStore

    static let rowHeight: CGFloat = 52
    static let maxRows = 7
    static let maxPeekRows = 3
    static let listPadding: CGFloat = 8
    static let maxDots = 4
    static let detailHeight: CGFloat = 520
    static let timerHeight: CGFloat = 214
    static let timerPeekHeight: CGFloat = 62

    init(hasNotch: Bool, notchWidth: CGFloat, notchHeight: CGFloat, timer: TimerStore, shelf: ShelfStore) {
        self.hasNotch = hasNotch
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.timer = timer
        self.shelf = shelf
    }

    var isOpen: Bool { mode != .collapsed }
    var bandHeight: CGFloat { max(notchHeight, 32) }
    var openWidth: CGFloat { max(620, notchWidth + 400) }
    var topRadius: CGFloat { isOpen ? 14 : 7 }

    /// A request's buttons work only after it has been visible for a moment, like macOS security
    /// prompts, so a double-click can't answer the next request before you've seen it.
    func arm(_ request: PendingPermission) {
        let id = request.requestId
        guard !armed.contains(id), !arming.contains(id) else { return }
        arming.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.arming.remove(id)
            self?.armed.insert(id)
        }
    }

    func canAnswer(_ request: PendingPermission) -> Bool {
        armed.contains(request.requestId) && flash == nil
    }

    func resetInput() {
        draft = ""
        note = ""
        picks = [:]
        other = [:]
        flash = nil
    }

    static func peekList(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        Array(sessions.filter(\.needsAttention).sorted { $0.statusSince > $1.statusSince }.prefix(maxPeekRows))
    }

    /// A running timer (or a Pomodoro waiting for its next round) shows beside the notch.
    var timerInEar: Bool { timer.isActive || timer.awaitingFocus }

    func earWidth(_ sessions: [ClaudeSession]) -> CGFloat {
        let dots = min(sessions.filter { $0.state != .idle }.count, Self.maxDots)
        let right: CGFloat = dots == 0 ? 30 : 20 + CGFloat(dots) * 6 + CGFloat(dots - 1) * 4
        // The countdown's width is fixed per format ("24:13" or "1:02:03") so the ears never jitter.
        let left: CGFloat = !timerInEar ? 0 : !timer.isActive ? 70 : timer.duration >= 3600 ? 88 : 72
        return max(36, right, left)
    }

    var shelfHeight: CGFloat { 172 + (shelf.historyOn && !shelf.historyAllowed ? 34 : 0) }

    /// Size of the black body (without the flared top corners).
    func bodySize(_ sessions: [ClaudeSession], mode: Mode? = nil) -> CGSize {
        switch mode ?? self.mode {
        case .collapsed:
            if sessions.isEmpty && !timerInEar { return CGSize(width: hasNotch ? notchWidth : 0, height: notchHeight) }
            return CGSize(width: notchWidth + 2 * earWidth(sessions), height: notchHeight)
        case .timerPeek:
            return CGSize(width: openWidth, height: bandHeight + Self.timerPeekHeight)
        case .peek:
            let rows = max(1, Self.peekList(sessions).count)
            return CGSize(width: openWidth, height: bandHeight + CGFloat(rows) * Self.rowHeight + 2 * Self.listPadding)
        case .expanded:
            switch tab {
            case .claude:
                let rows = max(1, min(sessions.count, Self.maxRows))
                return CGSize(width: openWidth, height: bandHeight + CGFloat(rows) * Self.rowHeight + 2 * Self.listPadding)
            case .timer:
                return CGSize(width: openWidth, height: bandHeight + (timer.page == .pomodoro ? Self.timerHeight : Self.timerHeight - 30))
            case .shelf:
                return CGSize(width: openWidth, height: bandHeight + shelfHeight)
            }
        case .detail(let id):
            return CGSize(width: openWidth, height: detailHeight(sessions.first { $0.id == id }))
        }
    }

    /// Tall enough for what the detail shows, so short requests get a compact card.
    func detailHeight(_ s: ClaudeSession?) -> CGFloat {
        guard let s else { return bandHeight + 120 }
        let textWidth = openWidth - 60
        func lines(_ text: String, size: CGFloat) -> CGFloat {
            let perLine = max(20, textWidth / (size * 0.52))
            return text.components(separatedBy: "\n").reduce(0) { $0 + max(1, ceil(CGFloat($1.count) / perLine)) }
        }
        var content: CGFloat
        if let p = s.permission {
            let d = p.detail
            content = 26 + (d.note?.isEmpty == false ? 22 : 0)
            switch d.kind {
            case .question:
                content += d.questions.reduce(0) { $0 + 30 + CGFloat($1.options.count) * 46 + 34 }
            case .plan:
                content += lines(d.plan ?? "", size: 12.5) * 18 + 26
            case .edit:
                content += min(220, CGFloat(d.diff.count) * 16 + 14)
            default:
                content += min(190, lines(d.body, size: 11.5) * 16 + 22)
            }
        } else if s.status == "waiting" {
            content = 110
        } else if s.state == .working {
            content = 30 + CGFloat(s.steps.count) * 24 + 26
        } else {
            content = lines(s.message.isEmpty ? s.activity : s.message, size: 12.5) * 18 + 30
            if s.ask != nil { content += 30 + (s.actions.isEmpty ? 0 : 34) }
            if case .error = s.outcome { content += 26 }
        }
        let chrome: CGFloat = 50 + (s.lastPrompt.isEmpty ? 0 : 34) + 64
        return min(Self.detailHeight, max(bandHeight + 200, bandHeight + chrome + content))
    }

    /// Largest the body can get; the window is sized for this plus room for the shadow.
    var maxBodySize: CGSize {
        let list = bandHeight + CGFloat(Self.maxRows) * Self.rowHeight + 2 * Self.listPadding
        return CGSize(width: openWidth, height: max(list, Self.detailHeight))
    }
}

// MARK: - Shapes and icons

/// The notch silhouette: flared top corners that melt into the bezel, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius
        let b = max(0, min(bottomRadius, rect.height - t, (rect.width - 2 * t) / 2))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// A Claude-style starburst.
struct SparkShape: Shape {
    var rays = 10

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let width = radius * 0.30
        var p = Path()
        for i in 0..<rays {
            let length = i % 2 == 0 ? radius : radius * 0.74
            let ray = Path(roundedRect: CGRect(x: -width / 2, y: -length, width: width, height: length + width * 0.2),
                           cornerRadius: width / 2)
            let angle = CGFloat(i) / CGFloat(rays) * 2 * .pi
            p.addPath(ray, transform: CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle))
        }
        return p
    }
}

struct Spark: View {
    var color: Color
    var spinning: Bool
    var pulsing = false

    /// Set by the snapshot renderer, which cannot draw AppKit views.
    static var staticRendering = false

    var body: some View {
        if Self.staticRendering {
            SparkShape().fill(color)
        } else {
            SparkLayer(color: NSColor(color), spinning: spinning, pulsing: pulsing)
        }
    }
}

/// The spark drawn and animated by Core Animation, so a spinning icon costs the app almost no CPU.
struct SparkLayer: NSViewRepresentable {
    var color: NSColor
    var spinning: Bool
    var pulsing: Bool

    func makeNSView(context: Context) -> SparkNSView { SparkNSView() }

    func updateNSView(_ view: SparkNSView, context: Context) {
        view.shape.fillColor = color.cgColor
        view.spinning = spinning
        view.pulsing = pulsing
    }
}

final class SparkNSView: NSView {
    let shape = CAShapeLayer()
    var spinning = false { didSet { if spinning != oldValue { updateAnimations() } } }
    var pulsing = false { didSet { if pulsing != oldValue { updateAnimations() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Clicks belong to the SwiftUI view around the icon.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.bounds = bounds
        shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
        shape.path = SparkShape().path(in: bounds).cgPath
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimations()
    }

    private func updateAnimations() {
        if spinning {
            if shape.animation(forKey: "spin") == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = -2 * Double.pi
                spin.duration = 3
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                shape.add(spin, forKey: "spin")
            }
        } else {
            shape.removeAnimation(forKey: "spin")
        }
        if pulsing {
            if shape.animation(forKey: "pulse") == nil {
                let pulse = CABasicAnimation(keyPath: "transform.scale")
                pulse.fromValue = 1
                pulse.toValue = 0.78
                pulse.duration = 0.6
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                pulse.isRemovedOnCompletion = false
                shape.add(pulse, forKey: "pulse")
            }
        } else {
            shape.removeAnimation(forKey: "pulse")
        }
    }
}

struct StatusIcon: View {
    let state: SessionState
    var size: CGFloat = 16

    var body: some View {
        switch state {
        case .working:
            Spark(color: Palette.claude, spinning: true).frame(width: size, height: size)
        case .needsInput:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: size * 0.88, weight: .semibold))
                .foregroundStyle(Palette.yellow)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: size * 0.88, weight: .semibold))
                .foregroundStyle(Palette.red)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Palette.green)
        case .idle:
            SparkShape().fill(Palette.idle).frame(width: size * 0.8, height: size * 0.8)
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

extension ClaudeSession {
    var badge: (String, Color)? {
        switch state {
        case .needsInput:
            if permission?.detail.kind == .question { return ("Question", Palette.yellow) }
            if permission?.detail.kind == .plan { return ("Review plan", Palette.yellow) }
            if permission != nil || status == "waiting" { return ("Needs approval", Palette.yellow) }
            return ("Needs reply", Palette.yellow)
        case .error: return ("Error", Palette.red)
        case .done: return ("Done", Palette.green)
        case .working, .idle: return nil
        }
    }
}

/// Small capsule buttons used across the notch.
struct PillButton: View {
    enum Style { case primary(Color), secondary, destructive }
    let title: String
    var style: Style = .secondary
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(background))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private var foreground: Color {
        switch style {
        case .primary: return .black
        case .secondary: return .white.opacity(0.9)
        case .destructive: return Palette.red
        }
    }

    private var background: Color {
        switch style {
        case .primary(let color): return color
        case .secondary: return .white.opacity(0.12)
        case .destructive: return Palette.red.opacity(0.16)
        }
    }
}

// MARK: - Root

/// Content only: the black shape and its animation live in Core Animation (NotchContainerView).
/// Each state is laid out once at its final size and revealed through the shape's mask, with a quick
/// fade, so text never runs ahead of the box when opening or lags behind it when closing.
struct NotchRootView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var model: NotchModel
    @ObservedObject var timer: TimerStore
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        let sessions = store.sessions
        let size = model.bodySize(sessions)
        ZStack(alignment: .top) {
            if Spark.staticRendering { // snapshots have no Core Animation layer behind them
                NotchShape(topRadius: model.topRadius, bottomRadius: model.isOpen ? 24 : 10)
                    .fill(Color.black)
                    .frame(width: size.width + 2 * model.topRadius, height: size.height)
            }
            switch model.mode {
            case .collapsed:
                CollapsedContent(model: model, timer: timer, sessions: sessions)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .transition(.notchEars)
            case .timerPeek:
                VStack(spacing: 0) {
                    PanelHeader(model: model, timer: timer, shelf: shelf, sessions: sessions).frame(height: model.bandHeight)
                    TimerPeekCard(model: model, timer: timer)
                }
                .frame(width: size.width, height: size.height, alignment: .top)
                .transition(.notchPanel)
            case .peek:
                OpenContent(model: model, sessions: NotchModel.peekList(sessions), all: sessions)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .transition(.notchPanel)
            case .expanded:
                switch model.tab {
                case .claude:
                    OpenContent(model: model, sessions: sessions, all: sessions)
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .transition(.notchPanel)
                case .timer:
                    VStack(spacing: 0) {
                        PanelHeader(model: model, timer: timer, shelf: shelf, sessions: sessions).frame(height: model.bandHeight)
                        TimerPage(model: model, timer: timer)
                    }
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .transition(.notchPanel)
                case .shelf:
                    VStack(spacing: 0) {
                        PanelHeader(model: model, timer: timer, shelf: shelf, sessions: sessions).frame(height: model.bandHeight)
                        ShelfPage(model: model, shelf: shelf)
                    }
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .transition(.notchPanel)
                }
            case .detail(let id):
                DetailContent(model: model, session: sessions.first { $0.id == id })
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .transition(.notchPanel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}

extension AnyTransition {
    /// Panel content: revealed by the growing shape as it fades in, gone at once when the box closes.
    static var notchPanel: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                .animation(.easeOut(duration: 0.16)),
            removal: .opacity.animation(.easeIn(duration: 0.07)))
    }

    /// The ears beside the notch: back once the box has nearly closed.
    static var notchEars: AnyTransition {
        .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.14).delay(0.1)),
                    removal: .opacity.animation(.easeIn(duration: 0.04)))
    }
}

// MARK: - Collapsed: ears beside the notch

struct CollapsedContent: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var timer: TimerStore
    let sessions: [ClaudeSession]

    var body: some View {
        let ear = model.earWidth(sessions)
        // Most urgent colour wins; the spark spins whenever anything is working.
        let top = sessions.map(\.state).min { $0.rawValue < $1.rawValue } ?? .idle
        let working = sessions.contains { $0.state == .working }
        let active = sessions.filter { $0.state != .idle }
        HStack(spacing: 0) {
            if !sessions.isEmpty || model.timerInEar {
                Group {
                    if model.timerInEar {
                        TimerEar(timer: timer)
                    } else {
                        Spark(color: Palette.color(top), spinning: working, pulsing: top == .needsInput)
                            .frame(width: 15, height: 15)
                    }
                }
                .frame(width: ear)
                Color.clear.frame(width: model.notchWidth)
                Group {
                    if sessions.isEmpty {
                        if timer.isActive { TimerRing(timer: timer) }
                    } else if active.isEmpty {
                        Text("\(sessions.count)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.idle)
                    } else {
                        HStack(spacing: 4) {
                            ForEach(active.prefix(NotchModel.maxDots)) { s in
                                Circle().fill(Palette.color(s.state)).frame(width: 6, height: 6)
                            }
                        }
                    }
                }
                .frame(width: ear)
            }
        }
        .frame(height: model.notchHeight)
        .contentShape(Rectangle())
        .onTapGesture { model.mode = .expanded }
    }
}

// MARK: - Open: header band + session list

struct OpenContent: View {
    @ObservedObject var model: NotchModel
    let sessions: [ClaudeSession]
    let all: [ClaudeSession]

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: model.bandHeight)
            if sessions.isEmpty {
                EmptyRow { model.actions?.newSession() }
                    .frame(height: NotchModel.rowHeight)
                    .padding(NotchModel.listPadding)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if sessions.count > NotchModel.maxRows {
                        ScrollView(.vertical, showsIndicators: false) { rows(context.date) }
                    } else {
                        rows(context.date)
                    }
                }
                .padding(.horizontal, NotchModel.listPadding)
                .padding(.vertical, NotchModel.listPadding)
            }
        }
    }

    private func rows(_ now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(sessions) { s in
                SessionRow(model: model, session: s, now: now, hovering: model.hoveredRow == s.id)
                    .frame(height: NotchModel.rowHeight)
                    .onHover { inside in
                        if inside { model.hoveredRow = s.id } else if model.hoveredRow == s.id { model.hoveredRow = nil }
                    }
            }
        }
    }

    private var header: some View {
        PanelHeader(model: model, timer: model.timer, shelf: model.shelf, sessions: all)
    }
}

/// "● 1  ● 2  ● 1" — how many sessions are in each state, in their colours.
struct SummaryChips: View {
    let sessions: [ClaudeSession]

    var body: some View {
        let states: [(SessionState, String)] = [(.needsInput, "need you"), (.error, "failed"), (.working, "working"), (.done, "done")]
        let counts = states.map { state, label in (state, label, sessions.filter { $0.state == state }.count) }.filter { $0.2 > 0 }
        HStack(spacing: 8) {
            if counts.isEmpty {
                Text(sessions.isEmpty ? "No sessions" : "\(sessions.count) idle")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            ForEach(counts, id: \.0) { state, label, count in
                HStack(spacing: 4) {
                    Circle().fill(Palette.color(state)).frame(width: 6, height: 6)
                    Text("\(count)").font(.system(size: 11.5, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                }
                .help("\(count) \(label)")
            }
        }
        .fixedSize()
    }
}

struct SessionRow: View {
    @ObservedObject var model: NotchModel
    let session: ClaudeSession
    let now: Date
    let hovering: Bool

    var body: some View {
        let state = session.state
        HStack(spacing: 11) {
            StatusIcon(state: state).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(state == .idle ? 0.72 : 0.96))
                        .lineLimit(1)
                    if let (text, color) = session.badge { Badge(text: text, color: color) }
                }
                Text(session.title == session.project ? session.activity : "\(session.project) · \(session.activity)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(session.needsAttention ? 0.72 : 0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.09) : session.needsAttention ? Palette.color(state).opacity(0.07) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.actions?.showDetail(session) }
        .help(session.lastPrompt.isEmpty ? session.cwd : "You: \(session.lastPrompt)")
    }

    @ViewBuilder private var trailing: some View {
        if let p = session.permission {
            HStack(spacing: 6) {
                // Quick answers only for requests the row shows in full; the rest open the detail card.
                if p.detail.kind == .command && !p.detail.body.contains("\n") || p.detail.kind == .fetch {
                    PillButton(title: "Deny", style: .destructive, enabled: model.canAnswer(p)) { model.actions?.deny(session, p) }
                    PillButton(title: "Allow", style: .primary(Palette.green), enabled: model.canAnswer(p)) { model.actions?.allow(session, p, always: false) }
                } else {
                    PillButton(title: "Review", style: .primary(Palette.yellow)) { model.actions?.showDetail(session) }
                }
            }
            .onAppear { model.arm(p) }
            .onChange(of: p.requestId) { model.arm(p) }
        } else if hovering, session.needsAttention, session.permission == nil, session.status == "idle" {
            Button { model.actions?.dismiss(session) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("Mark as seen")
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                Text(elapsed(session, now))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(session.state == .idle ? Color.white.opacity(0.35) : Palette.color(session.state))
                Image(systemName: session.isDesktop ? "macwindow" : "terminal")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }
}

func elapsed(_ session: ClaudeSession, _ now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(session.statusSince)))
    let text: String
    switch seconds {
    case ..<60: text = "\(seconds)s"
    case ..<3600: text = "\(seconds / 60)m"
    case ..<86400: text = "\(seconds / 3600)h"
    default: text = "\(seconds / 86400)d"
    }
    return session.status == "idle" && session.permission == nil ? text + " ago" : text
}

struct EmptyRow: View {
    let onNew: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            SparkShape().fill(Palette.idle).frame(width: 14, height: 14)
            Text("No Claude Code sessions running")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            PillButton(title: "New session", style: .primary(Palette.claude), action: onNew)
        }
        .padding(.horizontal, 14)
    }
}

// MARK: - Detail: one session, everything you can do with it

struct DetailContent: View {
    @ObservedObject var model: NotchModel
    let session: ClaudeSession?

    var body: some View {
        VStack(spacing: 0) {
            band.frame(height: model.bandHeight)
            if let session {
                DetailBody(model: model, session: session)
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
            } else {
                VStack(spacing: 10) {
                    Text("This session has ended.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    PillButton(title: "Back to all sessions") { model.actions?.back() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .top) {
            if let flash = model.flash {
                Text(flash)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Palette.green))
                    .padding(.top, model.bandHeight + 4)
                    .transition(.opacity)
            }
        }
    }

    private var band: some View {
        let side = max(0, (model.openWidth - model.notchWidth) / 2)
        return HStack(spacing: 0) {
            HStack {
                Button { model.actions?.back() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        Text("All sessions").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(.leading, 20)
            .frame(width: side)

            Color.clear.frame(width: model.notchWidth)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if let session {
                    Button { model.actions?.open(session) } label: {
                        HStack(spacing: 4) {
                            Text("Open").font(.system(size: 12, weight: .semibold))
                            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(.white.opacity(0.75))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open in \(session.hostName)")
                }
                Button { model.actions?.close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 16)
            .frame(width: side)
        }
    }
}

struct DetailBody: View {
    @ObservedObject var model: NotchModel
    let session: ClaudeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !session.lastPrompt.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("You").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.45))
                    Text(session.lastPrompt).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusIcon(state: session.state, size: 18).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(session.project) · \(session.hostName) · \(elapsed(session, context.date))")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            Spacer()
            if let (text, color) = session.badge { Badge(text: text, color: color) }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let p = session.permission {
            PermissionView(model: model, permission: p)
        } else if session.status == "waiting" {
            InfoBox(color: Palette.yellow, title: "Waiting for you in the \(session.hostName)",
                    text: session.activity + "\n\nThis request started before the notch could catch it. Answer it there, or open it with the button above.")
        } else if session.state == .working {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Spark(color: Palette.claude, spinning: true).frame(width: 13, height: 13)
                    Text(session.activity).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                }
                StepsView(steps: session.steps)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if case .error(let label) = session.outcome {
                    InfoBox(color: Palette.red, title: label, text: session.message == label ? "" : session.message)
                } else {
                    MessageBox(text: session.message.isEmpty ? session.activity : session.message)
                }
                if let ask = session.ask {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(ask).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.yellow)
                        if !session.actions.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(session.actions, id: \.self) { action in
                                    PillButton(title: action.label, style: action == session.actions.first ? .primary(Palette.yellow) : .secondary,
                                               enabled: session.canReply) {
                                        model.actions?.reply(session, text: action.message)
                                    }
                                    .help(action.message)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        if let p = session.permission {
            let ready = model.canAnswer(p)
            Group {
                switch p.detail.kind {
                case .question:
                    HStack(spacing: 8) {
                        Spacer()
                        PillButton(title: "Skip", style: .destructive, enabled: ready) { model.actions?.deny(session, p) }
                        PillButton(title: "Send answers", style: .primary(Palette.yellow), enabled: ready && allAnswered(p)) { model.actions?.answer(session, p) }
                    }
                case .plan:
                    HStack(spacing: 8) {
                        inputField("What should change? (optional)", text: $model.note) {}
                        PillButton(title: "Keep planning", style: .destructive, enabled: ready) { model.actions?.deny(session, p) }
                        PillButton(title: "Approve plan", style: .primary(Palette.green), enabled: ready) { model.actions?.allow(session, p, always: false) }
                    }
                default:
                    HStack(spacing: 8) {
                        inputField("Optional: tell Claude what to do instead", text: $model.note) { if ready { model.actions?.deny(session, p) } }
                        PillButton(title: "Deny", style: .destructive, enabled: ready) { model.actions?.deny(session, p) }
                        if let always = p.alwaysLabel {
                            PillButton(title: always, enabled: ready) { model.actions?.allow(session, p, always: true) }
                        }
                        PillButton(title: "Allow", style: .primary(Palette.green), enabled: ready) { model.actions?.allow(session, p, always: false) }
                    }
                }
            }
            .onAppear { model.arm(p) }
            .onChange(of: p.requestId) { model.arm(p) }
        } else if session.status == "idle", case .error = session.outcome, !session.canReply {
            HStack(spacing: 8) {
                Text("Claude stopped on an error. Retry from the session itself.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button("Mark as seen") { model.actions?.dismiss(session) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                PillButton(title: "Open to retry", style: .primary(Palette.red)) { model.actions?.open(session) }
            }
        } else if session.status == "idle" {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    inputField(session.canReply ? "Reply to Claude, or tell it what to do next…" : "Replying from the notch opens after this session's next turn",
                               text: $model.draft, enabled: session.canReply) { send() }
                    PillButton(title: "Send", style: .primary(Palette.claude), enabled: session.canReply && !model.draft.trimmingCharacters(in: .whitespaces).isEmpty) { send() }
                }
                if session.needsAttention {
                    Button("Mark as seen") { model.actions?.dismiss(session) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        } else if session.state == .working {
            Text("You can reply here as soon as Claude finishes.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private func send() {
        guard session.canReply else { return }
        model.actions?.reply(session, text: model.draft)
    }

    private func allAnswered(_ p: PendingPermission) -> Bool {
        p.detail.questions.allSatisfy { q in
            !(model.picks[q.question] ?? []).isEmpty || !(model.other[q.question] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func inputField(_ placeholder: String, text: Binding<String>, enabled: Bool = true, onSubmit: @escaping () -> Void) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(enabled ? 0.09 : 0.04)))
            .disabled(!enabled)
            .onSubmit(onSubmit)
    }
}

struct PermissionView: View {
    @ObservedObject var model: NotchModel
    let permission: PendingPermission

    var body: some View {
        let d = permission.detail
        VStack(alignment: .leading, spacing: 8) {
            Text(d.kind == .question || d.kind == .plan ? d.title : "Wants to: \(d.title)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.yellow)
            if let note = d.note, !note.isEmpty, d.kind != .plan {
                Text(note).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(3)
            }
            switch d.kind {
            case .question:
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(d.questions, id: \.self) { q in QuestionView(model: model, question: q) }
                    }
                }
            case .plan:
                MessageBox(text: d.plan ?? "")
            case .edit:
                DiffView(lines: d.diff)
            default:
                CodeBox(text: d.body)
            }
        }
    }
}

struct QuestionView: View {
    @ObservedObject var model: NotchModel
    let question: AskQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.question).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
            ForEach(question.options, id: \.self) { option in
                let chosen = (model.picks[question.question] ?? []).contains(option.label)
                Button { toggle(option.label) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: question.multiSelect ? (chosen ? "checkmark.square.fill" : "square") : (chosen ? "largecircle.fill.circle" : "circle"))
                            .font(.system(size: 12))
                            .foregroundStyle(chosen ? Palette.yellow : .white.opacity(0.5))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                            if !option.description.isEmpty {
                                Text(option.description).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 9).fill(chosen ? Palette.yellow.opacity(0.14) : Color.white.opacity(0.05)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            TextField("Or type your own answer", text: Binding(
                get: { model.other[question.question] ?? "" },
                set: { model.other[question.question] = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.07)))
        }
    }

    private func toggle(_ label: String) {
        var chosen = model.picks[question.question] ?? []
        if question.multiSelect {
            if let i = chosen.firstIndex(of: label) { chosen.remove(at: i) } else { chosen.append(label) }
        } else {
            chosen = chosen == [label] ? [] : [label]
        }
        model.picks[question.question] = chosen
    }
}

struct CodeBox: View {
    let text: String

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 190)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

struct DiffView: View {
    let lines: [DiffLine]

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    let color = line.kind == .removed ? Palette.red : Palette.green
                    Text((line.kind == .removed ? "− " : "+ ") + line.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color.opacity(0.95))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .background(color.opacity(0.08))
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

struct MessageBox: View {
    let text: String

    var body: some View {
        ScrollView(.vertical) {
            Text(Self.render(text))
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.88))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    /// Light markdown: bold, italics, code and links render; headings and bullets become plain lines.
    static func render(_ text: String) -> AttributedString {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { return trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return "• " + trimmed.dropFirst(2) }
            return line
        }
        let joined = lines.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: joined, options: options)) ?? AttributedString(joined)
    }
}

struct InfoBox: View {
    let color: Color
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(color)
            if !text.isEmpty {
                ScrollView(.vertical) {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.1)))
    }
}

struct StepsView: View {
    let steps: [Step]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: 8) {
                    switch step.result {
                    case .running: Spark(color: Palette.claude, spinning: true).frame(width: 11, height: 11)
                    case .done: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.green)
                    case .failed: Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.red)
                    }
                    Text(step.label)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(step.result == .running ? 0.9 : 0.6))
                        .lineLimit(1)
                }
                .frame(height: 18)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}
