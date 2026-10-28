#if DEBUG
import AppKit

// Pasteboard helpers for the tests (ShelfStoreTests). They live in the app's debug build because a test
// target that imports AppKit trips the Command Line Tools' Swift Testing macro lookup.

/// A shelf on a private pasteboard (never the real clipboard) with its own settings.
func makeShelf() -> (shelf: ShelfStore, clipboard: Clipboard) {
    let pasteboard = NSPasteboard(name: .init("ClaudeNotchTest-" + UUID().uuidString))
    return (ShelfStore(pasteboard: pasteboard, defaults: UserDefaults(suiteName: UUID().uuidString)!), Clipboard(pasteboard))
}

/// What another app would put on a pasteboard when you drag or copy something.
struct Clipboard {
    let pasteboard: NSPasteboard
    init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    static func fresh() -> Clipboard {
        let pb = NSPasteboard(name: .init("ClaudeNotchTestDrop-" + UUID().uuidString))
        pb.clearContents()
        return Clipboard(pb)
    }

    static func text(_ text: String) -> Clipboard {
        let c = fresh()
        c.pasteboard.setString(text, forType: .string)
        return c
    }

    static func files(_ urls: [URL]) -> Clipboard {
        let c = fresh()
        c.pasteboard.writeObjects(urls.map { $0 as NSURL })
        return c
    }

    static func png() -> Clipboard {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let c = fresh()
        c.pasteboard.setData(rep.representation(using: .png, properties: [:])!, forType: .png)
        return c
    }

    /// Copy as a user would: replaces what's there. `private` marks it the way password managers do.
    func copy(_ text: String, private: Bool = false) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if `private` { pasteboard.setData(Data(), forType: .init("org.nspasteboard.ConcealedType")) }
    }

    var string: String? { pasteboard.string(forType: .string) }
}

extension ShelfStore {
    @discardableResult
    func add(_ clipboard: Clipboard, source: String? = nil) -> Int { add(from: clipboard.pasteboard, source: source) }
}
#endif
