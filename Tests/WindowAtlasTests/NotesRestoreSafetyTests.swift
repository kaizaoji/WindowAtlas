import XCTest
@testable import WindowAtlas

final class NotesRestoreSafetyTests: XCTestCase {
    private func library() throws -> NotesLibrary {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("windowatlas-restore-safety-\(UUID().uuidString)")
        return try NotesLibrary(root: root)
    }

    private func file(_ path: String, id: String) -> VerifiedSnapshot.NoteFile {
        let note = NoteDocument(id: id, title: id, body: "内容 \(id)", created: Date(), updated: Date())
        return .init(path: path, note: note, data: Data(NoteFormat.encode(note).utf8))
    }

    private func write(_ file: VerifiedSnapshot.NoteFile, to library: NotesLibrary) throws {
        try FileManager.default.createDirectory(at: library.url(NotesLibrary.parent(of: file.path)), withIntermediateDirectories: true)
        try file.data.write(to: library.url(file.path))
    }

    func testRepeatedFallbackPreservesLocalNotesAndMapsChildren() throws {
        let library = try library()
        try write(file("shared.md", id: "local"), to: library)
        try write(file("shared-恢复.md", id: "fallback"), to: library)
        try write(file("shared-恢复-2.md", id: "second"), to: library)
        let snapshot = VerifiedSnapshot(name: "测试", notes: [file("shared.md", id: "parent"), file("shared/child.md", id: "child")], folders: ["shared", "shared/empty"], attachments: [])
        _ = try library.restore(snapshot)
        let paths = Dictionary(uniqueKeysWithValues: library.loadAll().map { ($0.note.id, $0.path) })
        XCTAssertEqual(paths.count, 5)
        XCTAssertEqual(paths["local"], "shared.md")
        XCTAssertEqual(paths["fallback"], "shared-恢复.md")
        XCTAssertEqual(paths["second"], "shared-恢复-2.md")
        XCTAssertEqual(paths["parent"], "shared-恢复-3.md")
        XCTAssertEqual(paths["child"], "shared-恢复-3/child.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.url("shared-恢复-3/empty").path))
    }

    func testTwoIncomingNotesCannotClaimSameFallback() throws {
        let library = try library()
        try write(file("shared.md", id: "local"), to: library)
        let snapshot = VerifiedSnapshot(name: "测试", notes: [file("shared.md", id: "first"), file("shared-恢复.md", id: "second")], attachments: [])
        _ = try library.restore(snapshot)
        XCTAssertEqual(Set(library.loadAll().map(\.note.id)), ["local", "first", "second"])
    }

    func testCaseVariantsCannotOverwriteWithinOneRestore() throws {
        let library = try library()
        let snapshot = VerifiedSnapshot(name: "测试", notes: [file("Shared.md", id: "first"), file("shared.md", id: "second")], attachments: [])
        _ = try library.restore(snapshot)
        XCTAssertEqual(Set(library.loadAll().map(\.note.id)), ["first", "second"])
    }

    func testSameIDCaseOnlyRenameDoesNotDeleteRestoredFile() throws {
        let library = try library()
        try write(file("Shared.md", id: "same"), to: library)
        var restoredNote = file("shared.md", id: "same").note
        restoredNote.body = "恢复后的正文"
        let restoredFile = VerifiedSnapshot.NoteFile(path: "shared.md", note: restoredNote, data: Data(NoteFormat.encode(restoredNote).utf8))
        _ = try library.restore(VerifiedSnapshot(name: "测试", notes: [restoredFile], attachments: []))
        let notes = library.loadAll()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.note.id, "same")
        XCTAssertEqual(notes.first?.note.body, "恢复后的正文")
    }

    func testCaseSensitiveVolumePreservesBothLocalOwners() throws {
        let library = try library()
        let values = try library.root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        guard values.volumeSupportsCaseSensitiveNames == true else {
            throw XCTSkip("当前临时目录不是大小写敏感卷，无法建立两篇仅大小写不同的本地笔记")
        }
        try write(file("Shared.md", id: "upper"), to: library)
        try write(file("shared.md", id: "lower"), to: library)
        _ = try library.restore(VerifiedSnapshot(name: "测试", notes: [file("shared.md", id: "upper")], attachments: []))
        let notes = library.loadAll()
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(Set(notes.map(\.note.id)), ["upper", "lower"])
        XCTAssertEqual(notes.first { $0.note.id == "lower" }?.path, "shared.md")
    }

    func testRestoreRejectsSymlinkParentBeforeWriting() throws {
        let library = try library()
        let outside = library.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: library.url("linked"), withDestinationURL: outside)
        let snapshot = VerifiedSnapshot(name: "测试", notes: [file("linked/new.md", id: "new")], attachments: [])
        XCTAssertThrowsError(try library.restore(snapshot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.restoreBackupsDirectory.path))
    }

    func testSwappedPathsPreserveBothRestoredIDs() throws {
        let library = try library()
        try write(file("first.md", id: "first"), to: library)
        try write(file("second.md", id: "second"), to: library)
        let snapshot = VerifiedSnapshot(name: "测试", notes: [file("second.md", id: "first"), file("first.md", id: "second")], attachments: [])
        _ = try library.restore(snapshot)
        let entries = library.loadAll()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.note.id)), ["first", "second"])
    }
}
