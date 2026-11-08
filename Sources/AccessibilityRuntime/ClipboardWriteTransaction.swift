import AppKit
import AccessibilityContracts

/// One paste's clipboard ownership. Source text never comes from this transaction.
/// Backup survives preparation errors; only the broker owns external paste operations.
@MainActor final class ClipboardWriteTransaction {
    static let markerType = NSPasteboard.PasteboardType("local.promptbridge.clipboard-transaction")
    private let board: NSPasteboard
    private let backup: [[NSPasteboard.PasteboardType: Data]]
    private let payload: [NSPasteboard.PasteboardType: Data]
    private let backupCount: Int
    private var clearedCount: Int?
    private var published = false
    private let publish: ([NSPasteboardItem]) -> Bool

    /// Snapshot only. The caller retains this object before `prepare` can clear data.
    init(text: String, board: NSPasteboard = .general,
         publish: (([NSPasteboardItem]) -> Bool)? = nil) throws {
        self.board = board
        self.publish = publish ?? { board.writeObjects($0) }
        if #available(macOS 15.4, *), board.accessBehavior == .alwaysDeny {
            throw FillError.clipboardUnavailable
        }
        let before = board.changeCount
        // nil may mean denied access, not an empty board. Never clear on that basis.
        guard let items = board.pasteboardItems else { throw FillError.clipboardUnavailable }
        var saved: [[NSPasteboard.PasteboardType: Data]] = []
        for item in items {
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { throw FillError.clipboardUnavailable }
                types[type] = data
            }
            guard !types.isEmpty else { throw FillError.clipboardUnavailable }
            saved.append(types)
        }
        guard before == board.changeCount else { throw FillError.clipboardChanged }
        backup = saved
        backupCount = before
        payload = [.string: Data(text.utf8), Self.markerType: Data(UUID().uuidString.utf8)]
    }

    func prepare() throws {
        guard clearedCount == nil, board.changeCount == backupCount else { throw FillError.clipboardChanged }
        let item = NSPasteboardItem()
        for (type, data) in payload {
            guard item.setData(data, forType: type) else { throw FillError.clipboardUnavailable }
        }
        guard board.changeCount == backupCount else { throw FillError.clipboardChanged }
        clearedCount = board.clearContents()
        guard board.changeCount == clearedCount else { throw FillError.clipboardChanged }
        // writeObjects fills the ownership generation returned by clearContents.
        // Do not adopt a newer count: it may belong to a concurrent application.
        guard publish([item]) else { throw FillError.clipboardUnavailable }
        guard matchesPayload(complete: true) else { throw FillError.clipboardChanged }
        published = true
    }

    var isOwned: Bool { published && matchesPayload(complete: true) }

    func validateSubmission(_ validate: () throws -> Void) throws {
        guard isOwned else { throw FillError.clipboardChanged }
        try validate()
        guard isOwned else { throw FillError.clipboardChanged }
    }

    private func matchesPayload(complete: Bool) -> Bool {
        guard let clearedCount, board.changeCount == clearedCount,
              let items = board.pasteboardItems, items.count <= 1 else { return false }
        if complete {
            guard items.count == 1, Set(items[0].types) == Set(payload.keys) else { return false }
        }
        // While preparing, the known clear generation can contain no data or a
        // partial publish. Restore only if every available representation is ours.
        if let item = items.first {
            for type in item.types {
                guard let expected = payload[type], item.data(forType: type) == expected else { return false }
            }
        }
        return board.changeCount == clearedCount
    }

    func restoreIfOwned() {
        guard matchesPayload(complete: published) else { return }
        let restored = backup.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        guard matchesPayload(complete: published) else { return }
        let cleared = board.clearContents()
        clearedCount = nil
        published = false
        guard board.changeCount == cleared else { return }
        if !restored.isEmpty { _ = board.writeObjects(restored) }
    }
}
