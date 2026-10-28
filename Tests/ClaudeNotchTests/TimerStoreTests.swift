import Foundation
import Combine
import Testing
@testable import ClaudeNotch

@Suite struct TimerStoreTests {
    /// A store with its own settings and a clock the test moves by hand.
    // Starts at the real time, so the store's real one-shot alarms stay in the future during a test.
    private final class Clock { var now = Date() }

    private func make(_ clock: Clock, suite: String = UUID().uuidString) -> TimerStore {
        TimerStore(defaults: UserDefaults(suiteName: suite)!, now: { clock.now })
    }

    @Test func plainTimerCountsDownAndFinishes() {
        let clock = Clock()
        let timer = make(clock)
        var events: [TimerStore.Finish] = []
        let sub = timer.finished.sink { events.append($0) }
        timer.startTimer(minutes: 5)
        #expect(timer.clock() == "5:00")
        clock.now += 61
        #expect(timer.clock() == "3:59")
        #expect(abs(timer.progress() - 61.0 / 300) < 0.001)
        timer.complete(silently: false)
        #expect(timer.run == .idle)
        #expect(events == [.timer])
        sub.cancel()
    }

    @Test func pauseKeepsTheRemainingTime() {
        let clock = Clock()
        let timer = make(clock)
        timer.startTimer(minutes: 10)
        clock.now += 120
        timer.pause()
        clock.now += 3600 // paused for an hour
        #expect(timer.clock() == "8:00")
        timer.resume()
        clock.now += 30
        #expect(timer.clock() == "7:30")
    }

    @Test func pomodoroCycleRunsFourRoundsThenALongBreak() {
        let clock = Clock()
        let timer = make(clock)
        var events: [TimerStore.Finish] = []
        let sub = timer.finished.sink { events.append($0) }
        for round in 1...4 {
            timer.startFocus()
            #expect(timer.kind == .focus)
            timer.complete(silently: false)   // focus ends → break starts by itself
            #expect(timer.focusRounds == round)
            #expect(timer.kind == (round == 4 ? .longBreak : .shortBreak))
            #expect(timer.isRunning)
            timer.complete(silently: false)   // break ends → the next focus waits for you
            #expect(timer.awaitingFocus)
            #expect(!timer.isActive)
        }
        #expect(events.filter { $0 == .breakOver }.count == 4)
        #expect(events.contains(.focus(next: .longBreak)))
        #expect(timer.focusRounds == 0) // a long break closes the cycle
        sub.cancel()
    }

    @Test func skipEndsThePhaseWithoutAnAlert() {
        let timer = make(Clock())
        var events: [TimerStore.Finish] = []
        let sub = timer.finished.sink { events.append($0) }
        timer.startFocus()
        timer.skip()
        #expect(timer.kind == .shortBreak)
        #expect(events.isEmpty)
        sub.cancel()
    }

    @Test func aRunningTimerSurvivesARestart() {
        let clock = Clock()
        let suite = UUID().uuidString
        let first = make(clock, suite: suite)
        first.startTimer(minutes: 25)
        clock.now += 300
        let second = make(clock, suite: suite)
        #expect(second.isRunning)
        #expect(second.clock() == "20:00")
    }

    @Test func aTimerThatRanOutWhileClosedJustEnds() {
        let clock = Clock()
        let suite = UUID().uuidString
        make(clock, suite: suite).startTimer(minutes: 1)
        clock.now += 600
        let later = make(clock, suite: suite)
        #expect(later.run == .idle)
    }

    @Test func longCountdownsKeepTheirHours() {
        #expect(TimerStore.format(59 * 60 + 59, long: false) == "59:59")
        #expect(TimerStore.format(3600, long: true) == "1:00:00")
        #expect(TimerStore.format(59 * 60, long: true) == "0:59:00")
        #expect(TimerStore.format(0.2, long: false) == "0:01") // never shows 0:00 while time is left
    }

    @Test func minutesStayInRange() {
        let timer = make(Clock())
        timer.minutes = 0
        #expect(timer.minutes == 1)
        timer.minutes = 1000
        #expect(timer.minutes == 180)
    }
}
