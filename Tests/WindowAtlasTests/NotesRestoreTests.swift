import XCTest
import AppKit
@testable import WindowAtlas

final class NotesRestoreTests: XCTestCase {
    private var base: URL!
    private var library: NotesLibrary!
    private var destination: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("windowatlas-restore-\(UUID().uuidString)")
        library = try NotesLibrary(root: base.appendingPathComponent("Notes"))
        destination = base.appendingPathComponent("Drive")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { library = nil; try? FileManager.default.removeItem(at: base) }

    private func note(_ id: String, _ title: String, _ body: String, sensitive: Bool = false) -> NoteDocument {
        var value = NoteDocument(id: id, title: title, body: body, created: Date(timeIntervalSince1970: 1_700_000_000), updated: Date(timeIntervalSince1970: 1_700_000_000))
        value.sensitive = sensitive
        return value
    }

    @discardableResult
    private func save(_ value: NoteDocument) throws -> String {
        guard case .saved(let name, _) = try library.save(value, previousPath: nil, expectedModified: nil) else { throw RestoreError.damaged("save") }
        return name
    }

    private func backup() throws -> URL {
        let items = library.loadAll().map { NotesBackup.Item(path: $0.path, text: NoteFormat.encode($0.note), sensitive: $0.note.sensitive) }
        let report = try NotesBackup.run(items: items, attachmentsDirectory: library.attachmentsDirectory, libraryRoot: library.root, destination: destination)
        return destination.appendingPathComponent(NotesBackup.folderName).appendingPathComponent(try XCTUnwrap(report.snapshotName))
    }

    func testRestoreMergesByIDKeepsSensitiveAndSavesSafetyCopy() throws {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
        let attachment = try library.importAttachment(XCTUnwrap(image.tiffRepresentation))
        let originalA = try save(note("A", "部署", "旧版本 ![](../attachments/\(attachment))"))
        try save(note("C", "将被删除", "快照里有"))
        let snapshot = try backup()

        // 备份后：A 被改名改坏、C 被删除、新增敏感笔记 S、附件丢失。
        _ = try library.save(note("A", "部署-改名", "改坏了"), previousPath: originalA, expectedModified: library.modificationDate(path: originalA))
        try FileManager.default.removeItem(at: library.notesDirectory.appendingPathComponent(library.loadAll().first { $0.note.id == "C" }!.path))
        try save(note("S", "私密", "敏感内容", sensitive: true))
        try FileManager.default.removeItem(at: library.attachmentsDirectory.appendingPathComponent(attachment))

        let verified = try NotesBackup.verify(snapshot: snapshot)
        XCTAssertEqual(library.restorePlan(for: verified), .init(overwritten: 1, added: 1, keptLocal: 1))
        let report = try library.restore(verified)
        let restored = Dictionary(uniqueKeysWithValues: library.loadAll().map { ($0.note.id, $0.note) })
        XCTAssertEqual(Set(restored.keys), ["A", "C", "S"])
        XCTAssertEqual(restored["A"]?.title, "部署")
        XCTAssertTrue(restored["A"]?.body.contains("旧版本") == true)
        XCTAssertEqual(restored["S"]?.body, "敏感内容")
        XCTAssertEqual(library.loadAll().filter { $0.note.id == "A" }.count, 1, "改名后的旧文件应被替换，不留重复")
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.attachmentsDirectory.appendingPathComponent(attachment).path))
        let saved = try FileManager.default.contentsOfDirectory(atPath: report.safetyCopy.appendingPathComponent("notes").path)
        XCTAssertEqual(saved.count, 2, "恢复前副本应包含改坏的 A 与敏感笔记 S")
    }

    func testVerifyRejectsTamperedFutureAndUnsafeSnapshots() throws {
        try save(note("A", "命令", "ls"))
        let snapshot = try backup()
        let noteFile = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: snapshot.path).first { $0.hasSuffix(".md") })
        XCTAssertNoThrow(try NotesBackup.verify(snapshot: snapshot))

        try "被篡改".write(to: snapshot.appendingPathComponent(noteFile), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try NotesBackup.verify(snapshot: snapshot)) { XCTAssertTrue("\($0)".contains("damaged")) }

        let manifestURL = snapshot.appendingPathComponent("manifest.json")
        let original = try String(contentsOf: manifestURL, encoding: .utf8)
        try original.replacingOccurrences(of: "\"version\" : 2", with: "\"version\" : 3").write(to: manifestURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try NotesBackup.verify(snapshot: snapshot)) { XCTAssertEqual($0 as? RestoreError, .unsupportedVersion(3)) }

        XCTAssertFalse(NotesBackup.isSafeNotePath("../x.md"))
        XCTAssertFalse(NotesBackup.isSafeNotePath("a/../../b.md"))
        XCTAssertFalse(NotesBackup.isSafeNotePath("/etc/x.md"))
        XCTAssertFalse(NotesBackup.isSafeNotePath("a//b.md"))
        XCTAssertFalse(NotesBackup.isSafeNotePath(".hidden.md"))
        XCTAssertFalse(NotesBackup.isSafeNotePath("x.sh"))
        XCTAssertTrue(NotesBackup.isSafeNotePath("项目/部署-1234/子-5678.md"))
    }

    func testPlaceholderFilesAreReportedAsNotDownloaded() throws {
        try save(note("A", "命令", "ls"))
        let snapshot = try backup()
        let noteFile = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: snapshot.path).first { $0.hasSuffix(".md") })
        let url = snapshot.appendingPathComponent(noteFile)
        try FileManager.default.moveItem(at: url, to: CloudFiles.placeholderURL(url))
        XCTAssertThrowsError(try NotesBackup.verify(snapshot: snapshot)) { XCTAssertEqual($0 as? RestoreError, .notDownloaded(1)) }
        let manifest = snapshot.appendingPathComponent("manifest.json")
        try FileManager.default.moveItem(at: manifest, to: CloudFiles.placeholderURL(manifest))
        let listed = NotesBackup.snapshots(in: destination)
        XCTAssertEqual(listed.count, 1)
        XCTAssertFalse(listed[0].available)
    }

    func testCloudLocationDetectionPrefersWritableGoogleDriveFolder() throws {
        let home = base.appendingPathComponent("home")
        let drive = home.appendingPathComponent("Library/CloudStorage/GoogleDrive-me@example.com")
        try FileManager.default.createDirectory(at: drive.appendingPathComponent("我的云端硬盘"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: drive.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: drive.path) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/CloudStorage/OneDrive-Personal"), withIntermediateDirectories: true)
        var detection = CloudLocations.detect(home: home)
        XCTAssertFalse(detection.iCloudAvailable)
        XCTAssertEqual(detection.locations.map(\.name), ["Google Drive（me@example.com）", "OneDrive（Personal）"])
        XCTAssertEqual(detection.locations[0].url.lastPathComponent, "我的云端硬盘")

        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"), withIntermediateDirectories: true)
        detection = CloudLocations.detect(home: home)
        XCTAssertTrue(detection.iCloudAvailable)
        XCTAssertEqual(detection.locations.first?.name, "iCloud 云盘")
    }

    /// 大量笔记：首次载入、无变化的二次扫描、跨笔记搜索都应在交互可接受的时间内完成。
    @MainActor
    func testTwoThousandNotesStayResponsive() throws {
        let body = String(repeating: "说明文字 lorem ipsum\n", count: 40) + "```sh\nswift test && zsh scripts/build.sh\n```\n"
        for index in 0..<2000 {
            let text = NoteFormat.encode(note("id-\(index)", "笔记 \(index)", body + "唯一标记-\(index)"))
            try Data(text.utf8).write(to: library.notesDirectory.appendingPathComponent("n\(index).md"))
        }
        library = nil
        let store = NotesStore(root: base.appendingPathComponent("Notes"))
        XCTAssertEqual(store.notes.count, 2000)

        var start = Date()
        store.reloadExternalChanges()
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "无变化的重新扫描应复用缓存")

        _ = store.searchSnippets("")
        start = Date()
        XCTAssertEqual(store.searchSnippets("swift test").count, 2000)
        store.query = "唯一标记-1999"
        XCTAssertEqual(store.visibleNotes.map(\.id), ["id-1999"])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "命令与全文搜索应使用缓存的派生数据")
    }
}
