import Foundation
import XCTest
@testable import WindowAtlas

final class NotesImportSafetyTests: XCTestCase {
    func testMarkdownImportPreservesBlankLinesAndLineEndings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("windowatlas-import-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("example.md")
        let markdown = "# 原始笔记\r\n\r\n\r\n\r\n```python\r\n    print('缩进')\r\n\r\n\r\n\r\n```\r\n"
        try Data(markdown.utf8).write(to: source)

        XCTAssertEqual(try NoteImporter.convert(source).body, markdown)
    }

    func testCodeImportPreservesTrailingBlankLinesInsideFence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("windowatlas-import-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("example.py")
        let code = "    print('保留缩进')\n\n\n\n\n"
        try Data(code.utf8).write(to: source)

        let note = try NoteImporter.convert(source)
        XCTAssertEqual(note.body, "来源：example.py\n\n```python\n\(code)```\n")
    }
}
