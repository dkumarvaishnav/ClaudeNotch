import AppKit
import SwiftUI

#if DEBUG
// `ClaudeNotch --snapshot <dir>` renders the notch states with your live sessions to PNGs and exits.
if let flag = CommandLine.arguments.firstIndex(of: "--snapshot") {
    let dir = CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : "."
    MainActor.assumeIsolated { Snapshot.render(to: URL(fileURLWithPath: dir)) }
    exit(0)
}
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
