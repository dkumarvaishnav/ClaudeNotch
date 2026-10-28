import AppKit
import Combine
import ServiceManagement

enum Settings {
    private static let defaults = UserDefaults.standard

    static var sounds: Bool {
        get { defaults.object(forKey: "sounds") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sounds") }
    }
    /// Pop open when a session finishes, fails or needs you.
    static var peek: Bool {
        get { defaults.object(forKey: "peek") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "peek") }
    }
    static var allDisplays: Bool {
        get { defaults.object(forKey: "allDisplays") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "allDisplays") }
    }
    /// Allow/Deny, answers and replies from the notch (needs ClaudeNotch's hooks in ~/.claude/settings.json).
    /// nil until you've been asked.
    static var hooks: Bool? {
        get { defaults.object(forKey: "hooks") as? Bool }
        set { defaults.set(newValue, forKey: "hooks") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, AppActions {
    #if DEBUG
    // Point a debug build at a fake ~/.claude to test state changes without touching real sessions.
    private let store = SessionStore(home: ProcessInfo.processInfo.environment["CLAUDENOTCH_HOME"].map { URL(fileURLWithPath: $0) }
                                     ?? FileManager.default.homeDirectoryForCurrentUser)
    #else
    private let store = SessionStore()
    #endif
    private let server = HookServer()
    private lazy var hub = HookHub(token: HookInstaller.token())
    private var controllers: [NotchController] = []
    private var monitors: [Any] = []
    private var tick: Timer?
    private var bag = Set<AnyCancellable>()
    private var hookProblem: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One notch is enough: a second copy would fight the first for the hook port.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
            NSApp.terminate(nil)
            return
        }
        hub.onChange = { [weak self] info in self?.store.update(hooks: info) }
        server.onRequest = { [weak self] request, exchange in self?.hub.handle(request, exchange) }
        server.start()
        askAboutHooksIfNeeded()
        applyHookSetting()

        store.start()
        rebuildPanels()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.rebuildPanels() }

        store.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &bag)
        // Requests answered in the app or terminal are let go as soon as the session moves on.
        store.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in self?.hub.reconcile(with: sessions) }
            .store(in: &bag)

        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in self?.trackMouse() }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] e in self?.trackMouse(); return e }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            let p = NSEvent.mouseLocation
            self?.controllers.forEach { $0.mouseDown(at: p) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            (self?.controllers.contains { $0.keyDown(e) } ?? false) ? nil : e
        }) { monitors.append(m) }
        // Mouse events alone miss hover delays and timed peeks, so check a few times a second too.
        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.trackMouse() }

        #if DEBUG
        // Remote control for testing. Opt-in, since any local process could post these notifications.
        if ProcessInfo.processInfo.environment["CLAUDENOTCH_DEBUG"] == "1" {
            DebugHooks.install(controllers: { [weak self] in self?.controllers ?? [] }, store: store, app: self)
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        hub.releaseAll() // anything still held goes back to Claude Code's own dialog
    }

    private func trackMouse() {
        let p = NSEvent.mouseLocation
        let now = Date()
        controllers.forEach { $0.update(mouse: p, now: now) }
    }

    private func rebuildPanels() {
        controllers.forEach { $0.teardown() }
        let screens: [NSScreen]
        if Settings.allDisplays {
            screens = NSScreen.screens
        } else {
            let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            screens = [notched ?? NSScreen.main].compactMap { $0 }
        }
        controllers = screens.map { NotchController(screen: $0, store: store, app: self) }
    }

    private func handle(_ event: SessionEvent) {
        let session = event.session
        #if DEBUG
        NSLog("ClaudeNotch attention: \(session.state) \(session.title) — \(session.activity)")
        #endif
        if Settings.sounds {
            let sound: String
            switch session.state {
            case .needsInput: sound = "Ping"
            case .error: sound = "Basso"
            default: sound = "Glass"
            }
            NSSound(named: sound)?.play()
        }
        guard Settings.peek else { return }
        // Show it where you are looking: the display under the pointer.
        let p = NSEvent.mouseLocation
        let target = controllers.first { NSMouseInRect(p, $0.screen.frame, false) } ?? controllers.first
        target?.peek()
    }

    // MARK: - Hooks

    /// The first time, ask before touching ~/.claude/settings.json (unless an earlier version already did).
    private func askAboutHooksIfNeeded() {
        guard Settings.hooks == nil else { return }
        if HookInstaller.hasAnyOfOurs() {
            Settings.hooks = true
            return
        }
        let alert = NSAlert()
        alert.messageText = "Answer Claude from the notch?"
        alert.informativeText = [
            "ClaudeNotch shows every Claude Code session without any setup.",
            "To also Allow or Deny requests, answer Claude's questions and reply from the notch, it adds a few hooks "
                + "to ~/.claude/settings.json. Your other settings and hooks are kept as they are, a backup is saved, "
                + "and you can turn this off any time from the notch's menu.",
        ].joined(separator: "\n\n")
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        Settings.hooks = alert.runModal() == .alertFirstButtonReturn
    }

    private func applyHookSetting() {
        do {
            if Settings.hooks == true {
                if !HookInstaller.isInstalled() { try HookInstaller.install() } else { try HookInstaller.installHelper() }
            } else if HookInstaller.hasAnyOfOurs() {
                try HookInstaller.uninstall() // whatever version put them there
            }
            hookProblem = nil
        } catch {
            hookProblem = error.localizedDescription
        }
    }

    // MARK: - AppActions

    func jump(to session: ClaudeSession) { Jumper.jump(to: session) }

    func allow(_ request: PendingPermission, always: Bool, answers: [String: String]?) -> Bool {
        hub.allow(request.requestId, always: always, answers: answers)
    }

    func deny(_ request: PendingPermission, note: String) -> Bool {
        hub.deny(request.requestId, note: note)
    }

    func reply(_ session: ClaudeSession, text: String) -> Bool {
        hub.reply(session.id, text: text)
    }

    func acknowledge(_ ids: [String]) {
        store.acknowledge(ids)
    }

    // MARK: - Menu

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let title = NSMenuItem(title: "ClaudeNotch", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(item("New Claude Code Session", #selector(newSession)))
        menu.addItem(.separator())
        menu.addItem(item("Allow, Deny & Reply from the Notch", #selector(toggleHooks), on: Settings.hooks == true))
        if let problem = hookProblem ?? server.failure {
            let warning = NSMenuItem(title: "⚠︎ " + problem, action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }
        menu.addItem(item("Play Sounds", #selector(toggleSounds), on: Settings.sounds))
        menu.addItem(item("Pop Open on Updates", #selector(togglePeek), on: Settings.peek))
        menu.addItem(item("Show on All Displays", #selector(toggleDisplays), on: Settings.allDisplays))
        menu.addItem(item("Launch at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(item("Quit ClaudeNotch", #selector(quit)))
        return menu
    }

    private func item(_ title: String, _ action: Selector, on: Bool? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let on { item.state = on ? .on : .off }
        return item
    }

    @objc private func newSession() { Jumper.newSession() }
    @objc private func toggleSounds() { Settings.sounds.toggle() }
    @objc private func togglePeek() { Settings.peek.toggle() }
    @objc private func toggleDisplays() { Settings.allDisplays.toggle(); rebuildPanels() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleHooks() {
        Settings.hooks = !(Settings.hooks ?? false)
        applyHookSetting()
        if Settings.hooks != true { hub.releaseAll() }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription + "\n\nMove ClaudeNotch.app to your Applications folder and try again."
            NSApp.activate()
            alert.runModal()
        }
    }
}
