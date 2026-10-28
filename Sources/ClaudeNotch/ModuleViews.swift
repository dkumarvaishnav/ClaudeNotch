import SwiftUI

extension Palette {
    static let focus = Color(red: 0.38, green: 0.70, blue: 1.0)    // timers and focus rounds
    static let rest = Color(red: 0.36, green: 0.86, blue: 0.76)    // breaks

    static func timer(_ kind: TimerStore.Kind) -> Color { kind.isBreak ? rest : focus }
}

// MARK: - Header shared by every page: tabs on the left, page tools on the right

struct PanelHeader: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var timer: TimerStore
    @ObservedObject var shelf: ShelfStore
    let sessions: [ClaudeSession]

    var body: some View {
        let side = max(0, (model.openWidth - model.notchWidth) / 2)
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                tab(.claude, "Claude") {
                    let top = sessions.map(\.state).min { $0.rawValue < $1.rawValue } ?? .idle
                    Spark(color: top == .idle ? Palette.claude : Palette.color(top), spinning: sessions.contains { $0.state == .working })
                        .frame(width: 12, height: 12)
                }
                tab(.timer, "Timer") {
                    Image(systemName: timer.kind.isBreak && timer.isActive ? "cup.and.saucer.fill" : "timer")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(timer.isActive ? Palette.timer(timer.kind) : .white.opacity(0.7))
                }
                tab(.shelf, "Shelf") {
                    Image(systemName: shelf.items.isEmpty ? "tray" : "tray.full.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
            .frame(width: side)

            Color.clear.frame(width: model.notchWidth)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                tools
                Button { model.actions?.showMenu() } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 16)
            .frame(width: side)
        }
    }

    /// The active tab shows its name; the others are just an icon.
    private func tab<Icon: View>(_ tab: NotchModel.Tab, _ title: String, @ViewBuilder icon: () -> Icon) -> some View {
        let active = model.tab == tab && model.mode != .peek && model.mode != .timerPeek
        return Button { model.actions?.select(tab) } label: {
            HStack(spacing: 5) {
                icon()
                if active {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.92)).fixedSize()
                }
                if tab == .shelf, !shelf.items.isEmpty, !active {
                    Text("\(shelf.items.count)").font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, active ? 9 : 6)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(active ? 0.12 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    @ViewBuilder private var tools: some View {
        switch model.mode == .peek ? .claude : model.tab {
        case .claude:
            if sessions.contains(where: { $0.needsAttention && $0.permission == nil && $0.status == "idle" }) {
                SmallButton(title: "Clear", help: "Mark finished sessions as seen") { model.actions?.clearAll() }
            }
            SummaryChips(sessions: sessions)
        case .timer:
            if timer.kind.isPomodoro, timer.isActive || timer.awaitingFocus { RoundDots(timer: timer) }
        case .shelf:
            if !shelf.items.isEmpty { SmallButton(title: "Clear", help: "Empty the shelf") { shelf.clear() } }
        }
    }
}

struct SmallButton: View {
    let title: String
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Timer

struct TimerPage: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var timer: TimerStore

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                segment(.timer, "Timer")
                segment(.pomodoro, "Pomodoro")
                Spacer()
            }
            if timer.page == .timer { timerFace } else { pomodoroFace }
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    private func segment(_ page: TimerStore.Page, _ title: String) -> some View {
        Button { timer.page = page } label: {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(timer.page == page ? 0.95 : 0.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(timer.page == page ? 0.12 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // A plain countdown.
    private var timerFace: some View {
        let showing = timer.kind == .timer && timer.isActive
        return VStack(spacing: 10) {
            HStack(spacing: 18) {
                if !showing { RoundIcon(symbol: "minus") { timer.minutes -= timer.minutes > 10 ? 5 : 1 } }
                Clock(timer: timer, show: showing ? nil : TimerStore.format(TimeInterval(timer.minutes * 60), long: timer.minutes >= 60),
                      color: showing ? Palette.focus : .white)
                if !showing { RoundIcon(symbol: "plus") { timer.minutes += timer.minutes >= 10 ? 5 : 1 } }
            }
            if showing {
                Progress(timer: timer, color: Palette.focus)
            } else {
                HStack(spacing: 6) {
                    ForEach([1, 5, 10, 15, 25, 45, 60], id: \.self) { m in
                        Button { timer.minutes = m } label: {
                            Text(m == 60 ? "1h" : "\(m)m")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(timer.minutes == m ? 0.95 : 0.6))
                                .frame(width: 38, height: 22)
                                .background(Capsule().fill(Color.white.opacity(timer.minutes == m ? 0.16 : 0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 8) {
                if !showing {
                    PillButton(title: "Start", style: .primary(Palette.focus)) { timer.startTimer() }
                } else if timer.isRunning {
                    PillButton(title: "Pause") { timer.pause() }
                    PillButton(title: "Reset", style: .destructive) { timer.reset() }
                } else {
                    PillButton(title: "Resume", style: .primary(Palette.focus)) { timer.resume() }
                    PillButton(title: "Reset", style: .destructive) { timer.reset() }
                }
            }
        }
    }

    // The Pomodoro cycle.
    private var pomodoroFace: some View {
        let showing = timer.kind.isPomodoro && timer.isActive
        let color = showing ? Palette.timer(timer.kind) : .white
        return VStack(spacing: 10) {
            Text(phaseTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(showing ? color : .white.opacity(0.7))
            Clock(timer: timer, show: showing ? nil : TimerStore.format(TimeInterval(timer.focusMinutes * 60), long: false), color: color)
            if showing { Progress(timer: timer, color: color) }
            HStack(spacing: 8) {
                if !showing {
                    PillButton(title: "Start focus", style: .primary(Palette.focus)) { timer.startFocus() }
                } else {
                    if timer.isRunning {
                        PillButton(title: "Pause") { timer.pause() }
                    } else {
                        PillButton(title: "Resume", style: .primary(color)) { timer.resume() }
                    }
                    PillButton(title: timer.kind.isBreak ? "Skip break" : "Done early") { timer.skip() }
                    PillButton(title: "Stop", style: .destructive) { timer.reset() }
                }
            }
            Text("\(timer.focusMinutes) min focus · \(timer.shortBreakMinutes) min break · \(timer.longBreakMinutes) min after \(timer.roundsPerCycle) rounds")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private var phaseTitle: String {
        let round = min(timer.focusRounds + 1, timer.roundsPerCycle)
        if timer.kind.isPomodoro, timer.isActive {
            switch timer.kind {
            case .focus: return "Focus · round \(round) of \(timer.roundsPerCycle)"
            case .shortBreak: return "Short break"
            case .longBreak: return "Long break · cycle done"
            case .timer: return ""
            }
        }
        return timer.awaitingFocus ? "Break's over · round \(round) of \(timer.roundsPerCycle)" : "Ready to focus"
    }
}

/// The big countdown. Redraws once a second only while it runs.
struct Clock: View {
    @ObservedObject var timer: TimerStore
    var show: String?            // a fixed value (when idle)
    var color: Color
    var size: CGFloat = 46

    var body: some View {
        Group {
            if let show {
                text(show)
            } else if timer.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { context in text(timer.clock(at: context.date)) }
            } else {
                text(timer.clock()).opacity(0.6)
            }
        }
    }

    private func text(_ value: String) -> some View {
        Text(value)
            .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(color)
            .contentTransition(.identity)
    }
}

struct Progress: View {
    @ObservedObject var timer: TimerStore
    var color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(color).frame(width: max(4, geo.size.width * timer.progress(at: context.date)))
                }
            }
        }
        .frame(width: 260, height: 4)
    }
}

struct RoundDots: View {
    @ObservedObject var timer: TimerStore

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<timer.roundsPerCycle, id: \.self) { i in
                Circle()
                    .fill(i < timer.focusRounds ? Palette.focus : Color.white.opacity(0.18))
                    .frame(width: 6, height: 6)
            }
        }
        .help("\(timer.focusRounds) of \(timer.roundsPerCycle) focus rounds done")
    }
}

struct RoundIcon: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// The countdown beside the notch while a timer runs (or a "Focus" nudge between Pomodoro rounds).
struct TimerEar: View {
    @ObservedObject var timer: TimerStore

    var body: some View {
        let color = Palette.timer(timer.kind)
        HStack(spacing: 4) {
            if timer.isActive {
                Image(systemName: timer.isRunning ? (timer.kind.isBreak ? "cup.and.saucer.fill" : "timer") : "pause.fill")
                    .font(.system(size: 9.5, weight: .bold))
                Clock(timer: timer, color: color, size: 12.5)
            } else {
                Image(systemName: "play.fill").font(.system(size: 8.5, weight: .bold))
                Text("Focus").font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(timer.isActive ? color : Palette.focus.opacity(0.85))
        .opacity(timer.isRunning || !timer.isActive ? 1 : 0.65)
        .fixedSize()
    }
}

/// A tiny progress ring for the right ear when there's no Claude session to show.
struct TimerRing: View {
    @ObservedObject var timer: TimerStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ZStack {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: timer.progress(at: context.date))
                    .stroke(Palette.timer(timer.kind), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 12, height: 12)
    }
}

/// The 4-second pop-up when a countdown ends.
struct TimerPeekCard: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var timer: TimerStore

    var body: some View {
        let event = model.timerEvent ?? .timer
        HStack(spacing: 12) {
            Image(systemName: icon(event))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(color(event))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(event)).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                Text(subtitle(event)).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            switch event {
            case .timer:
                PillButton(title: "Again", style: .primary(Palette.focus)) { timer.startTimer(); model.actions?.close() }
            case .focus:
                PillButton(title: "Skip break") { timer.skip() }
            case .breakOver:
                PillButton(title: "Start focus", style: .primary(Palette.focus)) { timer.startFocus(); model.actions?.close() }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
    }

    private func icon(_ e: TimerStore.Finish) -> String {
        switch e {
        case .timer: return "bell.fill"
        case .focus: return "cup.and.saucer.fill"
        case .breakOver: return "timer"
        }
    }
    private func color(_ e: TimerStore.Finish) -> Color {
        if case .focus = e { return Palette.rest }
        return Palette.focus
    }
    private func title(_ e: TimerStore.Finish) -> String {
        switch e {
        case .timer: return "Time's up"
        case .focus(let next): return next == .longBreak ? "Cycle done, take a long break" : "Focus done, take a break"
        case .breakOver: return "Break's over"
        }
    }
    private func subtitle(_ e: TimerStore.Finish) -> String {
        switch e {
        case .timer: return "\(timer.minutes) min timer finished"
        case .focus(let next):
            return "\(next == .longBreak ? timer.longBreakMinutes : timer.shortBreakMinutes) min break started · \(timer.focusRounds) of \(timer.roundsPerCycle) rounds"
        case .breakOver: return "Ready for focus round \(min(timer.focusRounds + 1, timer.roundsPerCycle))"
        }
    }
}

// MARK: - Shelf

struct ShelfPage: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(model.dropTargeted ? "Release to keep it here" : "Drop files, images or text here · drag them out, or click to copy")
                    .font(.system(size: 11))
                    .foregroundStyle(model.dropTargeted ? Palette.focus : .white.opacity(0.45))
                    .lineLimit(1)
                Spacer(minLength: 4)
                PillButton(title: "Paste") { shelf.pasteFromClipboard() }
                    .help("Add what you copied last")
                Button { shelf.setHistory(!shelf.historyOn) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: shelf.historyOn ? "clock.arrow.circlepath" : "clock")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("History").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(shelf.historyOn ? Palette.focus : .white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(shelf.historyOn ? Palette.focus.opacity(0.15) : Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help(shelf.historyOn ? "Clipboard history is on: everything you copy lands here" : "Turn on clipboard history")
            }
            if shelf.historyOn, !shelf.historyAllowed {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(Palette.yellow)
                    Text("macOS asks before apps read what you copy. Set ClaudeNotch to Allow under Paste from Other Apps.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    SmallButton(title: "Allow…") { shelf.requestAccess() }
                }
            }
            tray
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var tray: some View {
        let outline = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if shelf.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: model.dropTargeted ? "arrow.down.circle.fill" : "tray.and.arrow.down")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(model.dropTargeted ? Palette.focus : .white.opacity(0.35))
                Text("Park things here to take them to another app or Space")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(outline.strokeBorder(model.dropTargeted ? Palette.focus : Color.white.opacity(0.14),
                                             style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(shelf.items) { item in ShelfTile(model: model, shelf: shelf, item: item) }
                }
                .padding(4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(outline.strokeBorder(model.dropTargeted ? Palette.focus : .clear, lineWidth: 1.5))
        }
    }
}

struct ShelfTile: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfStore
    let item: ShelfStore.Item

    var body: some View {
        let hovering = model.hoveredRow == item.id.uuidString
        let copied = shelf.copied == item.id
        VStack(spacing: 5) {
            preview
                .frame(width: 52, height: 46)
            Text(item.title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .truncationMode(isText ? .tail : .middle) // long file names keep their extension
                .multilineTextAlignment(.center)
                .frame(height: 26, alignment: .center)
            Text(copied ? "Copied" : item.kindLabel)
                .font(.system(size: 9.5, weight: copied ? .bold : .regular))
                .foregroundStyle(copied ? Palette.green : .white.opacity(0.4))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .frame(width: 100, height: 112)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hovering ? 0.12 : 0.06)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { shelf.remove(item) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color(white: 0.25)))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .help("Remove from the shelf")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { shelf.copy(item) }
        .onDrag { shelf.provider(for: item) }
        .onHover { inside in
            if inside { model.hoveredRow = item.id.uuidString } else if model.hoveredRow == item.id.uuidString { model.hoveredRow = nil }
        }
        .help(help)
    }

    private var isText: Bool { if case .text = item.content { return true } else { return false } }

    @ViewBuilder private var preview: some View {
        switch item.content {
        case .text(let text):
            Text(text)
                .font(.system(size: 8.5))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(4)
                .padding(5)
                .frame(width: 52, height: 46, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
        default:
            Image(nsImage: shelf.thumbnail(for: item))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: item.isImage ? 5 : 0))
        }
    }

    private var help: String {
        let from = item.source.map { " · from \($0)" } ?? ""
        switch item.content {
        case .file(let url): return url.path + from
        case .text(let text): return String(text.prefix(400)) + from
        case .link(let url): return url.absoluteString + from
        }
    }
}
