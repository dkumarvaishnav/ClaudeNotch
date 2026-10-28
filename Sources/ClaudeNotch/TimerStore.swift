import Foundation
import Combine

/// A countdown timer and a Pomodoro cycle, shown in the notch.
///
/// Only the end date is stored: the views draw the remaining time from it, and a single one-shot timer
/// fires when it's due, so nothing ticks in the background. State survives a restart of the app.
final class TimerStore: ObservableObject {
    enum Kind: String, Codable {
        case timer, focus, shortBreak, longBreak

        var label: String {
            switch self {
            case .timer: return "Timer"
            case .focus: return "Focus"
            case .shortBreak: return "Break"
            case .longBreak: return "Long break"
            }
        }
        var isPomodoro: Bool { self != .timer }
        var isBreak: Bool { self == .shortBreak || self == .longBreak }
    }

    enum Run: Codable, Equatable {
        case idle
        case running(end: Date)
        case paused(remaining: TimeInterval)
    }

    /// What just happened, for the pop-up and sound.
    enum Finish: Equatable {
        case timer                      // a plain timer ran out
        case focus(next: Kind)          // a focus round ended; the break has started
        case breakOver                  // the break ended; the next focus waits for you
    }

    enum Page: String { case timer, pomodoro }

    @Published private(set) var kind: Kind = .timer
    @Published private(set) var run: Run = .idle
    @Published private(set) var duration: TimeInterval = 25 * 60
    @Published private(set) var focusRounds = 0          // focus rounds finished in this cycle
    @Published private(set) var awaitingFocus = false    // a break ended; start the next focus when ready
    /// The plain timer's length, 1 minute to 3 hours.
    @Published var minutes = 25 {
        didSet {
            // Re-assigning inside the observer would call it again: only clamp when out of range.
            let clamped = min(max(minutes, 1), 180)
            if clamped != minutes { minutes = clamped } else { save() }
        }
    }
    @Published var page: Page = .timer { didSet { save() } }
    let finished = PassthroughSubject<Finish, Never>()

    // The classic Pomodoro rhythm.
    let focusMinutes = 25
    let shortBreakMinutes = 5
    let longBreakMinutes = 15
    let roundsPerCycle = 4

    private var alarm: Timer?
    private var restoring = false
    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        restore()
    }

    // MARK: - Reading

    var isActive: Bool { run != .idle }
    var isRunning: Bool { if case .running = run { return true } else { return false } }

    func remaining(at date: Date? = nil) -> TimeInterval {
        switch run {
        case .idle: return kind == .timer ? TimeInterval(minutes * 60) : duration
        case .running(let end): return max(0, end.timeIntervalSince(date ?? now()))
        case .paused(let remaining): return remaining
        }
    }

    func progress(at date: Date? = nil) -> Double {
        guard duration > 0, isActive else { return 0 }
        return min(1, max(0, 1 - remaining(at: date) / duration))
    }

    /// "4:59", "24:13" or "1:02:03" (hours only when the countdown is that long, so the width stays put).
    func clock(at date: Date? = nil) -> String {
        Self.format(remaining(at: date), long: duration >= 3600 || (run == .idle && kind == .timer && minutes >= 60))
    }

    static func format(_ seconds: TimeInterval, long: Bool) -> String {
        let total = Int(seconds.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return long ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", h * 60 + m, s)
    }

    // MARK: - Plain timer

    func startTimer(minutes: Int? = nil) {
        if let minutes { self.minutes = minutes }
        awaitingFocus = false
        begin(.timer, seconds: TimeInterval(self.minutes * 60))
    }

    // MARK: - Pomodoro

    func startFocus() {
        awaitingFocus = false
        if focusRounds >= roundsPerCycle { focusRounds = 0 }
        begin(.focus, seconds: TimeInterval(focusMinutes * 60))
    }

    /// Ends the current phase now, as if its time had run out.
    func skip() {
        guard kind.isPomodoro, isActive else { return }
        complete(silently: true)
    }

    // MARK: - Both

    func pause() {
        guard case .running = run else { return }
        run = .paused(remaining: remaining())
        alarm?.invalidate()
        save()
    }

    func resume() {
        guard case .paused(let left) = run else { return }
        run = .running(end: now().addingTimeInterval(left))
        schedule()
        save()
    }

    /// Stops and forgets the countdown (and the Pomodoro cycle).
    func reset() {
        alarm?.invalidate()
        run = .idle
        awaitingFocus = false
        if kind.isPomodoro { focusRounds = 0; kind = .focus; duration = TimeInterval(focusMinutes * 60) }
        save()
    }

    /// Starts a countdown of any length (the public starters use whole minutes).
    func begin(_ kind: Kind, seconds: TimeInterval) {
        self.kind = kind
        duration = seconds
        run = .running(end: now().addingTimeInterval(seconds))
        schedule()
        save()
    }

    private func schedule() {
        alarm?.invalidate()
        guard case .running(let end) = run else { return }
        let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in self?.complete(silently: false) }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        alarm = timer
    }

    /// Time's up (or skipped): move to the next phase.
    func complete(silently: Bool) {
        alarm?.invalidate()
        let event: Finish
        switch kind {
        case .timer:
            run = .idle
            event = .timer
        case .focus:
            focusRounds += 1
            let next: Kind = focusRounds % roundsPerCycle == 0 ? .longBreak : .shortBreak
            begin(next, seconds: TimeInterval((next == .longBreak ? longBreakMinutes : shortBreakMinutes) * 60))
            event = .focus(next: next)
        case .shortBreak, .longBreak:
            if kind == .longBreak { focusRounds = 0 }
            kind = .focus
            duration = TimeInterval(focusMinutes * 60)
            run = .idle
            awaitingFocus = true
            event = .breakOver
        }
        save()
        if !silently { finished.send(event) }
    }

    // MARK: - Persistence

    private struct Saved: Codable {
        var kind: Kind, run: Run, duration: TimeInterval, focusRounds: Int, awaitingFocus: Bool, minutes: Int, page: String
    }

    private func save() {
        guard !restoring else { return }
        let state = Saved(kind: kind, run: run, duration: duration, focusRounds: focusRounds,
                          awaitingFocus: awaitingFocus, minutes: minutes, page: page.rawValue)
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: "timer") }
    }

    private func restore() {
        guard let data = defaults.data(forKey: "timer"), let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        restoring = true
        defer { restoring = false; save() }
        kind = s.kind
        duration = s.duration
        focusRounds = s.focusRounds
        awaitingFocus = s.awaitingFocus
        minutes = s.minutes
        page = Page(rawValue: s.page) ?? .timer
        // A countdown that ran out while the app was closed just ends; no stale alarm on launch.
        if case .running(let end) = s.run, end <= now() {
            run = .idle
            if kind == .timer { save() } else { complete(silently: true) }
        } else {
            run = s.run
            schedule()
        }
    }
}
