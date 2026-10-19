import XCTest
@testable import WindowAtlas

final class NotesSaveSafetyTests: XCTestCase {
    @MainActor
    private func savedStore() throws -> (store: NotesStore, id: String, directory: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("windowatlas-save-safety-\(UUID().uuidString)")
        let store = NotesStore(root: root)
        store.createNote()
        XCTAssertTrue(store.flush())
        return (store, try XCTUnwrap(store.selectedID), try XCTUnwrap(store.library).notesDirectory)
    }

    @MainActor
    func testFailedSaveBlocksSnapshotAndCanRetryWithoutLosingEdits() throws {
        let fixture = try savedStore()
        let store = fixture.store
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path) }
        store.editBody(fixture.id, "需要保留并重试的正文")

        XCTAssertFalse(store.flush())
        XCTAssertNil(store.snapshotItems(), "备份和导出不得漏掉尚未保存的内容")
        XCTAssertEqual(store.selected?.body, "需要保留并重试的正文")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
        XCTAssertTrue(store.flush())
        store.reload()
        XCTAssertEqual(store.selected?.body, "需要保留并重试的正文")
        XCTAssertEqual(try XCTUnwrap(store.snapshotItems()).items.count, 1)
    }

    @MainActor
    func testReloadCannotDiscardPendingEdits() throws {
        let fixture = try savedStore()
        fixture.store.editBody(fixture.id, "重新载入前尚未落盘的正文")

        fixture.store.reload()

        XCTAssertEqual(fixture.store.selected?.body, "重新载入前尚未落盘的正文")
        XCTAssertTrue(fixture.store.flush())
        fixture.store.reload()
        XCTAssertEqual(fixture.store.selected?.body, "重新载入前尚未落盘的正文")
    }

    @MainActor
    func testFailedSaveBlocksFolderMutationAndNoteSwitch() throws {
        let fixture = try savedStore()
        let store = fixture.store
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path) }
        store.editBody(fixture.id, "失败后仍留在当前笔记")

        store.createFolder(named: "不得创建")
        store.select(nil)
        store.createNote()

        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.selectedID, fixture.id)
        XCTAssertEqual(store.selected?.body, "失败后仍留在当前笔记")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("不得创建").path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
        XCTAssertTrue(store.flush())
    }
}
