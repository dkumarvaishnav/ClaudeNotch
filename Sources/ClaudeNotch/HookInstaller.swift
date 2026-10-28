import Foundation
import Darwin

/// Adds (or removes) ClaudeNotch's hooks in `~/.claude/settings.json`, next to whatever hooks are already there.
///
/// The file is edited with an order-preserving JSON model: every other setting keeps its value, its order and
/// its exact text (strings, numbers), laid out the way Claude Code itself writes the file (2-space JSON).
/// Every change is checked (only "hooks" may differ) and the previous file is kept as a backup.
enum HookInstaller {
    #if DEBUG
    // Debug builds can point at a fake home so tests never touch your real settings.
    static let home = ProcessInfo.processInfo.environment["CLAUDENOTCH_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser
    #else
    static let home = FileManager.default.homeDirectoryForCurrentUser
    #endif
    static let settingsFile = home.appendingPathComponent(".claude/settings.json")
    static let helperFile = home.appendingPathComponent(".claude/hooks/claudenotch-hook")
    // The helper always reads the token from the real home, so it lives there.
    static let supportDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ClaudeNotch")
    static let tokenFile = supportDir.appendingPathComponent("token")

    /// Events we listen to, and how the helper is run for each.
    private static func hooks() -> [(event: String, hooks: [[String: Any]])] {
        let helper = helperFile.path
        let event: [String: Any] = ["type": "command", "command": command("event", helper: helper), "async": true, "timeout": 10]
        return [
            // Held open until you answer in the notch; Claude Code's own dialog stays usable meanwhile.
            ("PermissionRequest", [["type": "command", "command": command("permission", helper: helper), "timeout": 3600]]),
            ("Stop", [event, ["type": "command", "command": command("wait", helper: helper), "asyncRewake": true, "timeout": 6 * 3600]]),
            ("StopFailure", [event]),
            ("UserPromptSubmit", [event]),
            // Not async: Claude Code kills background hooks when a session exits.
            ("SessionEnd", [["type": "command", "command": command("event", helper: helper), "timeout": 5]]),
        ]
    }

    /// The shell command for one hook, with the helper path quoted (homes can contain spaces or quotes).
    static func command(_ mode: String, helper: String) -> String {
        "'" + helper.replacingOccurrences(of: "'", with: "'\\''") + "' " + mode
    }

    private static func isOurs(_ hook: JSONNode) -> Bool {
        hook["command"]?.stringValue?.contains("claudenotch-hook") == true
    }

    // MARK: - Token and helper

    static func token() -> String {
        if let saved = try? String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           saved.count == 48 { return saved }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let fresh = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tokenFile.path, contents: Data(fresh.utf8), attributes: [.posixPermissions: 0o600])
        return fresh
    }

    /// Copies the helper next to the app's executable into ~/.claude/hooks, so hooks keep a stable path.
    static func installHelper() throws {
        let fm = FileManager.default
        guard let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("claudenotch-hook"),
              fm.fileExists(atPath: bundled.path) else { throw InstallError("The hook helper is missing from the app.") }
        if fm.contentsEqual(atPath: bundled.path, andPath: helperFile.path) { return }
        try fm.createDirectory(at: helperFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = helperFile.appendingPathExtension("new")
        try? fm.removeItem(at: temp)
        try fm.copyItem(at: bundled, to: temp)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
        guard rename(temp.path, helperFile.path) == 0 else { throw InstallError("Could not install the hook helper.") }
    }

    // MARK: - settings.json

    /// Our hooks are all there, exactly as this version writes them (wherever they sit in each list).
    static func isInstalled() -> Bool {
        guard let root = try? readSettings() else { return false }
        var expected: [String: [JSONNode]] = [:]
        for (event, list) in hooks() { expected[event] = list.map(JSONNode.from) }
        return ourHooks(in: root) == expected
    }

    /// Any ClaudeNotch hook at all (possibly from an older version).
    static func hasAnyOfOurs() -> Bool {
        guard let root = try? readSettings() else { return false }
        return !ourHooks(in: root).isEmpty
    }

    private static func ourHooks(in root: JSONNode) -> [String: [JSONNode]] {
        guard case .object(let events)? = root["hooks"] else { return [:] }
        var found: [String: [JSONNode]] = [:]
        for member in events {
            guard case .array(let groups) = member.value else { continue }
            let ours = groups.flatMap { group -> [JSONNode] in
                guard case .array(let list)? = group["hooks"] else { return [] }
                return list.filter(isOurs)
            }
            if !ours.isEmpty { found[member.key] = ours }
        }
        return found
    }

    static func install() throws {
        _ = token()
        try installHelper()
        try update(install: true)
    }

    static func uninstall() throws {
        try update(install: false)
    }

    private static func update(install: Bool) throws {
        // Write through a symlinked settings.json (dotfile setups) instead of replacing the link.
        let target = try settingsTarget()
        let before = modificationDate(target)
        let originalData = try readSettingsData()
        let original = try parse(originalData)
        guard let updated = render(applying: install, to: original) else { return }
        if updated == original { return }
        try check(original: original, updated: updated)
        let text = updated.serialized() + "\n"
        let fm = FileManager.default
        // Keep the file as private as it was (settings can hold API keys).
        let permissions = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber ?? 0o644
        if let originalData {
            let backup = settingsFile.appendingPathExtension("claudenotch-backup")
            try originalData.write(to: backup) // the contents, even when settings.json is a symlink
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: backup.path)
        } else {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let temp = target.appendingPathExtension("claudenotch-tmp")
        try Data(text.utf8).write(to: temp)
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
        // Claude Code (or you) saved the file while we were working: keep their version, try again next launch.
        guard modificationDate(target) == before else {
            try? fm.removeItem(at: temp)
            throw InstallError("~/.claude/settings.json changed while it was being updated, so it was left alone. Try again.")
        }
        guard rename(temp.path, target.path) == 0 else { throw InstallError("Could not save ~/.claude/settings.json.") }
    }

    /// nil when there is no settings file yet. Any other read problem is an error: never treat an unreadable
    /// file as empty, or the next save would wipe it.
    /// The real file behind settings.json. A link to a missing file is an error, not "no settings yet":
    /// writing there would replace someone's dotfiles link with a plain file.
    private static func settingsTarget() throws -> URL {
        let fm = FileManager.default
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: settingsFile.path) else { return settingsFile }
        let target = URL(fileURLWithPath: destination, relativeTo: settingsFile.deletingLastPathComponent()).standardizedFileURL
        guard fm.fileExists(atPath: target.path) else {
            throw InstallError("~/.claude/settings.json links to \(destination), which doesn't exist, so it was left alone.")
        }
        return target.resolvingSymlinksInPath()
    }

    private static func readSettingsData() throws -> Data? {
        let target = try settingsTarget()
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        do { return try Data(contentsOf: target) }
        catch { throw InstallError("~/.claude/settings.json could not be read, so it was left alone.") }
    }

    private static func parse(_ data: Data?) throws -> JSONNode {
        guard let data else { return .object([]) }
        guard let node = JSONNode.parse(data) else { throw InstallError("~/.claude/settings.json is not valid JSON, so it was left alone.") }
        return node
    }

    private static func readSettings() throws -> JSONNode {
        try parse(try readSettingsData())
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// The settings with our hooks added (or removed). nil if the file's shape is unexpected.
    static func render(applying install: Bool, to root: JSONNode) -> JSONNode? {
        guard case .object = root else { return nil }
        var hooksNode = root["hooks"] ?? .object([])
        guard case .object = hooksNode else { return nil }

        // Remove ours everywhere, keeping everyone else's hooks and groups in place.
        if case .object(let events) = hooksNode {
            var kept: [JSONNode.Member] = []
            for member in events {
                guard case .array(let groups) = member.value else { kept.append(member); continue }
                let cleaned: [JSONNode] = groups.compactMap { group in
                    guard case .array(let list)? = group["hooks"] else { return group }
                    let others = list.filter { !isOurs($0) }
                    if others.count == list.count { return group }
                    return others.isEmpty ? nil : group.setting("hooks", .array(others))
                }
                if !cleaned.isEmpty || groups.isEmpty { kept.append(.init(key: member.key, value: .array(cleaned))) }
            }
            hooksNode = .object(kept)
        }

        if install {
            for (event, list) in hooks() {
                let group = JSONNode.from(["hooks": list])
                if case .array(let groups)? = hooksNode[event] {
                    hooksNode = hooksNode.setting(event, .array(groups + [group]))
                } else {
                    hooksNode = hooksNode.setting(event, .array([group]))
                }
            }
        }

        // Uninstalling left an empty "hooks" that only held ours: drop the key, as before we added it.
        if !install, case .object(let events) = hooksNode, events.isEmpty, !ourHooks(in: root).isEmpty {
            return root.removing("hooks")
        }
        if root["hooks"] == nil, case .object(let events) = hooksNode, events.isEmpty { return root }
        return root.setting("hooks", hooksNode)
    }

    /// Safety net: everything except "hooks" must be untouched, and the result must be valid JSON.
    private static func check(original: JSONNode, updated: JSONNode) throws {
        let text = updated.serialized()
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary,
              let before = try? JSONSerialization.jsonObject(with: Data(original.serialized().utf8)) as? NSDictionary else {
            throw InstallError("Could not produce valid settings, so nothing was changed.")
        }
        let a = before.mutableCopy() as! NSMutableDictionary
        let b = parsed.mutableCopy() as! NSMutableDictionary
        a.removeObject(forKey: "hooks")
        b.removeObject(forKey: "hooks")
        guard a == b else { throw InstallError("A change outside \"hooks\" was about to happen, so nothing was changed.") }
    }

    struct InstallError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

// MARK: - Order-preserving JSON

/// JSON that remembers key order and the exact text of every scalar, so a file can be edited without
/// reformatting anything that was not changed. Serializes like `JSON.stringify(value, null, 2)`.
indirect enum JSONNode: Equatable {
    struct Member: Equatable {
        var key: String      // decoded, for lookups
        var rawKey: String   // as written, quotes included
        var value: JSONNode

        init(key: String, rawKey: String? = nil, value: JSONNode) {
            self.key = key
            self.rawKey = rawKey ?? JSONNode.quote(key)
            self.value = value
        }
    }

    case object([Member])
    case array([JSONNode])
    case scalar(String)      // raw text: "string", 12.5, true, false, null

    subscript(key: String) -> JSONNode? {
        guard case .object(let members) = self else { return nil }
        return members.last { $0.key == key }?.value
    }

    var stringValue: String? {
        guard case .scalar(let raw) = self, raw.hasPrefix("\"") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) as? String
    }

    func setting(_ key: String, _ value: JSONNode) -> JSONNode {
        guard case .object(var members) = self else { return self }
        if let index = members.lastIndex(where: { $0.key == key }) { members[index].value = value }
        else { members.append(Member(key: key, value: value)) }
        return .object(members)
    }

    func removing(_ key: String) -> JSONNode {
        guard case .object(let members) = self else { return self }
        return .object(members.filter { $0.key != key })
    }

    static func quote(_ string: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    /// From plain Swift values (dictionaries keep the order of `keyOrder`, then sorted).
    static func from(_ value: Any) -> JSONNode {
        switch value {
        case let dict as [String: Any]:
            let order = ["type", "command", "async", "asyncRewake", "timeout", "hooks"]
            let keys = dict.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
            return .object(keys.map { Member(key: $0, value: from(dict[$0]!)) })
        case let array as [Any]:
            return .array(array.map(from))
        case let string as String:
            return .scalar(quote(string))
        case let bool as Bool:
            return .scalar(bool ? "true" : "false")
        case let number as Int:
            return .scalar(String(number))
        case let number as Double:
            return .scalar(String(number))
        default:
            return .scalar("null")
        }
    }

    func serialized(indent: Int = 0) -> String {
        let pad = String(repeating: " ", count: indent + 2), end = String(repeating: " ", count: indent)
        switch self {
        case .scalar(let raw):
            return raw
        case .array(let items):
            if items.isEmpty { return "[]" }
            return "[\n" + items.map { pad + $0.serialized(indent: indent + 2) }.joined(separator: ",\n") + "\n" + end + "]"
        case .object(let members):
            if members.isEmpty { return "{}" }
            return "{\n" + members.map { pad + $0.rawKey + ": " + $0.value.serialized(indent: indent + 2) }.joined(separator: ",\n") + "\n" + end + "}"
        }
    }

    // MARK: Parsing

    static func parse(_ data: Data) -> JSONNode? {
        var parser = Parser(bytes: [UInt8](data))
        guard let node = parser.value() else { return nil }
        parser.skipSpace()
        return parser.index == parser.bytes.count ? node : nil
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value() -> JSONNode? {
            skipSpace()
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"): return object()
            case UInt8(ascii: "["): return array()
            case UInt8(ascii: "\""): return string().map { .scalar($0) }
            default: return literal()
            }
        }

        mutating func object() -> JSONNode? {
            index += 1
            var members: [Member] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object([]) }
            while true {
                skipSpace()
                guard let rawKey = string(), let key = JSONNode.scalar(rawKey).stringValue else { return nil }
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
                index += 1
                guard let value = value() else { return nil }
                members.append(Member(key: key, rawKey: rawKey, value: value))
                skipSpace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                return nil
            }
        }

        mutating func array() -> JSONNode? {
            index += 1
            var items: [JSONNode] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array([]) }
            while true {
                guard let item = value() else { return nil }
                items.append(item)
                skipSpace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                return nil
            }
        }

        /// Raw string token, quotes included.
        mutating func string() -> String? {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
            let start = index
            index += 1
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"): index += 2
                case UInt8(ascii: "\""):
                    index += 1
                    return String(decoding: bytes[start..<index], as: UTF8.self)
                default: index += 1
                }
            }
            return nil
        }

        mutating func literal() -> JSONNode? {
            let start = index
            while index < bytes.count, !",]} \t\n\r".utf8.contains(bytes[index]) { index += 1 }
            guard index > start else { return nil }
            let raw = String(decoding: bytes[start..<index], as: UTF8.self)
            // JSON's own number grammar: Double() would also accept "nan", "inf", "0x1p3", "+1"…
            let number = #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#
            guard raw == "true" || raw == "false" || raw == "null" || raw.range(of: number, options: .regularExpression) != nil else { return nil }
            return .scalar(raw)
        }
    }
}
