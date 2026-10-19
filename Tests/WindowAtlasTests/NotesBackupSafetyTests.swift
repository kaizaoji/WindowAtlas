import Foundation
import XCTest
@testable import WindowAtlas

/// 仅在独立临时目录验证备份失败行为，不接触实际笔记库。
final class NotesBackupSafetyTests: XCTestCase {
    func testMissingAttachmentDoesNotPublishOrReplaceSnapshot() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("windowatlas-backup-safety-\(UUID().uuidString)")
        let library = try NotesLibrary(root: base.appendingPathComponent("Library"))
        let destination = base.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = NotesBackup.Item(path: "note.md", text: "原有完整内容", sensitive: false)
        let initial = try NotesBackup.run(items: [original], attachmentsDirectory: library.attachmentsDirectory,
            libraryRoot: library.root, destination: destination)
        let missingName = String(repeating: "a", count: 64) + ".png"
        let incomplete = NotesBackup.Item(path: "note.md", text: "![](../attachments/\(missingName))", sensitive: false)

        XCTAssertThrowsError(try NotesBackup.run(items: [incomplete], attachmentsDirectory: library.attachmentsDirectory,
            libraryRoot: library.root, destination: destination)) { error in
            guard case NotesBackup.BackupError.incompleteAttachments(1) = error else {
                return XCTFail("应报告引用附件不完整：\(error)")
            }
        }

        let snapshots = NotesBackup.snapshots(in: destination)
        XCTAssertEqual(snapshots.map(\.name), [try XCTUnwrap(initial.snapshotName)])
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(try String(contentsOf: snapshot.url.appendingPathComponent("note.md"), encoding: .utf8), original.text)
    }

    func testCorruptSourceAttachmentDoesNotPublishSnapshot() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("windowatlas-backup-safety-\(UUID().uuidString)")
        let library = try NotesLibrary(root: base.appendingPathComponent("Library"))
        let destination = base.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let name = String(repeating: "b", count: 64) + ".png"
        try Data("损坏图片".utf8).write(to: library.attachmentsDirectory.appendingPathComponent(name))
        let item = NotesBackup.Item(path: "note.md", text: "![](../attachments/\(name))", sensitive: false)

        XCTAssertThrowsError(try NotesBackup.run(items: [item], attachmentsDirectory: library.attachmentsDirectory,
            libraryRoot: library.root, destination: destination))
        XCTAssertTrue(NotesBackup.snapshots(in: destination).isEmpty)
    }
}
