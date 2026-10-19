import XCTest
@testable import WindowAtlas

final class CommandLibraryTests: XCTestCase {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("windowatlas-commands-\(UUID().uuidString)", isDirectory: true)
    }

    @MainActor
    func testSeedsOnlyCreateFirstLibraryAndEditsSurviveRelaunch() throws {
        let root = temporaryRoot()
        let seed = CommandEntry(title: "初始命令", tool: "测试工具", command: "tool --help")
        var store: CommandLibraryStore! = CommandLibraryStore(root: root, seeds: [seed])
        XCTAssertFalse(store.isReadOnly)
        var edited = try XCTUnwrap(store.entries.first)
        edited.title = "我的命令"
        edited.command = "tool --version\n\n# 保留空行"
        XCTAssertTrue(store.save(edited))
        XCTAssertTrue(store.archive(edited.id))
        store = nil
        let reopened = CommandLibraryStore(root: root, seeds: [seed, CommandEntry(title: "新增模板", tool: "测试工具", command: "tool list")])
        XCTAssertEqual(reopened.entries.count, 1)
        XCTAssertEqual(reopened.entries.first?.title, edited.title)
        XCTAssertEqual(reopened.entries.first?.command, edited.command)
        XCTAssertTrue(try XCTUnwrap(reopened.entries.first).archived)
        XCTAssertEqual(reopened.entries.first?.created, seed.created)
        XCTAssertTrue(reopened.restore(seed.id))
        XCTAssertEqual(reopened.filtered().count, 1)
    }

    @MainActor
    func testCorruptJSONIsReadOnlyAndNeverOverwrittenBySeedsOrSave() throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = root.appendingPathComponent("library.json")
        let original = Data("{ broken json".utf8)
        try original.write(to: library)
        let seed = CommandEntry(title: "命令", tool: "工具", command: "help")
        let store = CommandLibraryStore(root: root, seeds: [seed])
        XCTAssertTrue(store.isReadOnly)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(store.save(seed))
        XCTAssertEqual(try Data(contentsOf: library), original)
    }

    @MainActor
    func testSaveAndUsageFailuresPreserveMemoryThenRetry() throws {
        let root = temporaryRoot()
        let seed = CommandEntry(title: "命令", tool: "工具", command: "help")
        let store = CommandLibraryStore(root: root, seeds: [seed])
        let original = try Data(contentsOf: store.libraryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        var edited = seed
        edited.title = "不应假装保存成功"
        XCTAssertFalse(store.save(edited))
        XCTAssertFalse(store.recordUse(seed.id))
        XCTAssertFalse(store.toggleFavorite(seed.id))
        XCTAssertFalse(store.archive(seed.id))
        XCTAssertEqual(store.entries, [seed])
        XCTAssertEqual(try Data(contentsOf: store.libraryURL), original)
        XCTAssertNotNil(store.errorMessage)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        XCTAssertTrue(store.save(edited))
        XCTAssertTrue(store.recordUse(seed.id))
        XCTAssertTrue(store.toggleFavorite(seed.id))
        XCTAssertNil(store.errorMessage)
        let reopened = CommandLibraryStore(root: root)
        XCTAssertEqual(reopened.entries.first?.title, edited.title)
        XCTAssertEqual(reopened.entries.first?.useCount, 1)
        XCTAssertNotNil(reopened.entries.first?.lastUsed)
        XCTAssertEqual(reopened.entries.first?.favorite, true)
    }

    @MainActor
    func testSearchFilterAndUsageSort() throws {
        let favorite = CommandEntry(title: "最爱", tool: "工具甲", command: "alpha", favorite: true)
        let frequent = CommandEntry(title: "常用", tool: "工具乙", command: "beta", purpose: "查找用途", example: "example-needle", useCount: 3)
        let recent = CommandEntry(title: "最近", tool: "工具甲", command: "gamma", useCount: 1, lastUsed: Date())
        let old = CommandEntry(title: "较早", tool: "工具甲", command: "delta", useCount: 1, lastUsed: Date(timeIntervalSince1970: 1))
        let archived = CommandEntry(title: "归档", tool: "工具丙", command: "epsilon", archived: true)
        let store = CommandLibraryStore(root: temporaryRoot(), seeds: [old, frequent, archived, recent, favorite])
        XCTAssertEqual(store.filtered().map(\.id), [favorite.id, frequent.id, recent.id, old.id])
        XCTAssertEqual(store.filtered(query: "EXAMPLE-NEEDLE").map(\.id), [frequent.id])
        XCTAssertEqual(store.filtered(query: "用途").map(\.id), [frequent.id])
        XCTAssertEqual(store.filtered(query: "gamma", tool: "工具甲").map(\.id), [recent.id])
        XCTAssertTrue(store.filtered(query: "gamma", tool: "工具乙").isEmpty)
        XCTAssertEqual(store.filtered(includeArchived: true).count, 5)
        XCTAssertEqual(Set(store.tools), Set(["工具甲", "工具乙"]))
    }

    @MainActor
    func testInvalidInputAndExternalChangesDoNotOverwriteDisk() throws {
        let seed = CommandEntry(title: "命令", tool: "工具", command: "help")
        let store = CommandLibraryStore(root: temporaryRoot(), seeds: [seed])
        var invalid = seed
        invalid.command = "  \n"
        XCTAssertFalse(store.save(invalid))
        invalid = seed
        invalid.sourceURL = URL(string: "javascript:alert(1)")
        XCTAssertFalse(store.save(invalid))
        XCTAssertEqual(store.entries, [seed])
        let external = Data("{ external edit in progress".utf8)
        try external.write(to: store.libraryURL)
        XCTAssertFalse(store.recordUse(seed.id))
        XCTAssertTrue(store.isReadOnly)
        XCTAssertEqual(try Data(contentsOf: store.libraryURL), external)
        XCTAssertEqual(store.entries, [seed])
    }

    @MainActor
    func testSavingOldDraftPreservesNewUsageAndFavoriteState() throws {
        let entry = CommandEntry(title: "命令", tool: "工具", command: "help")
        let store = CommandLibraryStore(root: temporaryRoot(), seeds: [entry])
        var draft = entry
        draft.purpose = "补充用途"
        XCTAssertTrue(store.recordUse(entry.id))
        XCTAssertTrue(store.toggleFavorite(entry.id))
        XCTAssertTrue(store.save(draft))
        XCTAssertEqual(store.entries.first?.purpose, draft.purpose)
        XCTAssertEqual(store.entries.first?.useCount, 1)
        XCTAssertEqual(store.entries.first?.favorite, true)
        XCTAssertNotNil(store.entries.first?.lastUsed)
    }
    @MainActor
    func testSecondInstanceIsReadOnlyAndWriterLockReleasesWithOwner() throws {
        let root = temporaryRoot()
        let seed = CommandEntry(title: "首实例", tool: "工具", command: "help")
        var owner: CommandLibraryStore? = CommandLibraryStore(root: root, seeds: [seed])
        let reader = CommandLibraryStore(root: root)
        XCTAssertTrue(reader.isReadOnly)
        XCTAssertEqual(reader.entries, [seed])
        XCTAssertNotNil(reader.errorMessage)
        XCTAssertFalse(reader.save(CommandEntry(title: "拒绝第二实例写入", tool: "工具", command: "version")))
        XCTAssertTrue(try XCTUnwrap(owner).recordUse(seed.id))
        owner = nil
        let successor = CommandLibraryStore(root: root)
        XCTAssertFalse(successor.isReadOnly)
        XCTAssertEqual(successor.entries.first?.useCount, 1)
        XCTAssertTrue(successor.save(CommandEntry(title: "接续写入", tool: "工具", command: "version")))
        XCTAssertEqual(successor.entries.count, 2)
        XCTAssertTrue(reader.isReadOnly, "既有只读实例不应在后台自行夺取写锁")
    }

    @MainActor
    func testUnreadableLibraryNeverReplacedBySeeds() throws {
        let root = temporaryRoot()
        let seed = CommandEntry(title: "原命令", tool: "工具", command: "help")
        var owner: CommandLibraryStore? = CommandLibraryStore(root: root, seeds: [seed])
        let libraryURL = try XCTUnwrap(owner).libraryURL
        let original = try Data(contentsOf: libraryURL)
        owner = nil
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: libraryURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: libraryURL.path) }
        let blocked = CommandLibraryStore(root: root, seeds: [CommandEntry(title: "不得覆盖", tool: "工具", command: "version")])
        XCTAssertTrue(blocked.isReadOnly)
        XCTAssertFalse(blocked.save(seed))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: libraryURL.path)
        XCTAssertEqual(try Data(contentsOf: libraryURL), original)
    }

    @MainActor
    func testEditorGuardBlocksLeavingUntilSavedOrCancelled() {
        let store = CommandLibraryStore(root: temporaryRoot())
        XCTAssertFalse(store.isEditing)
        XCTAssertTrue(store.canLeaveEditor())
        store.beginEditing()
        XCTAssertTrue(store.isEditing)
        XCTAssertFalse(store.canLeaveEditor())
        XCTAssertNotNil(store.errorMessage)
        store.endEditing()
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isEditing)
        XCTAssertTrue(store.canLeaveEditor())
    }


    @MainActor
    func testTemplateAdditionsReachExistingLibraryOnceWithoutDuplicates() throws {
        let root = temporaryRoot()
        let seed = CommandEntry(title: "旧模板", tool: "Codex", command: "/plan")
        // 旧版本建库：只有初始模板，没有修订号文件。
        _ = CommandLibraryStore(root: root, seeds: [seed])
        try FileManager.default.removeItem(at: root.appendingPathComponent("template-revision"))
        let resume = CommandEntry(title: "恢复", tool: "Codex", command: "codex resume")
        let duplicate = CommandEntry(title: "重复", tool: "Codex", command: "/plan")
        let additions = [CommandTemplates.Addition(revision: 2, entries: [resume, duplicate])]
        var store: CommandLibraryStore? = CommandLibraryStore(root: root, seeds: [seed], additions: additions)
        XCTAssertEqual(store?.entries.map(\.command), ["/plan", "codex resume"], "只补充新命令，命令相同的不重复")
        store = nil
        // 用户删掉补充的命令后，再次启动不会被加回来。
        let again = CommandLibraryStore(root: root, seeds: [seed], additions: additions)
        XCTAssertEqual(again.entries.count, 2)
        XCTAssertTrue(again.archive(again.entries[1].id))
        let third = CommandLibraryStore(root: root, seeds: [seed], additions: additions)
        XCTAssertEqual(third.entries.count, 2)
    }

    @MainActor
    func testNewLibraryContainsAllTemplatesIncludingCodexResume() {
        let store = CommandLibraryStore(root: temporaryRoot(), seeds: CommandTemplates.entries, additions: CommandTemplates.additions)
        let commands = store.entries.map(\.command)
        XCTAssertTrue(commands.contains("codex resume"))
        XCTAssertTrue(commands.contains("codex resume --all"))
        XCTAssertTrue(commands.contains("codex resume --last"))
        XCTAssertEqual(Set(commands).count, commands.count)
    }
}

