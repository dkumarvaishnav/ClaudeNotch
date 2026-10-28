import Foundation
import HookProtocol

/// Main-thread side of the hooks: pending permission requests, reply waits, and how each turn ended.
final class HookHub {
    private(set) var info: [String: HookInfo] = [:]
    var onChange: ([String: HookInfo]) -> Void = { _ in }

    private let token: String
    private var seenNonces: [String: Date] = [:] // replay protection
    private var permissionExchanges: [String: HookServer.Exchange] = [:]  // request id → held request
    private var permissionInputs: [String: [String: Any]] = [:]
    private var permissionSuggestions: [String: [Any]] = [:]
    private var permissionSessions: [String: String] = [:]                // request id → session id
    private var replyExchanges: [String: HookServer.Exchange] = [:]       // session id → held wait
    private var replySince: [String: Date] = [:]

    init(token: String) { self.token = token }

    // MARK: - Requests from claudenotch-hook

    func handle(_ request: HookServer.Request, _ exchange: HookServer.Exchange) {
        guard authentic(request) else { return exchange.respond(status: 403) }
        let nonce = request.headers[HookAuth.nonceHeader.lowercased()] ?? ""
        let secret = token
        exchange.proof = { status, body in HookAuth.responseProof(secret: secret, nonce: nonce, status: status, body: body) }
        guard let event = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let sid = event["session_id"] as? String, !sid.isEmpty else { return exchange.respond() }

        var i = info[sid] ?? HookInfo()
        i.lastEventAt = Date()
        if let cwd = event["cwd"] as? String { i.cwd = cwd }
        if let pid = request.query["pid"].flatMap({ Int32($0) }) { i.pid = pid }

        switch request.path {
        case "/permission":
            let id = UUID().uuidString
            let tool = event["tool_name"] as? String ?? ""
            let input = event["tool_input"] as? [String: Any] ?? [:]
            let suggestions = event["permission_suggestions"] as? [Any] ?? []
            permissionExchanges[id] = exchange
            permissionInputs[id] = input
            permissionSuggestions[id] = suggestions
            permissionSessions[id] = sid
            exchange.onClose = { [weak self] in self?.forgetPermission(id) }
            i.permissions.append(PendingPermission(requestId: id, toolName: tool,
                                                   detail: Self.detail(tool: tool, input: input),
                                                   alwaysLabel: Self.alwaysLabel(suggestions), receivedAt: Date()))
        case "/wait":
            replyExchanges.removeValue(forKey: sid)?.respond() // an older wait is stale
            replyExchanges[sid] = exchange
            replySince[sid] = Date()
            exchange.onClose = { [weak self] in self?.forgetReply(sid) }
            i.replyWaiting = true
        default:
            exchange.respond()
            switch event["hook_event_name"] as? String {
            case "Stop":
                i.lastStop = .init(at: Date(), message: event["last_assistant_message"] as? String ?? "")
                releasePermissions(of: sid, into: &i)
            case "StopFailure":
                let message = event["last_assistant_message"] as? String ?? event["error_details"] as? String ?? ""
                i.lastFailure = .init(at: Date(), error: event["error"] as? String ?? "unknown", message: message)
                releasePermissions(of: sid, into: &i)
            case "UserPromptSubmit":
                i.lastPromptAt = Date()
                releasePermissions(of: sid, into: &i)
                cancelReply(sid, into: &i) // you typed somewhere else
            case "SessionEnd":
                releasePermissions(of: sid, into: &i)
                cancelReply(sid, into: &i)
                info[sid] = nil
                onChange(info)
                return
            default:
                break
            }
        }
        info[sid] = i
        onChange(info)
    }

    /// Signed by the helper with our shared secret, recent, and never seen before.
    private func authentic(_ request: HookServer.Request) -> Bool {
        let h = { (name: String) in request.headers[name.lowercased()] }
        guard let nonce = h(HookAuth.nonceHeader), (16...128).contains(nonce.count),
              let time = h(HookAuth.timeHeader).flatMap(Int.init),
              abs(Date().timeIntervalSince1970 - Double(time)) <= HookAuth.maxAge,
              HookAuth.matches(h(HookAuth.signatureHeader),
                               HookAuth.requestSignature(secret: token, path: request.path, time: time, nonce: nonce, body: request.body))
        else { return false }
        let cutoff = Date().addingTimeInterval(-2 * HookAuth.maxAge)
        seenNonces = seenNonces.filter { $0.value > cutoff }
        guard seenNonces[nonce] == nil else { return false }
        seenNonces[nonce] = Date()
        return true
    }

    // MARK: - Your answers

    @discardableResult
    func allow(_ requestId: String, always: Bool = false, answers: [String: String]? = nil) -> Bool {
        guard let input = permissionInputs[requestId], let tool = pendingTool(requestId) else { return false }
        var decision: [String: Any] = ["behavior": "allow"]
        if tool == "AskUserQuestion" {
            var updated = input
            updated["answers"] = answers ?? [:]
            decision["updatedInput"] = updated
        } else if tool == "ExitPlanMode" {
            decision["updatedInput"] = input // required for tools that need you
        }
        if always, let suggestions = permissionSuggestions[requestId], !suggestions.isEmpty {
            decision["updatedPermissions"] = suggestions
        }
        return answer(requestId, decision)
    }

    @discardableResult
    func deny(_ requestId: String, note: String) -> Bool {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmed.isEmpty
            ? "The user denied this from the ClaudeNotch notch."
            : "The user denied this from the ClaudeNotch notch and said: \(trimmed)"
        return answer(requestId, ["behavior": "deny", "message": message])
    }

    /// Wakes Claude with your text (through the asyncRewake Stop hook that is waiting).
    @discardableResult
    func reply(_ sid: String, text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let exchange = replyExchanges.removeValue(forKey: sid),
              let json = try? JSONSerialization.data(withJSONObject: ["reply": String(clean.prefix(8000))]) else { return false }
        exchange.respond(json: json)
        replySince[sid] = nil
        if var i = info[sid] {
            i.replyWaiting = false
            i.lastPromptAt = Date()
            info[sid] = i
        }
        onChange(info)
        return true
    }

    /// Let go of requests that were answered somewhere else, using the live session status.
    func reconcile(with sessions: [ClaudeSession]) {
        var changed = false
        for s in sessions {
            guard var i = info[s.id] else { continue }
            // Permission answered in the app or terminal: the session left "waiting" after the request came in.
            if !i.permissions.isEmpty, s.status != "waiting", s.entrypoint != "hook" {
                let stale = i.permissions.filter { s.statusSince > $0.receivedAt && Date().timeIntervalSince($0.receivedAt) > 2 }
                for p in stale {
                    permissionExchanges.removeValue(forKey: p.requestId)?.respond()
                    forgetPermissionState(p.requestId)
                }
                if !stale.isEmpty {
                    i.permissions.removeAll { p in stale.contains { $0.requestId == p.requestId } }
                    changed = true
                }
            }
            // You started a new turn elsewhere: the reply wait from the previous turn is over.
            if i.replyWaiting, s.status == "busy" || s.status == "shell", let since = replySince[s.id], s.statusSince > since.addingTimeInterval(1) {
                cancelReply(s.id, into: &i)
                changed = true
            }
            info[s.id] = i
        }
        // Hook-only sessions that went quiet long ago.
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        for (sid, i) in info where i.lastEventAt < cutoff && i.permissions.isEmpty && !i.replyWaiting {
            info[sid] = nil
            changed = true
        }
        if changed { onChange(info) }
    }

    /// Hand everything back to Claude Code's own dialogs (hooks turned off, or the app is quitting).
    func releaseAll() {
        permissionExchanges.values.forEach { $0.respond() }
        replyExchanges.values.forEach { $0.respond() }
        permissionExchanges.removeAll()
        replyExchanges.removeAll()
        permissionInputs.removeAll()
        permissionSuggestions.removeAll()
        permissionSessions.removeAll()
        replySince.removeAll()
        for id in info.keys {
            info[id]?.permissions.removeAll()
            info[id]?.replyWaiting = false
        }
        onChange(info)
    }

    // MARK: - Internals

    private func pendingTool(_ requestId: String) -> String? {
        guard let sid = permissionSessions[requestId] else { return nil }
        return info[sid]?.permissions.first { $0.requestId == requestId }?.toolName
    }

    private func answer(_ requestId: String, _ decision: [String: Any]) -> Bool {
        guard let exchange = permissionExchanges.removeValue(forKey: requestId), exchange.isOpen,
              let json = try? JSONSerialization.data(withJSONObject: [
                  "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]
              ]) else {
            forgetPermission(requestId)
            return false
        }
        exchange.respond(json: json)
        forgetPermission(requestId)
        return true
    }

    private func releasePermissions(of sid: String, into i: inout HookInfo) {
        for p in i.permissions {
            permissionExchanges.removeValue(forKey: p.requestId)?.respond()
            forgetPermissionState(p.requestId)
        }
        i.permissions.removeAll()
    }

    private func cancelReply(_ sid: String, into i: inout HookInfo) {
        replyExchanges.removeValue(forKey: sid)?.respond()
        replySince[sid] = nil
        i.replyWaiting = false
    }

    private func forgetPermission(_ requestId: String) {
        let sid = permissionSessions[requestId]
        permissionExchanges[requestId] = nil
        forgetPermissionState(requestId)
        if let sid, var i = info[sid] {
            i.permissions.removeAll { $0.requestId == requestId }
            info[sid] = i
            onChange(info)
        }
    }

    private func forgetPermissionState(_ requestId: String) {
        permissionInputs[requestId] = nil
        permissionSuggestions[requestId] = nil
        permissionSessions[requestId] = nil
    }

    private func forgetReply(_ sid: String) {
        replyExchanges[sid] = nil
        replySince[sid] = nil
        if var i = info[sid] {
            i.replyWaiting = false
            info[sid] = i
            onChange(info)
        }
    }

    // MARK: - Describing a request

    private static func alwaysLabel(_ suggestions: [Any]) -> String? {
        let entries = suggestions.compactMap { $0 as? [String: Any] }
        if entries.contains(where: { $0["type"] as? String == "setMode" && $0["mode"] as? String == "acceptEdits" }) {
            return "Allow all edits"
        }
        if entries.contains(where: { $0["type"] as? String == "addRules" }) { return "Always allow" }
        return nil
    }

    static func detail(tool: String, input: [String: Any]) -> PermissionDetail {
        let path = input["file_path"] as? String ?? input["notebook_path"] as? String
        let file = path.map { ($0 as NSString).lastPathComponent } ?? "a file"
        func lines(_ text: String?, _ kind: DiffLine.Kind, max: Int) -> [DiffLine] {
            (text ?? "").components(separatedBy: "\n").prefix(max).map { DiffLine(kind: kind, text: $0) }
        }

        switch tool {
        case "Bash", "PowerShell":
            let command = input["command"] as? String ?? ""
            let lines = command.components(separatedBy: "\n")
            let more = lines.count > 1 ? " (+\(lines.count - 1) more line\(lines.count == 2 ? "" : "s"))" : ""
            return PermissionDetail(kind: .command, title: "Run a command", summary: "Run: \(lines.first ?? command)\(more)",
                                    body: command, note: input["description"] as? String)
        case "Edit":
            let diff = lines(input["old_string"] as? String, .removed, max: 30) + lines(input["new_string"] as? String, .added, max: 30)
            return PermissionDetail(kind: .edit, title: "Edit \(file)", summary: "Edit \(file)", body: "", note: path, diff: diff)
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            let diff = edits.prefix(4).flatMap {
                lines($0["old_string"] as? String, .removed, max: 12) + lines($0["new_string"] as? String, .added, max: 12)
            }
            return PermissionDetail(kind: .edit, title: "Edit \(file)", summary: "Edit \(file) (\(edits.count) changes)", body: "", note: path, diff: diff)
        case "Write":
            return PermissionDetail(kind: .edit, title: "Write \(file)", summary: "Write \(file)", body: "", note: path,
                                    diff: lines(input["content"] as? String, .added, max: 40))
        case "NotebookEdit":
            return PermissionDetail(kind: .edit, title: "Edit \(file)", summary: "Edit \(file)", body: "", note: path,
                                    diff: lines(input["new_source"] as? String, .added, max: 40))
        case "WebFetch":
            let url = input["url"] as? String ?? ""
            let host = URL(string: url)?.host ?? url
            return PermissionDetail(kind: .fetch, title: "Fetch \(host)", summary: "Fetch \(host)", body: url, note: input["prompt"] as? String)
        case "WebSearch":
            let query = input["query"] as? String ?? ""
            return PermissionDetail(kind: .fetch, title: "Search the web", summary: "Search: \(query)", body: query, note: nil)
        case "AskUserQuestion":
            let questions = (input["questions"] as? [[String: Any]] ?? []).map { q in
                AskQuestion(question: q["question"] as? String ?? "", header: q["header"] as? String ?? "",
                            multiSelect: q["multiSelect"] as? Bool ?? false,
                            options: (q["options"] as? [[String: Any]] ?? []).map {
                                AskOption(label: $0["label"] as? String ?? "", description: $0["description"] as? String ?? "")
                            })
            }
            return PermissionDetail(kind: .question, title: "Claude has a question", summary: questions.first?.question ?? "Has a question for you",
                                    body: "", note: nil, questions: questions)
        case "ExitPlanMode":
            return PermissionDetail(kind: .plan, title: "Plan ready for review", summary: "Plan ready for your review",
                                    body: "", note: nil, plan: input["plan"] as? String ?? "")
        default:
            let pretty = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let name = tool.hasPrefix("mcp__") ? (tool.components(separatedBy: "__").last ?? tool).replacingOccurrences(of: "_", with: " ") : tool
            return PermissionDetail(kind: .other, title: "Use \(name)", summary: "Use \(name)", body: String(pretty.prefix(3000)),
                                    note: tool.hasPrefix("mcp__") ? tool : nil)
        }
    }
}
