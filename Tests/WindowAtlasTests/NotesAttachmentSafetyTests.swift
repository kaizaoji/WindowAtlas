import AppKit
import XCTest
@testable import WindowAtlas

final class NotesAttachmentSafetyTests: XCTestCase {
    private func fixture() throws -> (NotesLibrary, Data, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("windowatlas-attachment-safety-\(UUID().uuidString)")
        let library = try NotesLibrary(root: root)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        return (library, image, try NoteAttachments.prepare(image).name)
    }

    func testReimportRepairsSameSizeCorruption() throws {
        let (library, image, name) = try fixture()
        let file = library.attachmentsDirectory.appendingPathComponent(name)
        try Data(repeating: 0, count: image.count).write(to: file)

        XCTAssertEqual(try library.importAttachment(image), name)
        XCTAssertEqual(try Data(contentsOf: file), image)
    }

    func testReimportPreservesUnchangedFile() throws {
        let (library, image, name) = try fixture()
        XCTAssertEqual(try library.importAttachment(image), name)
        let file = library.attachmentsDirectory.appendingPathComponent(name)
        let timestamp = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)

        XCTAssertEqual(try library.importAttachment(image), name)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, timestamp)
        XCTAssertEqual(try Data(contentsOf: file), image)
    }

    func testImportRejectsAttachmentSymlinkWithoutTouchingTarget() throws {
        let (library, image, name) = try fixture()
        let outside = library.root.appendingPathComponent("outside.bin")
        let original = Data("外部文件必须保留".utf8)
        try original.write(to: outside)
        let file = library.attachmentsDirectory.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)

        XCTAssertThrowsError(try library.importAttachment(image))
        XCTAssertEqual(try Data(contentsOf: outside), original)
        XCTAssertTrue(try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    func testImportRejectsDirectoryAtAttachmentPath() throws {
        let (library, image, name) = try fixture()
        let file = library.attachmentsDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try library.importAttachment(image))
        XCTAssertTrue(try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }
}
