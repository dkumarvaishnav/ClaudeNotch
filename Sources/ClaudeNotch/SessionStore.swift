import Foundation
import Combine
import Darwin

/// Follows every live Claude Code session on this Mac.
///
/// Claude Code keeps a registry of running sessions in `~/.claude/sessions/<pid>.json`
/// (name, folder, status busy/shell/waiting/idle). The transcript tail adds what the session
/// is doing and how its last turn ended; ClaudeNotch's hooks (when on) add pending permission
/// requests, reply waits and API errors.
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []
    let events = PassthroughSubject<SessionEvent, Never>()

    private let sessionsDir: URL
    private let projectsDir: URL
    private let queue = DispatchQueue(label: "ClaudeNotch.poll", qos: .utility)
    private var timer: DispatchSourceTimer?

    // Only touched on `queue`.
    private var registry: [String: (mtime: Date, record: RegistryRecord)] = [:]
    private var transcripts: [String: TranscriptSummary] = [:]
    private var transcriptMisses: [String: Date] = [:]
    private var hooks: [String: HookInfo] = [:]
    private var lastState: [String: SessionState] = [:]
    private var acks: [String: Double]            // session id → when you last dealt with it (ms)
    private var missingSince: [String: Date] = [:]
    private var primed = false

    private static let acksKey = "acknowledged"
    #if DEBUG
    /// A debug build on a fake ~/.claude shows only the fake sessions, never real ones reaching it via hooks.
    private static let fakeHome = ProcessInfo.processInfo.environment["CLAUDENOTCH_HOME"] != nil
    #else
    private static let fakeHome = false
    #endif
    /// On first sight, anything that finished longer ago than this counts as already seen.
    private static let freshWindow: TimeInterval = 15 * 60

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        sessionsDir = home.appendingPathComponent(".claude/sessions")
        projectsDir = home.appendingPathComponent(".claude/projects")
        acks = UserDefaults.standard.dictionary(forKey: Self.acksKey) as? [String: Double] ?? [:]
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    /// Synchronous refresh, used by the snapshot renderer.
    func refreshNow() {
        queue.sync { poll() }
    }

    func update(hooks info: [String: HookInfo]) {
        queue.async { [weak self] in
            self?.hooks = info
            self?.poll()
        }
    }

    /// You dealt with it (opened it, replied, dismissed): back to grey until its next turn ends.
    func acknowledge(_ ids: [String]) {
        let now = Date().timeIntervalSince1970 * 1000
        queue.async { [weak self] in
            guard let self else { return }
            ids.forEach { self.acks[$0] = now }
            self.saveAcks()
            self.poll()
        }
    }

    private func saveAcks() {
        UserDefaults.standard.set(acks, forKey: Self.acksKey)
    }

    // MARK: - Polling

    private func poll() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        var found: [ClaudeSession] = []
        var liveKeys = Set<String>()
        var acksChanged = false

        for url in files where url.pathExtension == "json" {
            let key = url.lastPathComponent
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let record: RegistryRecord
            if let cached = registry[key], cached.mtime == mtime {
                record = cached.record
            } else if let data = try? Data(contentsOf: url),
                      let decoded = try? JSONDecoder().decode(RegistryRecord.self, from: data) {
                record = decoded
                registry[key] = (mtime, decoded)
            } else if let cached = registry[key] {
                record = cached.record // caught mid-write: keep the last good copy
            } else {
                continue
            }
            liveKeys.insert(key)

            if record.spare == true { continue }                       // pre-warmed, nobody uses it yet
            if let kind = record.kind, kind != "interactive", kind != "bg" { continue }
            guard Proc.isSameProcess(pid: record.pid, procStart: record.procStart) else { continue }

            let status = record.status ?? "idle"
            let statusMs = record.statusUpdatedAt ?? record.updatedAt ?? record.startedAt ?? 0
            var session = ClaudeSession(
                id: record.sessionId, pid: record.pid, name: record.name ?? "", cwd: record.cwd ?? "",
                entrypoint: record.entrypoint ?? "cli", hostSessionId: record.hostSessionId,
                status: status, waitingFor: record.waitingFor,
                statusSince: Date(timeIntervalSince1970: statusMs / 1000), activity: "", lastPrompt: "")
            if acks[session.id] == nil, Date().timeIntervalSince(session.statusSince) > Self.freshWindow {
                acks[session.id] = statusMs
                acksChanged = true
            }
            fill(&session, statusMs: statusMs)
            found.append(session)
        }

        // Sessions we only know from hooks (e.g. `claude -p`, Agent SDK apps).
        let known = Set(found.map(\.id))
        for (sid, info) in hooks where !known.contains(sid) && !Self.fakeHome {
            guard !info.permissions.isEmpty || info.replyWaiting || Date().timeIntervalSince(info.lastEventAt) < 600 else { continue }
            let ended = [info.lastStop?.at, info.lastFailure?.at].compactMap { $0 }.max()
            let busy = info.lastPromptAt.map { prompt in ended.map { prompt > $0 } ?? true } ?? false
            let status = !info.permissions.isEmpty ? "waiting" : busy ? "busy" : "idle"
            let since = [info.lastPromptAt, ended].compactMap { $0 }.max() ?? info.lastEventAt
            var session = ClaudeSession(id: sid, pid: info.pid ?? 0, name: "", cwd: info.cwd ?? "", entrypoint: "hook",
                                        hostSessionId: nil, status: status, waitingFor: nil, statusSince: since,
                                        activity: "", lastPrompt: "")
            fill(&session, statusMs: since.timeIntervalSince1970 * 1000)
            found.append(session)
        }

        // Forget sessions that went away.
        registry = registry.filter { liveKeys.contains($0.key) }
        let ids = Set(found.map(\.id))
        transcripts = transcripts.filter { ids.contains($0.key) }
        transcriptMisses = transcriptMisses.filter { ids.contains($0.key) }
        // Forget what you've seen only once a session has been gone for a while (not on one bad read).
        let now = Date()
        for id in ids { missingSince[id] = nil }
        for id in Set(acks.keys).union(lastState.keys) where !ids.contains(id) { missingSince[id] = missingSince[id] ?? now }
        let gone = Set(missingSince.filter { now.timeIntervalSince($0.value) > 600 }.keys)
        if !gone.isEmpty {
            gone.forEach { acks[$0] = nil; lastState[$0] = nil; missingSince[$0] = nil }
            acksChanged = true
        }
        if acksChanged { saveAcks() }

        // Something new needs you: pop open (once per change of state).
        var pending: [SessionEvent] = []
        for s in found {
            let state = s.state
            if primed, s.needsAttention, lastState[s.id] != state { pending.append(.attention(s)) }
            lastState[s.id] = state
        }
        primed = true

        found.sort { a, b in
            a.state.rawValue != b.state.rawValue ? a.state.rawValue < b.state.rawValue : a.statusSince > b.statusSince
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.sessions != found { self.sessions = found }
            pending.forEach { self.events.send($0) }
        }
    }

    /// Adds transcript and hook knowledge to a session.
    private func fill(_ session: inout ClaudeSession, statusMs: Double) {
        let info = hooks[session.id]
        let summary = transcript(for: session.id, cwd: session.cwd, needsText: session.status == "idle")
        let turnStart = session.statusSince.addingTimeInterval(-5)

        session.lastPrompt = summary?.lastPrompt ?? ""
        session.steps = summary?.steps ?? []
        session.permission = info?.permissions.first
        session.canReply = info?.replyWaiting ?? false
        session.ask = summary?.ask
        session.actions = summary?.actions ?? []

        // How the last turn ended: an API error reported by the hook wins, then the transcript, then the Stop hook.
        if let failure = info?.lastFailure, failure.at >= turnStart, info?.lastPromptAt.map({ $0 < failure.at }) ?? true {
            session.outcome = .error(Self.errorLabel(failure))
            session.message = failure.message
        } else if let summary, summary.outcome != .none {
            session.outcome = summary.outcome
            session.message = summary.message
        } else if let stop = info?.lastStop, stop.at >= turnStart {
            session.outcome = Transcript.asksSomething(stop.message) ? .question : .done
            session.message = stop.message
        }
        if case .error(let text) = session.outcome, session.message.isEmpty { session.message = text }

        session.acknowledged = (acks[session.id] ?? 0) >= statusMs
        session.activity = Self.activity(for: session, summary)
    }

    private static func errorLabel(_ failure: HookInfo.Failure) -> String {
        let labels = ["rate_limit": "Rate limit reached", "overloaded": "Claude is overloaded", "authentication_failed": "Not signed in",
                      "billing_error": "Billing problem", "server_error": "Server error", "max_output_tokens": "Reply too long",
                      "invalid_request": "Invalid request", "model_not_found": "Model not found"]
        return labels[failure.error] ?? (failure.message.isEmpty ? "Error: \(failure.error)" : failure.message)
    }

    // MARK: - Transcripts

    private func transcript(for id: String, cwd: String, needsText: Bool) -> TranscriptSummary? {
        let fm = FileManager.default
        var path = transcripts[id]?.path
        if path == nil {
            if let missedAt = transcriptMisses[id], Date().timeIntervalSince(missedAt) < 15 { return nil }
            path = locateTranscript(id: id, cwd: cwd)
            if path == nil { transcriptMisses[id] = Date(); return nil }
            transcriptMisses[id] = nil
        }
        guard let path, let attrs = try? fm.attributesOfItem(atPath: path.path) else {
            transcripts[id] = nil
            return nil
        }
        let mtime = attrs[.modificationDate] as? Date ?? .distantPast
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        if let cached = transcripts[id], cached.mtime == mtime, cached.size == size,
           !needsText || cached.searchedForText { return cached }
        let summary = Transcript.summarize(path, mtime: mtime, size: size, needsText: needsText)
        transcripts[id] = summary
        return summary
    }

    private func locateTranscript(id: String, cwd: String) -> URL? {
        let fm = FileManager.default
        // Claude Code names the project folder after the cwd, with every other character replaced by "-".
        let encoded = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let direct = projectsDir.appendingPathComponent(encoded).appendingPathComponent(id + ".jsonl")
        if fm.fileExists(atPath: direct.path) { return direct }
        let dirs = (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let candidate = dir.appendingPathComponent(id + ".jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: - Wording

    static func activity(for s: ClaudeSession, _ t: TranscriptSummary?) -> String {
        if let p = s.permission { return p.detail.summary }
        switch s.status {
        case "waiting":
            if let question = t?.tool?.question, t?.toolResolved == false { return question }
            if s.waitingFor == "input needed" { return "Has a question for you" }
            if let tool = t?.tool, t?.toolResolved == false { return "Wants to " + tool.permission }
            return "Waiting for your permission"
        case "shell":
            return "Running a shell command"
        case "busy":
            guard let t else { return "Working…" }
            switch t.latest {
            case .tool:
                if let tool = t.tool, !t.toolResolved { return tool.label }
                return "Thinking…"
            case .text: return "Writing a reply…"
            case .thinking, .toolResult, .prompt, .none: return "Thinking…"
            }
        default:
            if case .error(let text) = s.outcome { return Transcript.clean(text) }
            if s.outcome == .interrupted { return "Interrupted" }
            if let ask = s.ask, !s.acknowledged { return ask }
            if s.outcome == .question, let question = Transcript.questionLine(s.message) { return question }
            if let text = t?.lastText, !text.isEmpty { return text }
            let first = Transcript.clean(s.message)
            if !first.isEmpty { return first }
            if !s.lastPrompt.isEmpty { return "Last: " + s.lastPrompt }
            return "Ready"
        }
    }
}

// MARK: - Processes

enum Proc {
    static func info(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    static func parent(of pid: Int32) -> Int32? {
        info(pid).map { $0.kp_eproc.e_ppid }
    }

    private static let lstartFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()

    /// The pid is alive and (when Claude Code recorded it) started when the registry says, so a reused pid is not mistaken for a session.
    static func isSameProcess(pid: Int32, procStart: String?) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let procStart, let info = info(pid) else { return true }
        let normalized = procStart.split(separator: " ").joined(separator: " ")
        guard let recorded = lstartFormatter.date(from: normalized) else { return true }
        let tv = info.kp_proc.p_starttime
        let actual = Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
        return abs(actual.timeIntervalSince(recorded)) < 3
    }
}
