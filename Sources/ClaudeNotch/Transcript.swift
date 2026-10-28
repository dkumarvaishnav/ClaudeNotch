import Foundation

/// What the tail of a session transcript (`~/.claude/projects/<dir>/<session>.jsonl`) says right now.
struct TranscriptSummary {
    enum Latest { case tool, text, thinking, toolResult, prompt }

    var path: URL
    var mtime: Date = .distantPast
    var size: UInt64 = 0
    var latest: Latest?
    var tool: ToolInfo?
    var toolResolved = false
    var lastText: String?          // first line of the newest reply
    var lastPrompt: String?
    var searchedForText = false    // already looked as far back as we go for the last reply

    // How the newest turn ended, read back to the last prompt.
    var outcome: Outcome = .none
    var message = ""               // the newest reply in full (or the error text)
    var ask: String?               // desktop wrap-up question
    var actions: [ReplyAction] = []
    var steps: [Step] = []         // newest last
}

struct ToolInfo {
    var name: String
    var label: String       // "Editing NotchView.swift"
    var permission: String  // "run: git push"
    var question: String?   // AskUserQuestion / plan review
}

enum Transcript {
    /// Bytes read from the end of the file: a small tail first, a large one only when that is not enough
    /// (single lines can be huge, e.g. tool output).
    private static let smallTail: UInt64 = 256_000
    private static let largeTail: UInt64 = 1_500_000
    private static let maxSteps = 8
    private static let assistantMarker = Data("\"type\":\"assistant\"".utf8)
    private static let userMarker = Data("\"type\":\"user\"".utf8)
    private static let lastPromptMarker = Data("\"type\":\"last-prompt\"".utf8)

    /// `needsText`: the last reply is shown (idle sessions); busy sessions only need the newest step.
    static func summarize(_ path: URL, mtime: Date, size: UInt64, needsText: Bool) -> TranscriptSummary {
        var small = scan(path, mtime: mtime, size: size, tail: smallTail)
        let enough = small.latest != nil && small.tool != nil && (small.lastText != nil || !needsText) && small.outcome != .none
        if size <= smallTail || enough {
            small.searchedForText = needsText || size <= smallTail
            return small
        }
        var large = scan(path, mtime: mtime, size: size, tail: largeTail)
        large.searchedForText = true
        return large
    }

    private static func scan(_ path: URL, mtime: Date, size: UInt64, tail: UInt64) -> TranscriptSummary {
        var summary = TranscriptSummary(path: path, mtime: mtime, size: size)
        guard let handle = try? FileHandle(forReadingFrom: path) else { return summary }
        defer { try? handle.close() }
        let start = size > tail ? size - tail : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return summary }

        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() } // partial line

        var results: [String: Bool] = [:]   // tool_use id → failed?
        var turnOver = false                // reached the prompt that started the newest turn
        var endingText: String?             // newest reply text in this turn
        var wrapUpSeen = false
        var steps: [Step] = []

        for line in lines.reversed() {
            let isAssistant = line.range(of: assistantMarker) != nil
            let isUser = !isAssistant && line.range(of: userMarker) != nil
            let isLastPrompt = !isAssistant && !isUser && line.range(of: lastPromptMarker) != nil
            guard isAssistant || isUser || isLastPrompt else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if obj["isSidechain"] as? Bool == true { continue }

            switch obj["type"] as? String {
            case "assistant":
                guard let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
                // Only an error that is the newest thing in the turn counts (a later retry may have worked).
                if obj["isApiErrorMessage"] as? Bool == true, !turnOver, summary.outcome == .none, endingText == nil, !wrapUpSeen {
                    let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    summary.outcome = .error(text.isEmpty ? "API error" : text)
                    summary.message = text
                }
                for block in blocks.reversed() {
                    switch block["type"] as? String {
                    case "tool_use":
                        if summary.latest == nil { summary.latest = .tool }
                        let name = block["name"] as? String ?? ""
                        let input = block["input"] as? [String: Any] ?? [:]
                        let id = block["id"] as? String ?? ""
                        if summary.tool == nil {
                            summary.tool = describe(tool: name, input: input)
                            summary.toolResolved = results[id] != nil
                        }
                        if name.hasSuffix("wrap_up") {
                            // The desktop app ends a turn with a recap and, when it needs you, one question.
                            if summary.lastText == nil, let recap = input["recap"] as? String {
                                let text = clean(recap)
                                if !text.isEmpty { summary.lastText = text }
                            }
                            if !turnOver, !wrapUpSeen {
                                wrapUpSeen = true
                                let ask = (input["ask"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                                summary.ask = ask?.isEmpty == false ? ask : nil
                                summary.actions = (input["actions"] as? [[String: Any]] ?? []).compactMap { action in
                                    guard action["action"] == nil, let label = action["label"] as? String else { return nil }
                                    return ReplyAction(label: label, message: action["message"] as? String ?? label)
                                }
                                if summary.message.isEmpty, let recap = input["recap"] as? String { summary.message = recap }
                            }
                        } else if !turnOver, steps.count < maxSteps, !name.hasSuffix("update_plan") {
                            let result: Step.Result = results[id].map { $0 ? .failed : .done } ?? .running
                            steps.append(Step(label: describe(tool: name, input: input).label, result: result))
                        }
                    case "text":
                        let raw = block["text"] as? String ?? ""
                        let text = clean(raw)
                        guard !text.isEmpty else { continue }
                        if summary.latest == nil { summary.latest = .text }
                        if summary.lastText == nil { summary.lastText = text }
                        if !turnOver, endingText == nil { endingText = raw }
                    case "thinking", "redacted_thinking":
                        if summary.latest == nil { summary.latest = .thinking }
                    default: break
                    }
                }
            case "user":
                if obj["isMeta"] as? Bool == true { continue }
                let content = (obj["message"] as? [String: Any])?["content"]
                var prompt: String?
                if let text = content as? String {
                    prompt = text
                } else if let blocks = content as? [[String: Any]] {
                    for block in blocks {
                        if block["type"] as? String == "tool_result" {
                            if let id = block["tool_use_id"] as? String { results[id] = block["is_error"] as? Bool == true }
                            if summary.latest == nil { summary.latest = .toolResult }
                        } else if block["type"] as? String == "text", prompt == nil {
                            prompt = block["text"] as? String
                        }
                    }
                }
                guard let prompt else { continue }
                let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("[Request interrupted") {
                    if !turnOver, summary.outcome == .none, endingText == nil { summary.outcome = .interrupted }
                    continue
                }
                // Harness-injected text (<system-reminder>, <command-name>, ...) is not something you typed.
                guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { continue }
                if summary.latest == nil { summary.latest = .prompt }
                if summary.lastPrompt == nil { summary.lastPrompt = clean(trimmed) }
                turnOver = true
            case "last-prompt":
                if summary.lastPrompt == nil, let p = obj["lastPrompt"] as? String {
                    let text = clean(p)
                    if !text.isEmpty { summary.lastPrompt = text }
                }
            default: break
            }

            if turnOver && summary.tool != nil && summary.lastText != nil && summary.lastPrompt != nil { break }
        }

        summary.steps = steps.reversed()
        if summary.outcome == .none {
            if wrapUpSeen {
                summary.outcome = summary.ask != nil ? .question : .done
                if let endingText { summary.message = endingText }
            } else if let endingText {
                summary.outcome = asksSomething(endingText) ? .question : .done
                summary.message = endingText
            }
        }
        summary.message = String(summary.message.prefix(6000))
        return summary
    }

    /// Conservative: only the closing lines count, and only a real question to you or an invitation to answer.
    static func asksSomething(_ text: String) -> Bool {
        var fenced = false
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            if line.hasPrefix("```") { fenced.toggle(); return false }
            return !line.isEmpty && !fenced
        }
        let plain = { (l: String) in l.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "_", with: "").trimmingCharacters(in: .whitespaces) }
        let pattern = #"\b(you|your|would|which|what|how|can|could|should|shall|want|do|does|prefer)\b"#
        let asks = { (l: String) -> Bool in
            let p = plain(l)
            return p.hasSuffix("?") && !p.hasPrefix(">") && p.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let invite = #"^(let me know|tell me|reply|pick|choose|confirm)\b|let me know[.!]?$"#
        let last = lines.last.map(plain) ?? ""
        return lines.suffix(3).contains(where: asks) || last.range(of: invite, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The last line that asks you something, for the one-line summary of a "needs reply" session.
    static func questionLine(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n").map { clean($0) }.filter { !$0.isEmpty }
        return lines.last { $0.hasSuffix("?") } ?? lines.last
    }

    /// First meaningful line of a markdown-ish message, without markup.
    static func clean(_ text: String) -> String {
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("|") || line.hasPrefix("---") { continue }
            while let first = line.first, "#>-*• ".contains(first) { line.removeFirst() }
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression) // [text](url) → text
                .trimmingCharacters(in: .whitespaces)
            if line.count >= 2 { return String(line.prefix(200)) }
        }
        return ""
    }

    private static func oneLine(_ s: String?, max: Int = 80) -> String? {
        guard let s else { return nil }
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return nil }
        return line.count > max ? String(line.prefix(max - 1)) + "…" : line
    }

    private static func pretty(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    }

    static func describe(tool name: String, input: [String: Any]) -> ToolInfo {
        let path = input["file_path"] as? String ?? input["notebook_path"] as? String ?? input["path"] as? String
        let file = path.map { ($0 as NSString).lastPathComponent }
        let command = oneLine(input["command"] as? String)
        let description = oneLine(input["description"] as? String)

        switch name {
        case "Read":
            return ToolInfo(name: name, label: "Reading \(file ?? "a file")", permission: "read \(file ?? "a file")")
        case "Edit", "MultiEdit", "NotebookEdit":
            return ToolInfo(name: name, label: "Editing \(file ?? "a file")", permission: "edit \(file ?? "a file")")
        case "Write":
            return ToolInfo(name: name, label: "Writing \(file ?? "a file")", permission: "write \(file ?? "a file")")
        case "Bash", "PowerShell":
            return ToolInfo(name: name, label: description ?? "Running \(command ?? "a command")",
                            permission: "run: \(command ?? description ?? "a command")")
        case "Grep", "Glob":
            return ToolInfo(name: name, label: "Searching the code", permission: "search files")
        case "WebFetch":
            let host = (input["url"] as? String).flatMap { URL(string: $0)?.host } ?? "a web page"
            return ToolInfo(name: name, label: "Reading \(host)", permission: "fetch \(host)")
        case "WebSearch":
            let query = oneLine(input["query"] as? String, max: 50) ?? ""
            return ToolInfo(name: name, label: "Searching the web: \(query)", permission: "search the web")
        case "Task", "Agent":
            return ToolInfo(name: name, label: "Subagent: \(description ?? "working")", permission: "start a subagent")
        case "TodoWrite":
            return ToolInfo(name: name, label: "Updating the to-do list", permission: "update the to-do list")
        case "Skill":
            let skill = input["skill"] as? String ?? "a skill"
            return ToolInfo(name: name, label: "Using skill \(skill)", permission: "use skill \(skill)")
        case "AskUserQuestion":
            let first = (input["questions"] as? [[String: Any]])?.first?["question"] as? String
            return ToolInfo(name: name, label: "Asking you a question", permission: "ask you something",
                            question: oneLine(first, max: 120) ?? "Has a question for you")
        case "ExitPlanMode":
            return ToolInfo(name: name, label: "Presenting a plan", permission: "start on its plan",
                            question: "Plan ready for your review")
        default:
            if name.hasSuffix("wrap_up") {
                return ToolInfo(name: name, label: "Wrapping up", permission: "wrap up")
            }
            if name.hasSuffix("update_plan") {
                return ToolInfo(name: name, label: "Updating its plan", permission: "update its plan")
            }
            if name.hasPrefix("mcp__") {
                let parts = name.components(separatedBy: "__")
                let tool = pretty(parts.last ?? name)
                return ToolInfo(name: name, label: "Using \(tool)", permission: "use \(tool)")
            }
            return ToolInfo(name: name, label: "Using \(name)", permission: "use \(name)")
        }
    }
}
