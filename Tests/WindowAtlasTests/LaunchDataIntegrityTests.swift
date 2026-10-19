import XCTest
import AppKit
@testable import WindowAtlas

/// 上线审计 R3/R4/R5 回归：备份跳过前核验、恢复修复坏附件、回滚结果如实区分。
final class LaunchDataIntegrityTests: XCTestCase {
    private var base: URL!
    private var library: NotesLibrary!
    private var destination: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("windowatlas-launch-\(UUID().uuidString)")
        library = try NotesLibrary(root: base.appendingPathComponent("Notes"))
        destination = base.appendingPathComponent("Drive")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // 故障注入会改权限，清理前全部恢复为可写。
        if let enumerator = FileManager.default.enumerator(atPath: base.path) {
            for case let path as String in enumerator {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.appendingPathComponent(path).path)
            }
        }
        library = nil
        try? FileManager.default.removeItem(at: base)
    }

    private func note(_ id: String, _ body: String) -> NoteDocument {
        NoteDocument(id: id, title: "笔记\(id)", body: body, created: Date(timeIntervalSince1970: 1_700_000_000), updated: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @discardableResult
    private func save(_ value: NoteDocument, in container: String = "") throws -> String {
        guard case .saved(let path, _) = try library.save(value, previousPath: nil, expectedModified: nil, container: container) else {
            throw NotesLibrary.LibraryError.invalidLocation
        }
        return path
    }

    private func backup(at date: Date) throws -> NotesBackup.Report {
        let scan = library.scan()
        let items = scan.entries.map { NotesBackup.Item(path: $0.path, text: NoteFormat.encode($0.note), sensitive: $0.note.sensitive) }
        return try NotesBackup.run(items: items, folders: scan.folders, attachmentsDirectory: library.attachmentsDirectory,
                                   libraryRoot: library.root, destination: destination, now: date)
    }

    private var backupRoot: URL { destination.appendingPathComponent(NotesBackup.folderName) }

    private func imageName() throws -> String {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        return try library.importAttachment(XCTUnwrap(image.tiffRepresentation))
    }

    // MARK: R3

    func testDamagedLatestSnapshotIsQuarantinedAndRebuilt() throws {
        let path = try save(note("A", "swift test"))
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let first = try XCTUnwrap(try backup(at: start).snapshotName)
        try "被损坏".write(to: backupRoot.appendingPathComponent(first).appendingPathComponent(path), atomically: true, encoding: .utf8)

        let second = try backup(at: start.addingTimeInterval(600))
        XCTAssertFalse(second.skippedUnchanged, "坏快照不能被当成内容未变化")
        XCTAssertEqual(second.quarantinedSnapshots, [first])
        let rebuilt = try XCTUnwrap(second.snapshotName)
        XCTAssertNoThrow(try NotesBackup.verify(snapshot: backupRoot.appendingPathComponent(rebuilt)))
        XCTAssertEqual(NotesBackup.snapshots(in: destination).map(\.name), [rebuilt], "损坏快照不再列出")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupRoot.appendingPathComponent(".\(first).damaged").path), "损坏快照保留不删")

        // 新快照完好时恢复正常跳过。
        XCTAssertTrue(try backup(at: start.addingTimeInterval(1200)).skippedUnchanged)
    }

    func testCloudPlaceholderInLatestSnapshotStillSkips() throws {
        let path = try save(note("A", "ls"))
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let first = try XCTUnwrap(try backup(at: start).snapshotName)
        let file = backupRoot.appendingPathComponent(first).appendingPathComponent(path)
        try FileManager.default.moveItem(at: file, to: CloudFiles.placeholderURL(file))
        let second = try backup(at: start.addingTimeInterval(600))
        XCTAssertTrue(second.skippedUnchanged, "云端占位不是损坏，不应每次重建")
        XCTAssertTrue(second.quarantinedSnapshots.isEmpty)
    }

    // MARK: R4

    func testRestoreRepairsCorruptLocalAttachment() throws {
        let name = try imageName()
        try save(note("A", "![](../attachments/\(name))"))
        let snapshot = backupRoot.appendingPathComponent(try XCTUnwrap(try backup(at: Date()).snapshotName))
        let local = library.attachmentsDirectory.appendingPathComponent(name)
        let good = try Data(contentsOf: local)
        var corrupt = good
        corrupt[corrupt.count - 1] ^= 0xFF
        try corrupt.write(to: local)

        _ = try library.restore(NotesBackup.verify(snapshot: snapshot))
        XCTAssertEqual(try Data(contentsOf: local), good, "恢复后本地附件应与快照一致")
    }

    // MARK: R5

    /// 写入阶段失败但回滚成功：明确报告已回滚，内容与恢复前一致。
    func testWriteFailureWithSuccessfulRollbackIsReportedAsRolledBack() throws {
        try save(note("A", "原内容"))
        let lockedPath = try library.createFolder(named: "locked", in: "")
        let source = try NotesLibrary(root: base.appendingPathComponent("Source"))
        _ = try source.createFolder(named: "locked", in: "")
        guard case .saved = try source.save(note("N", "新笔记"), previousPath: nil, expectedModified: nil, container: "locked") else { return XCTFail() }
        let scan = source.scan()
        let report = try NotesBackup.run(items: scan.entries.map { NotesBackup.Item(path: $0.path, text: NoteFormat.encode($0.note), sensitive: false) },
                                         folders: scan.folders, attachmentsDirectory: source.attachmentsDirectory,
                                         libraryRoot: source.root, destination: destination)
        let verified = try NotesBackup.verify(snapshot: backupRoot.appendingPathComponent(try XCTUnwrap(report.snapshotName)))
        let before = try XCTUnwrap(NotesLibrary.contentDigest(library.notesDirectory))

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: library.url(lockedPath).path)
        XCTAssertThrowsError(try library.restore(verified)) { error in
            let failure = error as? RestoreFailure
            XCTAssertEqual(failure?.rolledBack, true)
            XCTAssertTrue(failure?.localizedDescription.contains("已回滚") == true || failure?.localizedDescription.contains("rolled back") == true)
        }
        XCTAssertEqual(NotesLibrary.contentDigest(library.notesDirectory), before)
    }

    /// 写入与回滚都失败：不得声称已回滚，并给出恢复前副本位置。
    func testFailedRollbackIsNotReportedAsSuccess() throws {
        try save(note("A", "原内容"))
        let source = try NotesLibrary(root: base.appendingPathComponent("Source"))
        guard case .saved = try source.save(note("N", "新笔记"), previousPath: nil, expectedModified: nil) else { return XCTFail() }
        let scan = source.scan()
        let report = try NotesBackup.run(items: scan.entries.map { NotesBackup.Item(path: $0.path, text: NoteFormat.encode($0.note), sensitive: false) },
                                         folders: scan.folders, attachmentsDirectory: source.attachmentsDirectory,
                                         libraryRoot: source.root, destination: destination)
        let verified = try NotesBackup.verify(snapshot: backupRoot.appendingPathComponent(try XCTUnwrap(report.snapshotName)))

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: library.notesDirectory.path)
        XCTAssertThrowsError(try library.restore(verified)) { error in
            guard let failure = error as? RestoreFailure else { return XCTFail("应返回 RestoreFailure：\(error)") }
            XCTAssertFalse(failure.rolledBack)
            XCTAssertTrue(failure.localizedDescription.contains(failure.safetyCopy.path))
            XCTAssertEqual(NotesLibrary.contentDigest(failure.safetyCopy.appendingPathComponent("notes"))?.count, 1, "恢复前副本完整")
        }
    }
}
