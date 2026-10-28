import Foundation
import Testing
@testable import ClaudeNotch

@Suite struct ShelfStoreTests {
    private func tempFile(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
        try Data("hello".utf8).write(to: url)
        return url
    }

    @Test func textLinksAndFilesLandAsTheRightKind() throws {
        let (shelf, _) = makeShelf()
        shelf.add(.text("  Remember the milk  "), source: "Notes")
        shelf.add(.text("https://claude.ai/code"))
        let a = try tempFile("a.pdf"), b = try tempFile("b.txt")
        shelf.add(.files([a, b]), source: "Finder")

        #expect(shelf.items.count == 4)
        #expect(shelf.items[0].content == .file(a)) // newest first, in the order they were dropped
        #expect(shelf.items[1].content == .file(b))
        #expect(shelf.items[2].content == .link(URL(string: "https://claude.ai/code")!))
        #expect(shelf.items[3].content == .text("Remember the milk"))
        #expect(shelf.items[3].source == "Notes")
    }

    @Test func theSameThingTwiceMovesToTheFront() {
        let (shelf, _) = makeShelf()
        shelf.add(.text("one"))
        shelf.add(.text("two"))
        shelf.add(.text("one"))
        #expect(shelf.items.map(\.title) == ["one", "two"])
    }

    @Test func copiedImagesBecomeTemporaryFilesThatGoAwayWithTheItem() {
        let (shelf, _) = makeShelf()
        shelf.add(.png(), source: "Screenshot")
        let item = shelf.items.first!
        guard case .file(let url) = item.content else { #expect(Bool(false), "expected a file"); return }
        #expect(item.temporary)
        #expect(item.isImage)
        #expect(FileManager.default.fileExists(atPath: url.path))
        shelf.remove(item)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func clickingAnItemPutsItOnTheClipboardWithoutRecordingItAgain() {
        let (shelf, clipboard) = makeShelf()
        shelf.add(.text("send this"))
        shelf.setHistory(true)
        shelf.copy(shelf.items[0])
        #expect(clipboard.string == "send this")
        shelf.checkClipboard()
        #expect(shelf.items.count == 1)
    }

    @Test func historyRecordsNewCopiesButNotPasswords() {
        let (shelf, clipboard) = makeShelf()
        shelf.setHistory(true)
        clipboard.copy("copied text")
        shelf.checkClipboard()
        #expect(shelf.items.map(\.title) == ["copied text"])

        clipboard.copy("hunter2", private: true)
        shelf.checkClipboard()
        #expect(shelf.items.count == 1)
    }

    @Test func historyOffRecordsNothing() {
        let (shelf, clipboard) = makeShelf()
        clipboard.copy("not recorded")
        shelf.checkClipboard()
        #expect(shelf.items.isEmpty)
    }

    @Test func theShelfKeepsAtMostFortyThings() {
        let (shelf, _) = makeShelf()
        for i in 0..<50 { shelf.add(.text("item \(i)")) }
        #expect(shelf.items.count == ShelfStore.maxItems)
        #expect(shelf.items.first?.title == "item 49")
    }
}
