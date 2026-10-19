import XCTest
import AppKit
@testable import WindowAtlas

final class NotesFormatTests: XCTestCase {
    private func note(_ body: String, title: String = "部署") -> NoteDocument {
        NoteDocument(id: "ABC-123", title: title, body: body, created: Date(timeIntervalSince1970: 1_700_000_000), updated: Date(timeIntervalSince1970: 1_700_000_600))
    }

    func testFrontMatterRoundTripKeepsEscapedTitleAndBodyExactly() throws {
        var original = note("\n首行前有空行\n\t缩进\n---\n结尾无换行", title: "标题: \"引号\" 与\n换行")
        original.favorite = true; original.sensitive = true
        let decoded = try XCTUnwrap(NoteFormat.decode(NoteFormat.encode(original)))
        XCTAssertEqual(decoded, original)
    }

    func testMissingOrBrokenFrontMatterIsNotParsed() {
        XCTAssertNil(NoteFormat.decode("# 普通 Markdown"))
        XCTAssertNil(NoteFormat.decode("---\nid: \"x\"\n没有结束"))
        XCTAssertNil(NoteFormat.decode("---\ntitle: \"无 ID\"\n---\n正文"))
    }

    func testFileNameStripsPathCharactersAndKeepsShortID() {
        XCTAssertEqual(NoteFormat.fileName(title: "../a/b:c", id: "1234-5678-9abc"), "-a-b-c-12345678.md")
        XCTAssertEqual(NoteFormat.fileName(title: "  ", id: "x"), "未命名笔记-x.md")
        XCTAssertTrue(NoteFormat.fileName(title: String(repeating: "长", count: 200), id: "id").count < 80)
    }

    func testSnippetsPreserveIndentationTabsAndBlankLines() {
        let body = "构建并安装：\n```zsh\nswift test \\\n\t--parallel\n\n  echo done\n```\n## Python 示例\n~~~python\nprint(\"```\")\n~~~\n"
        let snippets = NoteSnippets.extract(from: note(body))
        XCTAssertEqual(snippets.count, 2)
        XCTAssertEqual(snippets[0].code, "swift test \\\n\t--parallel\n\n  echo done")
        XCTAssertEqual(snippets[0].label, "构建并安装")
        XCTAssertTrue(snippets[0].isCommand)
        XCTAssertEqual(snippets[1].code, "print(\"```\")")
        XCTAssertEqual(snippets[1].label, "Python 示例")
        XCTAssertFalse(snippets[1].isCommand)
    }

    func testUnclosedFenceAndUnlabeledBlockFallBackSafely() {
        let snippets = NoteSnippets.extract(from: note("```\nls -la\n````"))
        XCTAssertEqual(snippets.count, 1)
        XCTAssertEqual(snippets[0].code, "ls -la")
        XCTAssertEqual(snippets[0].label, "部署")
        XCTAssertTrue(snippets[0].isCommand)
        XCTAssertEqual(NoteSnippets.extract(from: note("````\na\n```\nb\n")).first?.code, "a\n```\nb\n")
    }

    func testPreviewCodeBlocksAlignWithExtractedSnippets() {
        let source = note("# 标题\n- 项目\n```sh\na\n```\n![](../attachments/x.png)\n```\nb\n```")
        let codes = PreviewBlock.parse(source).compactMap { block -> String? in
            if case .code(let snippet) = block { return snippet.code }; return nil
        }
        XCTAssertEqual(codes, NoteSnippets.extract(from: source).map(\.code))
    }

    func testSecretScannerFindsCommonKeysWithoutFlaggingPlaceholders() {
        XCTAssertFalse(SecretScanner.findings(in: "export ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwx").isEmpty)
        XCTAssertFalse(SecretScanner.findings(in: "git clone https://ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com/x").isEmpty)
        XCTAssertFalse(SecretScanner.findings(in: "AKIAABCDEFGHIJKLMNOP").isEmpty)
        XCTAssertFalse(SecretScanner.findings(in: "-----BEGIN OPENSSH PRIVATE KEY-----").isEmpty)
        XCTAssertFalse(SecretScanner.findings(in: "DB_PASSWORD=Sup3rS3cretValue").isEmpty)
        XCTAssertTrue(SecretScanner.findings(in: "export TOKEN=$GITHUB_TOKEN\npassword: <your-password>\nswift test").isEmpty)
    }

    func testAttachmentLinksOnlyAcceptGeneratedHashNames() {
        let hash = String(repeating: "a", count: 64)
        XCTAssertEqual(NoteAttachments.validatedName(fromLink: "../attachments/\(hash).png"), "\(hash).png")
        XCTAssertNil(NoteAttachments.validatedName(fromLink: "../attachments/../../etc/passwd"))
        XCTAssertEqual(NoteAttachments.validatedName(fromLink: "../../../attachments/\(hash).png"), "\(hash).png")
        XCTAssertEqual(NoteAttachments.normalizeLinks(in: "a ![](../attachments/\(hash).png) b", depth: 2), "a ![](../../../attachments/\(hash).png) b")
        XCTAssertNil(NoteAttachments.validatedName(fromLink: "/Users/x/a.png"))
        XCTAssertNil(NoteAttachments.validatedName(fromLink: "https://example.com/\(hash).png"))
        XCTAssertNil(NoteAttachments.validatedName(fromLink: "../attachments/\(hash).svg"))
        XCTAssertEqual(NoteAttachments.referencedNames(in: "![](../attachments/\(hash).png) ![x](../a.png)"), ["\(hash).png"])
    }

    func testImagePreparationKeepsPngAndConvertsTiff() throws {
        let image = NSImage(size: NSSize(width: 4, height: 3))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 3).fill(); image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let converted = try NoteAttachments.prepare(tiff)
        XCTAssertTrue(converted.name.hasSuffix(".png"))
        XCTAssertTrue(NoteAttachments.isValidName(converted.name))
        let again = try NoteAttachments.prepare(converted.data)
        XCTAssertEqual(again.name, converted.name)
        XCTAssertEqual(again.data, converted.data)
        XCTAssertThrowsError(try NoteAttachments.prepare(Data("not an image".utf8)))
        XCTAssertThrowsError(try NoteAttachments.prepare(Data(count: NoteAttachments.maxBytes + 1)))
    }
}

final class NotesStorageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("windowatlas-notes-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func sample(_ title: String = "命令", body: String = "```sh\nls\n```") -> NoteDocument {
        NoteDocument(id: UUID().uuidString, title: title, body: body, created: Date(), updated: Date())
    }

    func testSaveRenameAndReload() throws {
        let library = try NotesLibrary(root: root)
        var note = sample()
        guard case .saved(let first, let modified) = try library.save(note, previousPath: nil, expectedModified: nil) else { return XCTFail() }
        note.title = "改名后"
        guard case .saved(let second, _) = try library.save(note, previousPath: first, expectedModified: modified) else { return XCTFail() }
        XCTAssertNotEqual(first, second)
        let entries = library.loadAll()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].path, second)
        XCTAssertEqual(entries[0].note.title, "改名后")
        XCTAssertEqual(entries[0].note.body, note.body)
    }

    func testExternalModificationCreatesConflictCopyInsteadOfOverwriting() throws {
        let library = try NotesLibrary(root: root)
        var note = sample()
        guard case .saved(let name, let modified) = try library.save(note, previousPath: nil, expectedModified: nil) else { return XCTFail() }
        let url = library.notesDirectory.appendingPathComponent(name)
        try "外部编辑".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        note.body = "本应用编辑"
        guard case .conflict(let copy, _, _) = try library.save(note, previousPath: name, expectedModified: modified) else { return XCTFail("应生成冲突副本") }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "外部编辑")
        XCTAssertNotEqual(copy.id, note.id)
        XCTAssertTrue(copy.title.contains("冲突副本"))
        XCTAssertEqual(library.loadAll().count, 2)
    }

    func testPlainMarkdownAndDuplicateIDsGetStableIDs() throws {
        let library = try NotesLibrary(root: root)
        let note = sample()
        guard case .saved(let name, _) = try library.save(note, previousPath: nil, expectedModified: nil) else { return XCTFail() }
        try FileManager.default.copyItem(at: library.notesDirectory.appendingPathComponent(name), to: library.notesDirectory.appendingPathComponent("副本.md"))
        try "# 外部 Markdown".write(to: library.notesDirectory.appendingPathComponent("外部.md"), atomically: true, encoding: .utf8)
        let first = library.loadAll().map(\.note.id).sorted()
        XCTAssertEqual(Set(first).count, 3)
        XCTAssertEqual(library.loadAll().map(\.note.id).sorted(), first)
    }

    func testSecondInstanceIsReadOnly() throws {
        let owner = try NotesLibrary(root: root)
        XCTAssertFalse(owner.readOnly)
        let second = try NotesLibrary(root: root)
        XCTAssertTrue(second.readOnly)
        XCTAssertThrowsError(try second.save(sample(), previousPath: nil, expectedModified: nil))
        withExtendedLifetime(owner) {}
    }
}

final class NotesBackupTests: XCTestCase {
    private var base: URL!
    private var library: NotesLibrary!
    private var destination: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("windowatlas-backup-\(UUID().uuidString)")
        library = try NotesLibrary(root: base.appendingPathComponent("Notes"))
        destination = base.appendingPathComponent("GoogleDrive")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { library = nil; try? FileManager.default.removeItem(at: base) }

    private func image() throws -> String {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
        return try library.importAttachment(XCTUnwrap(image.tiffRepresentation))
    }

    private func run(_ items: [NotesBackup.Item], at date: Date) throws -> NotesBackup.Report {
        try NotesBackup.run(items: items, attachmentsDirectory: library.attachmentsDirectory, libraryRoot: library.root, destination: destination, now: date)
    }

    func testSensitiveNotesAndTheirOnlyAttachmentsAreExcluded() throws {
        let shared = try image()
        let backupRoot = destination.appendingPathComponent(NotesBackup.folderName)
        let items = [
            NotesBackup.Item(path: "公开.md", text: "![](../attachments/\(shared))\nexport TOKEN=abcdefgh12345678", sensitive: false),
            NotesBackup.Item(path: "私密.md", text: "密钥笔记", sensitive: true)
        ]
        let report = try run(items, at: Date())
        let snapshot = backupRoot.appendingPathComponent(try XCTUnwrap(report.snapshotName))
        XCTAssertEqual(report.noteCount, 1)
        XCTAssertEqual(report.excludedSensitive, 1)
        XCTAssertEqual(report.secretWarnings, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("公开.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("私密.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupRoot.appendingPathComponent("attachments/\(shared)").path))

        // 图片只被敏感笔记引用时不进入备份。
        let privateImage = try NoteAttachments.prepare(XCTUnwrap(NSImage(size: NSSize(width: 3, height: 3)).withFill().tiffRepresentation))
        try privateImage.data.write(to: library.attachmentsDirectory.appendingPathComponent(privateImage.name))
        _ = try run([NotesBackup.Item(path: "私密.md", text: "![](../attachments/\(privateImage.name))", sensitive: true)], at: Date().addingTimeInterval(10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupRoot.appendingPathComponent("attachments/\(privateImage.name)").path))
    }

    func testUnchangedContentIsSkippedAndChangesCreateNewSnapshot() throws {
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        // 真实备份内容由 NoteFormat.encode 生成；跳过前会按恢复标准核验快照，因此测试数据也需带头部。
        func item(_ body: String) -> NotesBackup.Item {
            NotesBackup.Item(path: "a.md", text: NoteFormat.encode(NoteDocument(id: "A", title: "a", body: body, created: start, updated: start)), sensitive: false)
        }
        XCTAssertNotNil(try run([item("一")], at: start).snapshotName)
        let skipped = try run([item("一")], at: start.addingTimeInterval(600))
        XCTAssertTrue(skipped.skippedUnchanged)
        XCTAssertNil(skipped.snapshotName)
        XCTAssertNotNil(try run([item("二")], at: start.addingTimeInterval(1200)).snapshotName)
        XCTAssertEqual(NotesBackup.snapshots(in: destination).count, 2)
        let manifest = try NotesBackup.manifest(at: NotesBackup.snapshots(in: destination)[0].url)
        XCTAssertEqual(manifest.notes.first?.sha256, sha256(Data(item("二").text.utf8)))
    }

    func testPartialAndForeignFoldersAreNotSnapshots() throws {
        let root = destination.appendingPathComponent(NotesBackup.folderName)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".2026-01-01 000000.partial"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("2026-01-02 000000"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("我的文件"), withIntermediateDirectories: true)
        XCTAssertTrue(NotesBackup.snapshots(in: destination).isEmpty)
        XCTAssertNotNil(try run([NotesBackup.Item(path: "a.md", text: "x", sensitive: false)], at: Date()).snapshotName)
        XCTAssertEqual(NotesBackup.snapshots(in: destination).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("我的文件").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-01-02 000000").path))
    }

    func testRetentionKeepsRecentThenOnePerDayWithinThirtyDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let now = formatter.date(from: "2026-10-18 120000")!
        var names: [String] = []
        for hour in 0..<22 { names.append(formatter.string(from: now.addingTimeInterval(Double(-hour) * 600))) }
        let older = ["2026-10-10 090000", "2026-10-10 180000", "2026-10-09 100000", "2026-08-01 100000"]
        let expired = NotesBackup.expiredSnapshots(names + older + ["我的文件"], now: now, calendar: calendar)
        XCTAssertEqual(Set(expired), Set([names[21], "2026-10-10 090000", "2026-08-01 100000"]))
        XCTAssertTrue(NotesBackup.expiredSnapshots(Array(names.prefix(20)), now: now).isEmpty)
    }

    func testDestinationCannotContainOrBeInsideLibrary() {
        XCTAssertNotNil(NotesBackup.validate(destination: library.root, libraryRoot: library.root))
        XCTAssertNotNil(NotesBackup.validate(destination: library.notesDirectory, libraryRoot: library.root))
        XCTAssertNotNil(NotesBackup.validate(destination: base.appendingPathComponent("不存在"), libraryRoot: library.root))
        XCTAssertNil(NotesBackup.validate(destination: destination, libraryRoot: library.root))
        // 备份根目录本身就是笔记库的父目录时，会把笔记库纳入备份目录内，必须拒绝。
        let parentBackup = library.root.deletingLastPathComponent()
        XCTAssertNotNil(NotesBackup.validate(destination: parentBackup.deletingLastPathComponent(),
            libraryRoot: parentBackup.deletingLastPathComponent().appendingPathComponent(NotesBackup.folderName + "/Notes")))
    }
}

private extension NSImage {
    func withFill() -> NSImage {
        lockFocus(); NSColor.green.setFill(); NSRect(origin: .zero, size: size).fill(); unlockFocus()
        return self
    }
}
