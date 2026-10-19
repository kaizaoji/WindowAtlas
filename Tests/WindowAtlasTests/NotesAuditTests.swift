import AppKit
import XCTest
@testable import WindowAtlas

/// 独立验收用例：只使用系统临时目录，不接触用户笔记或云盘。
final class NotesAuditTests: XCTestCase {
    private func workspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("windowatlas-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func document(_ id: String, body: String) -> NoteDocument {
        NoteDocument(id: id, title: id, body: body, created: Date(), updated: Date())
    }

    private func imageData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testRestoreDoesNotOverwriteUnrelatedNoteAtFallbackName() throws {
        let base = try workspace()
        let library = try NotesLibrary(root: base.appendingPathComponent("Library"))
        let primary = document("local-primary", body: "原有内容一")
        let fallback = document("local-fallback", body: "原有内容二，必须保留")
        try Data(NoteFormat.encode(primary).utf8).write(to: library.url("shared.md"))
        try Data(NoteFormat.encode(fallback).utf8).write(to: library.url("shared-恢复.md"))
        let incoming = document("incoming", body: "从备份恢复")
        let snapshot = VerifiedSnapshot(name: "audit", notes: [.init(path: "shared.md", note: incoming,
            data: Data(NoteFormat.encode(incoming).utf8))], attachments: [])

        _ = try library.restore(snapshot)

        XCTAssertEqual(Set(library.loadAll().map(\.note.id)), [primary.id, fallback.id, incoming.id],
            "自动选择的恢复文件名也必须检查占用，不能覆盖另一篇本地笔记")
    }

    func testVerifyRejectsSnapshotWithReferencedImageMissingFromManifest() throws {
        let base = try workspace()
        let destination = base.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let missingName = String(repeating: "a", count: 64) + ".png"
        let note = document("missing-image", body: "![](../attachments/\(missingName))")
        // 新版备份会直接拒绝缺图；手工构造旧版快照以继续验证恢复端防线。
        let snapshot = destination.appendingPathComponent(NotesBackup.folderName)
            .appendingPathComponent("2026-10-18 120000")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let encoded = Data(NoteFormat.encode(note).utf8)
        try encoded.write(to: snapshot.appendingPathComponent("note.md"))
        let records = [NotesBackup.Manifest.FileRecord(file: "note.md", size: encoded.count, sha256: sha256(encoded))]
        let manifest = NotesBackup.Manifest(version: NotesBackup.manifestVersion, created: Date(),
            digest: NotesBackup.digest(notes: records, attachments: []), notes: records, attachments: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: snapshot.appendingPathComponent("manifest.json"))

        XCTAssertThrowsError(try NotesBackup.verify(snapshot: snapshot), "正文引用的图片缺失时不能声称完整校验通过")
    }

    func testBackupRepairsCorruptSharedImageWithSameSize() throws {
        let base = try workspace()
        let library = try NotesLibrary(root: base.appendingPathComponent("Library"))
        let destination = base.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let name = try library.importAttachment(imageData())
        let note = document("image", body: "![](../attachments/\(name))")
        let items = [NotesBackup.Item(path: "note.md", text: NoteFormat.encode(note), sensitive: false)]
        let first = try NotesBackup.run(items: items, attachmentsDirectory: library.attachmentsDirectory,
            libraryRoot: library.root, destination: destination)
        let shared = destination.appendingPathComponent(NotesBackup.folderName).appendingPathComponent("attachments/\(name)")
        var corrupt = try Data(contentsOf: shared)
        corrupt[corrupt.startIndex] ^= 0xff
        try corrupt.write(to: shared, options: .atomic)

        _ = try NotesBackup.run(items: items, attachmentsDirectory: library.attachmentsDirectory,
            libraryRoot: library.root, destination: destination)
        let snapshot = destination.appendingPathComponent(NotesBackup.folderName)
            .appendingPathComponent(try XCTUnwrap(first.snapshotName))

        XCTAssertNoThrow(try NotesBackup.verify(snapshot: snapshot), "再次备份应修复已损坏的共享附件，不能仅比较大小")
    }

    func testCodeImportPreservesRepeatedBlankLines() throws {
        let base = try workspace()
        let source = base.appendingPathComponent("example.py")
        let code = "print('开始')\n\n\n\n\nprint('结束')\n"
        try Data(code.utf8).write(to: source)

        let note = try NoteImporter.convert(source)
        let snippet = try XCTUnwrap(NoteSnippets.extract(from: note).first)

        XCTAssertEqual(snippet.code, String(code.dropLast()), "代码导入不能压缩原始代码中的空行")
    }

    func testVerifyRejectsSnapshotWithSymlinkAncestor() throws {
        let base = try workspace()
        let library = try NotesLibrary(root: base.appendingPathComponent("Library"))
        let destination = base.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let note = document("external", body: "不得通过上级符号链接读取")
        let report = try NotesBackup.run(items: [.init(path: "folder/note.md", text: NoteFormat.encode(note), sensitive: false)],
            attachmentsDirectory: library.attachmentsDirectory, libraryRoot: library.root, destination: destination)
        let snapshot = destination.appendingPathComponent(NotesBackup.folderName)
            .appendingPathComponent(try XCTUnwrap(report.snapshotName))
        let external = base.appendingPathComponent("OutsideSnapshot")
        try FileManager.default.moveItem(at: snapshot.appendingPathComponent("folder"), to: external)
        try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent("folder"), withDestinationURL: external)

        XCTAssertThrowsError(try NotesBackup.verify(snapshot: snapshot), "除文件本身外，还必须拒绝上级目录符号链接越界")
    }

    @MainActor
    func testFailedSaveBeforeMovePreservesUnsavedBody() throws {
        let base = try workspace()
        let store = NotesStore(root: base.appendingPathComponent("Library"))
        store.createNote()
        store.flush()
        let id = try XCTUnwrap(store.selectedID)
        let library = try XCTUnwrap(store.library)
        // 用不可写目录模拟磁盘写入失败，之后恢复权限，不影响其他测试。
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: library.notesDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: library.notesDirectory.path) }
        store.editBody(id, "尚未保存的编辑必须保留")

        store.moveNote(id, to: "")

        XCTAssertEqual(store.selected?.body, "尚未保存的编辑必须保留", "保存失败后不能继续重新载入磁盘并丢弃内存编辑")
    }
}
