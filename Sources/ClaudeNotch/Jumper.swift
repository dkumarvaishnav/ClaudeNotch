import AppKit

/// Brings you to the place a session lives: the Claude desktop app, or the terminal / editor that runs it.
enum Jumper {
    static func jump(to session: ClaudeSession) {
        if session.isDesktop, let host = session.hostSessionId,
           let url = URL(string: "claude://code/continue?session=\(host)") {
            NSWorkspace.shared.open(url)
            return
        }
        // CLI sessions: walk up the process tree to the first real app (Terminal, iTerm, Ghostty, VS Code, ...).
        var pid = session.pid
        for _ in 0..<16 {
            guard let parent = Proc.parent(of: pid), parent > 1 else { break }
            if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular {
                activate(app)
                return
            }
            pid = parent
        }
    }

    static func newSession() {
        if let url = URL(string: "claude://code/new") { NSWorkspace.shared.open(url) }
    }

    private static func activate(_ app: NSRunningApplication) {
        guard let bundle = app.bundleURL else {
            app.activate()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: bundle, configuration: config)
    }
}
