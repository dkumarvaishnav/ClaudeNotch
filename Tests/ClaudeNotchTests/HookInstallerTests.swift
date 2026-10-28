import Foundation
import Testing
@testable import ClaudeNotch

/// The settings.json editor must never change anything it doesn't own.
@Suite struct HookInstallerTests {
    /// Written the way Claude Code writes it (JSON.stringify, 2 spaces), with someone else's hooks,
    /// escapes, an empty array and a number that a naive re-encode would change.
    let original = """
    {
      "env": {
        "GREETING": "h\\u00e9llo\\n\\"quoted\\""
      },
      "permissions": {
        "allow": [],
        "deny": []
      },
      "model": "opus",
      "ratio": 1.50,
      "hooks": {
        "Stop": [
          {
            "matcher": ".*",
            "hooks": [
              {
                "type": "command",
                "command": "'/Users/me/Other Tool/stop.cjs'"
              }
            ]
          }
        ]
      }
    }
    """

    private func parse(_ text: String) throws -> JSONNode {
        try #require(JSONNode.parse(Data(text.utf8)))
    }

    @Test func roundTripsByteForByte() throws {
        #expect(try parse(original).serialized() == original)
    }

    @Test func installAddsOursAndKeepsEverythingElse() throws {
        let installed = try #require(HookInstaller.render(applying: true, to: try parse(original)))
        let text = installed.serialized()
        #expect(text.contains("'/Users/me/Other Tool/stop.cjs'"))
        #expect(text.contains("\"ratio\": 1.50"))
        #expect(text.contains("h\\u00e9llo"))
        for mode in ["permission", "event", "wait"] { #expect(text.contains("claudenotch-hook' \(mode)")) }
        // The other tool's Stop hook stays first; ours come after it.
        let stop = try #require(installed["hooks"]?["Stop"])
        guard case .array(let groups) = stop else { Issue.record("Stop is not an array"); return }
        #expect(groups.count == 2)
        #expect(groups[0]["matcher"]?.stringValue == ".*")
    }

    @Test func uninstallRestoresTheOriginalExactly() throws {
        let installed = try #require(HookInstaller.render(applying: true, to: try parse(original)))
        let removed = try #require(HookInstaller.render(applying: false, to: installed))
        #expect(removed.serialized() == original)
    }

    @Test func installingTwiceChangesNothing() throws {
        let once = try #require(HookInstaller.render(applying: true, to: try parse(original)))
        #expect(HookInstaller.render(applying: true, to: once) == once)
    }

    @Test func fileWithoutHooksGetsThemAndLosesThemAgain() throws {
        let bare = "{\n  \"model\": \"opus\"\n}"
        let installed = try #require(HookInstaller.render(applying: true, to: try parse(bare)))
        #expect(installed["hooks"] != nil)
        let removed = try #require(HookInstaller.render(applying: false, to: installed))
        #expect(removed.serialized() == bare)
    }

    @Test func refusesWhatIsNotPlainJSON() {
        #expect(JSONNode.parse(Data("{ // a comment\n \"a\": 1 }".utf8)) == nil)
        #expect(JSONNode.parse(Data("{ \"a\": 1, }".utf8)) == nil)
        #expect(JSONNode.parse(Data("{ \"a\": NaN }".utf8)) == nil)
    }

    @Test func helperPathIsQuotedForHomesWithSpaces() {
        let command = HookInstaller.command("permission", helper: "/Users/Jane Doe/.claude/hooks/claudenotch-hook")
        #expect(command == "'/Users/Jane Doe/.claude/hooks/claudenotch-hook' permission")
        #expect(HookInstaller.command("event", helper: "/Users/o'brien/h") == "'/Users/o'\\''brien/h' event")
    }
}
