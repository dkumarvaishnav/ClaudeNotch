import Foundation

/// What a session needs from you, most urgent first (also the order of the list).
enum SessionState: Int {
    case needsInput = 0  // yellow: permission, question, or a reply that asks you something
    case error           // red: the turn ended on an API error
    case done            // green: finished with a result you haven't dealt with yet
    case working         // orange
    case idle            // grey: nothing new
}

/// How the latest turn ended.
enum Outcome: Equatable {
    case none
    case done
    case question
    case error(String)
    case interrupted
}

struct ReplyAction: Equatable, Hashable {
    var label: String
    var message: String
}

struct Step: Equatable, Hashable {
    enum Result { case running, done, failed }
    var label: String
    var result: Result
}

struct ClaudeSession: Identifiable, Equatable {
    let id: String              // Claude Code session id
    var pid: Int32
    var name: String
    var cwd: String
    var entrypoint: String      // "cli", "claude-desktop", "claude-vscode", "hook" (known only from hooks)
    var hostSessionId: String?  // desktop app's "local_…" id, used for deep links
    var status: String          // busy | shell | waiting | idle
    var waitingFor: String?
    var statusSince: Date
    var activity: String        // one line: what it is doing / what it said last
    var lastPrompt: String
    var outcome: Outcome = .none
    var message: String = ""    // Claude's last reply (or the error), for the detail view
    var ask: String?            // the desktop app's wrap-up question, if any
    var actions: [ReplyAction] = []
    var steps: [Step] = []
    var permission: PendingPermission?
    var canReply = false        // a reply hook is waiting for this session
    var acknowledged = true     // you've dealt with the latest outcome

    var project: String {
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? cwd : base
    }
    var title: String { name.isEmpty ? project : name }
    var isDesktop: Bool { entrypoint.hasPrefix("claude-desktop") }
    var hostName: String { isDesktop ? "Claude app" : entrypoint == "claude-vscode" ? "VS Code" : "Terminal" }

    var state: SessionState {
        if permission != nil || status == "waiting" { return .needsInput }
        if status == "busy" || status == "shell" { return .working }
        if acknowledged { return .idle }
        switch outcome {
        case .question: return .needsInput
        case .error: return .error
        case .done: return .done
        case .none, .interrupted: return .idle
        }
    }

    /// Worth showing in a pop-up / keeping coloured until you act.
    var needsAttention: Bool { [.needsInput, .error, .done].contains(state) }
}

enum SessionEvent {
    case attention(ClaudeSession)

    var session: ClaudeSession {
        switch self { case .attention(let s): return s }
    }
}

// MARK: - Hooks

/// A permission request held open by the hook until you answer it in the notch (or elsewhere).
struct PendingPermission: Equatable {
    let requestId: String
    let toolName: String
    let detail: PermissionDetail
    let alwaysLabel: String?    // "Always allow" / "Allow all edits", when Claude Code offers a rule
    let receivedAt: Date
}

struct DiffLine: Equatable, Hashable {
    enum Kind { case removed, added }
    var kind: Kind
    var text: String
}

struct AskQuestion: Equatable, Hashable {
    var question: String
    var header: String
    var multiSelect: Bool
    var options: [AskOption]
}

struct AskOption: Equatable, Hashable {
    var label: String
    var description: String
}

struct PermissionDetail: Equatable {
    enum Kind { case command, edit, fetch, question, plan, other }
    var kind: Kind
    var title: String           // "Run a command", "Edit NotchView.swift"
    var summary: String         // one line for the list row
    var body: String            // command / url / input, shown as code
    var note: String?           // Bash description, fetch prompt, file path
    var diff: [DiffLine] = []
    var questions: [AskQuestion] = []
    var plan: String?
}

/// What the hooks have told us about one session. Value type, safe to hand to the poll queue.
struct HookInfo: Equatable {
    struct Stop: Equatable { var at: Date; var message: String }
    struct Failure: Equatable { var at: Date; var error: String; var message: String }

    var permissions: [PendingPermission] = []
    var replyWaiting = false
    var lastStop: Stop?
    var lastFailure: Failure?
    var lastPromptAt: Date?
    var lastEventAt = Date()
    var cwd: String?
    var pid: Int32?
}

/// One `~/.claude/sessions/<pid>.json` file, written by Claude Code itself for every live session.
struct RegistryRecord: Decodable {
    var pid: Int32
    var sessionId: String
    var cwd: String?
    var startedAt: Double?
    var procStart: String?
    var kind: String?
    var entrypoint: String?
    var hostSessionId: String?
    var name: String?
    var status: String?
    var waitingFor: String?
    var updatedAt: Double?
    var statusUpdatedAt: Double?
    var spare: Bool?
}
