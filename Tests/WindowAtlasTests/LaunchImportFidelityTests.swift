import XCTest
import AppKit
@testable import WindowAtlas

/// 上线审计 R6/R7/R8 回归：导入不得改写代码、丢缩进或读错编码。
final class LaunchImportFidelityTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("windowatlas-fidelity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
        try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
            .write(to: base.appendingPathComponent("example.png"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private let fakeName = String(repeating: "d", count: 64) + ".png"

    // MARK: R6

    func testImageLinksInsideCodeAreNotRewritten() {
        let body = """
        正文图片 ![图](example.png)

        ```python
        print("![example](example.png)")
        ```

        行内 `![x](example.png)` 不改
        """
        let result = NoteImporter.rewriteLocalImages(in: body, baseDirectory: base, depth: 0) { _ in self.fakeName }
        XCTAssertEqual(result.imported, 1, "只改写正文里的图片")
        XCTAssertTrue(result.body.contains("![图](../attachments/\(fakeName))"))
        XCTAssertTrue(result.body.contains("print(\"![example](example.png)\")"))
        XCTAssertTrue(result.body.contains("`![x](example.png)`"))
    }

    func testCodeFileImportKeepsSourceVerbatim() throws {
        let source = "print(\"![example](example.png)\")\n"
        let url = base.appendingPathComponent("tool.py")
        try source.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(NoteImporter.isMarkdown(url), "代码文件不进入图片改写流程")
        XCTAssertEqual(NoteSnippets.extract(from: try NoteImporter.convert(url)).first?.code, String(source.dropLast()))
    }

    // MARK: R7

    func testHtmlPreKeepsIndentation() {
        let text = NoteImporter.htmlToText("<p>  说明  </p><pre>if True:\n    print(&quot;hello&quot;)\n\tdone()\n</pre>")
        let note = NoteDocument(id: "h", title: "h", body: text, created: Date(), updated: Date())
        XCTAssertEqual(NoteSnippets.extract(from: note).first?.code, "if True:\n    print(\"hello\")\n\tdone()")
        XCTAssertTrue(text.hasPrefix("说明"), "普通段落仍去掉首尾空白")
    }

    // MARK: R8

    func testTextEncodingDetection() throws {
        let sample = "中文内容ABC"
        XCTAssertEqual(NoteImporter.decodeText(try XCTUnwrap(sample.data(using: .utf16LittleEndian))), sample, "无 BOM UTF-16LE")
        XCTAssertEqual(NoteImporter.decodeText(try XCTUnwrap(sample.data(using: .utf16BigEndian))), sample, "无 BOM UTF-16BE")
        XCTAssertEqual(NoteImporter.decodeText(try XCTUnwrap("纯中文没有英文字母".data(using: .utf16LittleEndian))), "纯中文没有英文字母")
        XCTAssertEqual(NoteImporter.decodeText(Data([0xFF, 0xFE]) + (try XCTUnwrap(sample.data(using: .utf16LittleEndian)))), sample, "带 BOM")
        XCTAssertEqual(NoteImporter.decodeText(Data([0xEF, 0xBB, 0xBF]) + Data(sample.utf8)), sample)
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        XCTAssertEqual(NoteImporter.decodeText(try XCTUnwrap("旧编码中文笔记".data(using: gb))), "旧编码中文笔记")
        XCTAssertEqual(NoteImporter.decodeText(Data("plain ascii".utf8)), "plain ascii")
    }

    func testRtfdPackageImportsAsSingleDocument() throws {
        let attributed = NSAttributedString(string: "RTFD 文档内容")
        let wrapper = try attributed.fileWrapper(from: NSRange(location: 0, length: attributed.length),
                                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let url = base.appendingPathComponent("说明.rtfd")
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        XCTAssertTrue(NoteImporter.isDocumentPackage(url))
        XCTAssertTrue(try NoteImporter.convert(url).body.contains("RTFD 文档内容"))
    }

    @MainActor
    func testFolderImportTreatsRtfdAsFile() async throws {
        let folder = base.appendingPathComponent("资料")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let attributed = NSAttributedString(string: "包内文字")
        try attributed.fileWrapper(from: NSRange(location: 0, length: attributed.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            .write(to: folder.appendingPathComponent("手册.rtfd"), options: .atomic, originalContentsURL: nil)
        let store = NotesStore(root: base.appendingPathComponent("Notes"))
        store.importDocuments([folder], into: "")
        for _ in 0..<200 where !(store.message?.contains("1") ?? false) || store.message?.contains("…") == true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertTrue(store.notes.first?.body.contains("包内文字") == true)
        XCTAssertEqual(store.folders, ["资料"], "RTFD 包不应变成目录")
    }
}
