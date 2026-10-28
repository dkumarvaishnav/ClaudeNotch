// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClaudeNotch", dependencies: ["HookProtocol"], path: "Sources/ClaudeNotch"),
        // Tiny helper Claude Code runs for each hook event; it talks to the app on 127.0.0.1.
        .executableTarget(name: "claudenotch-hook", dependencies: ["HookProtocol"], path: "Sources/ClaudeNotchHook"),
        // How the two prove to each other that they share the secret, without ever sending it.
        .target(name: "HookProtocol", path: "Sources/HookProtocol"),
        .testTarget(name: "ClaudeNotchTests", dependencies: ["ClaudeNotch", "HookProtocol"], path: "Tests/ClaudeNotchTests"),
    ]
)
