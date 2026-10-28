import Foundation
import Testing
@testable import ClaudeNotch

@Suite struct TranscriptTests {
    /// Writes compact JSONL, the way Claude Code does, and summarizes it.
    private func summary(_ entries: [[String: Any]], needsText: Bool = true) throws -> TranscriptSummary {
        let lines = try entries.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        return Transcript.summarize(url, mtime: Date(), size: size, needsText: needsText)
    }

    private func prompt(_ text: String) -> [String: Any] {
        ["type": "user", "message": ["role": "user", "content": text]]
    }
    private func reply(_ text: String) -> [String: Any] {
        ["type": "assistant", "message": ["content": [["type": "text", "text": text]]]]
    }
    private func tool(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "assistant", "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]]]
    }
    private func result(_ id: String, error: Bool = false) -> [String: Any] {
        ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": id, "is_error": error, "content": "…"]]]]
    }

    @Test func finishedTurnIsDone() throws {
        let s = try summary([prompt("Fix the build"), tool("t1", "Bash", ["command": "make", "description": "Build it"]),
                             result("t1"), reply("**Done.** The build passes now.")])
        #expect(s.outcome == .done)
        #expect(s.lastText == "Done. The build passes now.")
        #expect(s.lastPrompt == "Fix the build")
        #expect(s.steps == [Step(label: "Build it", result: .done)])
    }

    @Test func replyThatAsksIsAQuestion() throws {
        let s = try summary([prompt("Write the copy"), reply("Drafted it.\n\nShould the page default to annual or monthly prices?")])
        #expect(s.outcome == .question)
    }

    @Test func apiErrorIsAnError() throws {
        var failure = reply("API Error: Rate limit reached")
        failure["isApiErrorMessage"] = true
        let s = try summary([prompt("Export invoices"), failure])
        #expect(s.outcome == .error("API Error: Rate limit reached"))
    }

    @Test func aRetryThatWorkedIsNotAnError() throws {
        var failure = reply("API Error: Overloaded")
        failure["isApiErrorMessage"] = true
        let s = try summary([prompt("Export invoices"), failure, reply("Exported 42 invoices.")])
        #expect(s.outcome == .done)
    }

    @Test func interruptionIsNotDone() throws {
        let s = try summary([prompt("Refactor"), tool("t1", "Read", ["file_path": "/a/b.swift"]),
                             ["type": "user", "message": ["content": [["type": "text", "text": "[Request interrupted by user]"]]]]])
        #expect(s.outcome == .interrupted)
    }

    @Test func runningToolIsTheCurrentStep() throws {
        let s = try summary([prompt("Split routes"), tool("a", "Read", ["file_path": "/x/routes.ts"]), result("a"),
                             tool("b", "Bash", ["command": "npm test"]), result("b", error: true),
                             tool("c", "Edit", ["file_path": "/x/users.ts"])], needsText: false)
        #expect(s.tool?.label == "Editing users.ts")
        #expect(s.toolResolved == false)
        #expect(s.steps.map(\.result) == [.done, .failed, .running])
    }

    @Test func desktopWrapUpQuestionWins() throws {
        let s = try summary([prompt("Ship it"),
                             tool("w", "mcp__ccd_turn__wrap_up", ["recap": "Shipped v2 to staging.", "ask": "Promote to production?",
                                                                 "actions": [["label": "Yes", "message": "Promote it"], ["label": "Commit", "action": "commit"]]]),
                             result("w"), reply("All set — staging is live.")])
        #expect(s.outcome == .question)
        #expect(s.ask == "Promote to production?")
        #expect(s.actions == [ReplyAction(label: "Yes", message: "Promote it")]) // app actions are not replies
        #expect(s.message == "All set — staging is live.")
    }

    @Test func injectedTextIsNotYourPrompt() throws {
        let s = try summary([prompt("Real question"), prompt("<system-reminder>noise</system-reminder>"), reply("Answer.")])
        #expect(s.lastPrompt == "Real question")
    }

    @Test(arguments: [
        ("Want me to also add tests?", true),
        ("Which option do you prefer?", true),
        ("Let me know if anything looks off.", true),
        ("Done. All 12 tests pass.", false),
        ("Why does this fail? Because the path was wrong.\nFixed it.", false),
        ("```\nwhat is this?\n```\nDone.", false),
    ])
    func detectsQuestions(text: String, asks: Bool) {
        #expect(Transcript.asksSomething(text) == asks)
    }

    @Test func cleanStripsMarkdown() {
        #expect(Transcript.clean("## **Done** — see [the preview](https://x.dev) and `make`") == "Done — see the preview and make")
    }
}

@Suite struct PermissionDetailTests {
    @Test func bashShowsTheCommand() {
        let d = HookHub.detail(tool: "Bash", input: ["command": "git push --force-with-lease\necho done", "description": "Push"])
        #expect(d.kind == .command)
        #expect(d.summary == "Run: git push --force-with-lease (+1 more line)")
        #expect(d.body.contains("echo done"))
        #expect(d.note == "Push")
    }

    @Test func editShowsADiff() {
        let d = HookHub.detail(tool: "Edit", input: ["file_path": "/a/App.swift", "old_string": "let a = 1", "new_string": "let a = 2\nlet b = 3"])
        #expect(d.title == "Edit App.swift")
        #expect(d.diff.map(\.kind) == [.removed, .added, .added])
    }

    @Test func questionsKeepTheirOptions() {
        let d = HookHub.detail(tool: "AskUserQuestion", input: ["questions": [[
            "question": "Which layout?", "header": "Layout", "multiSelect": false,
            "options": [["label": "Split", "description": "Two columns"], ["label": "Minimal", "description": ""]],
        ]]])
        #expect(d.kind == .question)
        #expect(d.questions.first?.options.map(\.label) == ["Split", "Minimal"])
    }
}
