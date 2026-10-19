import XCTest
@testable import WindowAtlas

final class NotesTreeTests: XCTestCase {
    private var base: URL!
    private var library: NotesLibrary!
    private let imageHash = String(repeating: "b", count: 64)

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("windowatlas-tree-\(UUID().uuidString)")
        library = try NotesLibrary(root: base.appendingPathComponent("Notes"))
    }

    override func tearDownWithError() throws { library = nil; try? FileManager.default.removeItem(at: base) }

    private func note(_ id: String, _ title: String, _ body: String = "正文", sensitive: Bool = false) -> NoteDocument {
        var value = NoteDocument(id: id, title: title, body: body, created: Date(), updated: Date())
        value.sensitive = sensitive
        return value
    }

    @discardableResult
    private func save(_ value: NoteDocument, in container: String) throws -> String {
        guard case .saved(let path, _) = try library.save(value, previousPath: nil, expectedModified: nil, container: container) else {
            throw NotesLibrary.LibraryError.invalidLocation
        }
        return path
    }

    private func text(_ path: String) throws -> String { try String(contentsOf: library.url(path), encoding: .utf8) }

    func testNestedFoldersNotesAndChildNotesScanCorrectly() throws {
        let project = try library.createFolder(named: "26window-manager", in: "")
        let deep = try library.createFolder(named: "调试", in: try library.createFolder(named: "构建", in: project))
        let parent = try save(note("P", "部署"), in: deep)
        let child = try save(note("C", "回滚"), in: NotesLibrary.childrenContainer(ofNote: parent))
        let grandchild = try save(note("G", "回滚细节"), in: NotesLibrary.childrenContainer(ofNote: child))
        _ = try library.createFolder(named: "子笔记下的目录", in: NotesLibrary.childrenContainer(ofNote: child))
        let scan = library.scan()
        XCTAssertEqual(Set(scan.entries.map(\.path)), [parent, child, grandchild])
        XCTAssertEqual(NotesLibrary.depth(of: NotesLibrary.parent(of: grandchild)), 5)
        // 笔记的子级文件夹不算普通目录；用户在子笔记下建的目录算。
        XCTAssertEqual(scan.folders, [project, project + "/构建", deep, NotesLibrary.childrenContainer(ofNote: child) + "/子笔记下的目录"])
    }

    func testTitleRenameCarriesChildrenFolder() throws {
        let parent = try save(note("P", "部署"), in: "")
        let child = try save(note("C", "回滚"), in: NotesLibrary.childrenContainer(ofNote: parent))
        guard case .saved(let renamed, _) = try library.save(note("P", "发布"), previousPath: parent,
                                                              expectedModified: library.modificationDate(path: parent)) else { return XCTFail() }
        XCTAssertNotEqual(renamed, parent)
        let paths = Set(library.loadAll().map(\.path))
        XCTAssertEqual(paths, [renamed, NotesLibrary.childrenContainer(ofNote: renamed) + "/" + (child as NSString).lastPathComponent])
    }

    func testMoveNoteWithChildrenRewritesLinksAndRejectsMovingIntoItself() throws {
        let parent = try save(note("P", "部署", "![](../attachments/\(imageHash).png)"), in: "")
        let child = try save(note("C", "回滚", "![](../../attachments/\(imageHash).png)"), in: NotesLibrary.childrenContainer(ofNote: parent))
        let target = try library.createFolder(named: "B", in: try library.createFolder(named: "A", in: ""))
        XCTAssertThrowsError(try library.moveNote(parent, to: NotesLibrary.childrenContainer(ofNote: parent))) {
            XCTAssertEqual($0 as? NotesLibrary.LibraryError, .moveIntoItself)
        }
        let moved = try library.moveNote(parent, to: target)
        XCTAssertEqual(moved, "A/B/" + (parent as NSString).lastPathComponent)
        XCTAssertTrue(try text(moved).contains("](../../../attachments/\(imageHash).png)"))
        let movedChild = NotesLibrary.childrenContainer(ofNote: moved) + "/" + (child as NSString).lastPathComponent
        XCTAssertTrue(try text(movedChild).contains("](../../../../attachments/\(imageHash).png)"))
        XCTAssertEqual(library.loadAll().count, 2)
    }

    func testFolderMoveRenameDeleteAndNameCollision() throws {
        let a = try library.createFolder(named: "A", in: "")
        let b = try library.createFolder(named: "B", in: a)
        XCTAssertThrowsError(try library.moveFolder(a, to: b)) { XCTAssertEqual($0 as? NotesLibrary.LibraryError, .moveIntoItself) }
        XCTAssertEqual(try library.createFolder(named: "A", in: ""), "A 2")
        XCTAssertEqual(try library.createFolder(named: "../逃逸", in: ""), "-逃逸")
        let inner = try save(note("N", "命令", "![](../../../attachments/\(imageHash).png)"), in: b)
        let moved = try library.moveFolder(b, to: "")
        XCTAssertEqual(moved, "B")
        XCTAssertTrue(try text("B/" + (inner as NSString).lastPathComponent).contains("](../../attachments/\(imageHash).png)"))
        XCTAssertThrowsError(try library.deleteEmptyFolder("B")) { XCTAssertEqual($0 as? NotesLibrary.LibraryError, .folderNotEmpty) }
        _ = try library.createFolder(named: "空子目录", in: a)
        XCTAssertNoThrow(try library.deleteEmptyFolder(a))
        XCTAssertEqual(try library.renameFolder("A 2", to: "改名"), "改名")
        XCTAssertThrowsError(try library.createFolder(named: "x", in: "../外部"))
    }

    func testTreeSnapshotRestoresFoldersAndNestedNotes() throws {
        let project = try library.createFolder(named: "项目", in: "")
        _ = try library.createFolder(named: "空目录", in: project)
        let parent = try save(note("P", "部署"), in: project)
        try save(note("C", "回滚"), in: NotesLibrary.childrenContainer(ofNote: parent))
        try save(note("S", "密钥", sensitive: true), in: project)
        let destination = base.appendingPathComponent("Drive")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let scan = library.scan()
        let items = scan.entries.map { NotesBackup.Item(path: $0.path, text: NoteFormat.encode($0.note), sensitive: $0.note.sensitive) }
        let report = try NotesBackup.run(items: items, folders: scan.folders, attachmentsDirectory: library.attachmentsDirectory,
                                         libraryRoot: library.root, destination: destination)
        let snapshot = destination.appendingPathComponent(NotesBackup.folderName).appendingPathComponent(try XCTUnwrap(report.snapshotName))

        // 新电脑：空库恢复。
        let fresh = try NotesLibrary(root: base.appendingPathComponent("Fresh"))
        _ = try fresh.restore(NotesBackup.verify(snapshot: snapshot))
        let restored = fresh.scan()
        XCTAssertEqual(Set(restored.entries.map(\.note.id)), ["P", "C"], "敏感笔记不在备份中")
        XCTAssertEqual(Set(restored.entries.map(\.path)), Set(scan.entries.filter { !$0.note.sensitive }.map(\.path)))
        XCTAssertTrue(restored.folders.contains("项目/空目录"))
    }

    func testExportImportRoundTripAsksAboutSensitive() throws {
        let project = try library.createFolder(named: "项目", in: "")
        try save(note("A", "部署"), in: project)
        try save(note("S", "密钥", sensitive: true), in: project)
        let scan = library.scan()
        let items = scan.entries.map { NotesBackup.Item(path: $0.path, text: NoteFormat.encode($0.note), sensitive: $0.note.sensitive) }
        for include in [false, true] {
            let zip = base.appendingPathComponent("导出-\(include).zip")
            let report = try NotesArchive.export(items: items, folders: scan.folders, attachmentsDirectory: library.attachmentsDirectory,
                                                 libraryRoot: library.root, to: zip, includeSensitive: include)
            XCTAssertEqual(report.noteCount, include ? 2 : 1)
            let located = try NotesArchive.locateSnapshot(in: zip)
            defer { if let cleanup = located.cleanup { try? FileManager.default.removeItem(at: cleanup) } }
            let fresh = try NotesLibrary(root: base.appendingPathComponent("Computer-\(include)"))
            _ = try fresh.restore(NotesBackup.verify(snapshot: located.snapshot))
            XCTAssertEqual(Set(fresh.loadAll().map(\.note.id)), include ? ["A", "S"] : ["A"])
            XCTAssertTrue(fresh.loadAll().allSatisfy { $0.path.hasPrefix("项目/") })
        }
    }

    func testImportRejectsZipWithTraversalEntry() throws {
        let zip = base.appendingPathComponent("evil.zip")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try MinimalZip.write(entries: [("../evil.txt", Data("x".utf8))], to: zip)
        XCTAssertThrowsError(try NotesArchive.locateSnapshot(in: zip)) { XCTAssertTrue("\($0)".contains("unsafeEntry")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory.appendingPathComponent("evil.txt").path))
    }

    @MainActor
    func testStoreTreeAndBreadcrumbShowParentNoteTitle() throws {
        library = nil
        let store = NotesStore(root: base.appendingPathComponent("Notes"))
        store.createFolder(named: "项目", in: "")
        store.createNote(in: "项目")
        let parentID = try XCTUnwrap(store.selectedID)
        store.update(parentID) { $0.title = "部署" }
        store.flush()
        store.createChildNote(of: parentID)
        let childID = try XCTUnwrap(store.selectedID)
        store.flush()
        let tree = store.tree()
        XCTAssertEqual(tree.map(\.title), ["项目"])
        XCTAssertEqual(tree[0].children?.map(\.title), ["部署"])
        XCTAssertEqual(tree[0].children?[0].children?.map(\.id), ["note:" + childID])
        XCTAssertEqual(store.breadcrumb(store.container(ofNote: childID)), "项目 › 部署")
        store.update(childID) { $0.archived = true }
        store.flush()
        XCTAssertNil(store.tree()[0].children?[0].children, "下级全部归档后父笔记不再显示展开")
    }
}

/// 测试用的最小 zip 写入器（仅存储方式），用来构造带越界路径的恶意压缩包。
enum MinimalZip {
    static func write(entries: [(String, Data)], to url: URL) throws {
        var archive = Data(), central = Data()
        for (name, data) in entries {
            let offset = UInt32(archive.count), nameData = Data(name.utf8), crc = crc32(data), size = UInt32(data.count)
            let local: [Data] = [le32(0x04034b50), le16(20), le16(0), le16(0), le16(0), le16(0), le32(crc),
                                 le32(size), le32(size), le16(UInt16(nameData.count)), le16(0), nameData, data]
            let record: [Data] = [le32(0x02014b50), le16(20), le16(20), le16(0), le16(0), le16(0), le16(0), le32(crc),
                                  le32(size), le32(size), le16(UInt16(nameData.count)), le16(0), le16(0),
                                  le16(0), le16(0), le32(0), le32(offset), nameData]
            archive.append(local.reduce(Data(), +))
            central.append(record.reduce(Data(), +))
        }
        let start = UInt32(archive.count)
        let end: [Data] = [le32(0x06054b50), le16(0), le16(0), le16(UInt16(entries.count)), le16(UInt16(entries.count)),
                           le32(UInt32(central.count)), le32(start), le16(0)]
        archive.append(central)
        archive.append(end.reduce(Data(), +))
        try archive.write(to: url)
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) }
        }
        return ~crc
    }
}
