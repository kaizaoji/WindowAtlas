import XCTest
import AppKit
@testable import WindowAtlas

final class NotesImportTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("windowatlas-import-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    @discardableResult
    private func write(_ name: String, _ text: String) throws -> URL {
        let url = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func pngData() throws -> Data {
        let image = NSImage(size: NSSize(width: 3, height: 3))
        image.lockFocus(); NSColor.orange.setFill(); NSRect(x: 0, y: 0, width: 3, height: 3).fill(); image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    }

    func testMarkdownKeepsBodyAndImportsOnlyLocalRelativeImages() throws {
        try pngData().write(to: base.appendingPathComponent("img/截图 1.png").creatingParent())
        let url = try write("部署.md", "# 发布流程\n\n![图](img/%E6%88%AA%E5%9B%BE%201.png)\n![远程](https://example.com/a.png)\n![绝对](/etc/a.png)\n```sh\nmake\n```\n")
        let note = try NoteImporter.convert(url)
        XCTAssertEqual(note.title, "发布流程")
        var stored: [Data] = []
        let rewritten = NoteImporter.rewriteLocalImages(in: note.body, baseDirectory: base, depth: 1) { stored.append($0); return "\(String(repeating: "c", count: 64)).png" }
        XCTAssertEqual(rewritten.imported, 1)
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(rewritten.body.contains("![图](../../attachments/\(String(repeating: "c", count: 64)).png)"))
        XCTAssertTrue(rewritten.body.contains("https://example.com/a.png"))
        XCTAssertTrue(rewritten.body.contains("](/etc/a.png)"))
        XCTAssertEqual(NoteSnippets.extract(from: note).map(\.code), ["make"])
    }

    func testJsonAndCodeBecomeCopyableBlocksWithExactContent() throws {
        let json = "{\n  \"scripts\": {\n\t\"dev\": \"vite\"\n  }\n}\n"
        let note = try NoteImporter.convert(try write("package.json", json))
        XCTAssertEqual(note.title, "package.json")
        let snippets = NoteSnippets.extract(from: note)
        XCTAssertEqual(snippets.map(\.language), ["json"])
        XCTAssertEqual(snippets.first?.code, String(json.dropLast()))

        let markdownInCode = "echo '```'\nprint(\"````\")"
        let script = try NoteImporter.convert(try write("tool.py", markdownInCode))
        XCTAssertEqual(NoteSnippets.extract(from: script).first?.code, markdownInCode)
        XCTAssertEqual(NoteSnippets.extract(from: try NoteImporter.convert(try write("Dockerfile", "FROM swift"))).first?.language, "dockerfile")
    }

    func testHtmlIsConvertedOfflineWithoutScripts() throws {
        let html = "<html><head><title>运维 &amp; 部署</title><script>alert(1)</script></head><body><h1>步骤</h1><p>先运行&nbsp;<b>测试</b></p><pre>swift test &amp;&amp; build</pre><ul><li>一</li></ul></body></html>"
        let note = try NoteImporter.convert(try write("a.html", html))
        XCTAssertEqual(note.title, "运维 & 部署")
        XCTAssertFalse(note.body.contains("alert"))
        XCTAssertTrue(note.body.contains("## 步骤"))
        XCTAssertTrue(note.body.contains("先运行 测试"))
        XCTAssertEqual(NoteSnippets.extract(from: note).first?.code, "swift test && build")
    }

    func testRtfPdfAndLegacyChineseEncoding() throws {
        let rtf = try NSAttributedString(string: "富文本内容").data(from: NSRange(location: 0, length: 5),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let rtfURL = base.appendingPathComponent("说明.rtf")
        try rtf.write(to: rtfURL)
        XCTAssertTrue(try NoteImporter.convert(rtfURL).body.contains("富文本内容"))

        let pdfURL = base.appendingPathComponent("手册.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try XCTUnwrap(CGContext(pdfURL as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "PDF manual text", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        context.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        XCTAssertTrue(try NoteImporter.convert(pdfURL).body.contains("PDF manual text"))

        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let legacy = base.appendingPathComponent("旧笔记.txt")
        try XCTUnwrap("中文旧编码".data(using: gbk)).write(to: legacy)
        XCTAssertEqual(try NoteImporter.convert(legacy).body, "中文旧编码")
    }

    func testLimitsAndUnsupportedTypes() throws {
        XCTAssertFalse(NoteImporter.isSupported(base.appendingPathComponent("a.exe")))
        XCTAssertFalse(NoteImporter.isSupported(base.appendingPathComponent("a.png")))
        XCTAssertTrue(NoteImporter.isSupported(base.appendingPathComponent("a.yaml")))
        let big = base.appendingPathComponent("big.txt")
        try Data(count: NoteImporter.maxBytes + 1).write(to: big)
        XCTAssertThrowsError(try NoteImporter.convert(big)) { XCTAssertEqual($0 as? NoteImporter.ImportError, .tooLarge) }
    }

    @MainActor
    func testFolderImportKeepsStructureAndSkipsUnsupported() async throws {
        try write("项目资料/README.md", "# 项目说明\n正文")
        try write("项目资料/配置/app.yaml", "port: 8080\n")
        try write("项目资料/配置/深层/run.sh", "npm run dev\n")
        try write("项目资料/程序.exe", "binary")
        try write("项目资料/.secret.md", "隐藏文件不导入")
        let store = NotesStore(root: base.appendingPathComponent("Notes"))
        store.importDocuments([base.appendingPathComponent("项目资料")], into: "")
        for _ in 0..<200 where !(store.message?.hasPrefix("已导入") ?? false) { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(store.message, "已导入 3 篇笔记；跳过 1 个不支持、过大或无法读取的文件。")
        let paths = Set(store.paths.values.map { NotesLibrary.parent(of: $0.path) })
        XCTAssertEqual(paths, ["项目资料", "项目资料/配置", "项目资料/配置/深层"])
        XCTAssertEqual(store.searchSnippets("npm run dev").count, 1)
        XCTAssertEqual(store.tree().map(\.title), ["项目资料"])
    }
}

private extension URL {
    func creatingParent() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
