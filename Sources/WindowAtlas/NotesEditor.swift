import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 纯文本 Markdown 编辑器。关闭智能引号、破折号等自动替换，保证命令复制后与输入完全一致。
struct MarkdownEditor: NSViewRepresentable {
    @EnvironmentObject var notes: NotesStore
    let noteID: String
    let text: String
    let editable: Bool

    final class Coordinator: NSObject, NSTextViewDelegate {
        var noteID = ""
        var store: NotesStore?
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, let store else { return }
            let value = textView.string
            store.editBody(noteID, value)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let textView = NoteTextView(frame: .zero)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.backgroundColor = NSColor(AtlasStyle.canvas)
        textView.textColor = .textColor
        textView.insertionPointColor = .textColor
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel(L("笔记正文"))
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NoteTextView else { return }
        textView.setAccessibilityLabel(L("笔记正文"))
        let coordinator = context.coordinator
        coordinator.store = notes
        textView.onImages = { [weak notes] datas in datas.compactMap { notes?.importImage($0) } }
        textView.onError = { [weak notes] message in notes?.message = message }
        if coordinator.noteID != noteID {
            coordinator.noteID = noteID
            textView.string = text
            // 切换笔记时清空撤销栈，避免撤销把另一篇笔记的内容写进当前笔记。
            textView.undoManager?.removeAllActions()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        } else if !textView.hasMarkedText(), textView.string != text {
            // 中文输入法组字期间不回写，否则窗口刷新或保存状态变化会打断拼音输入。
            textView.string = text
        }
        textView.isEditable = editable
        notes.activeTextView = textView
    }
}

final class NoteTextView: NSTextView {
    var onImages: (([Data]) -> [String])?
    var onError: ((String) -> Void)?

    override func paste(_ sender: Any?) {
        if insertImages(from: .general) { return }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if insertImages(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    /// 图片文件或截图数据转为附件链接；其他内容交回系统按纯文本处理。
    private func insertImages(from pasteboard: NSPasteboard) -> Bool {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        var datas: [Data] = []
        if !urls.isEmpty {
            for url in urls {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard size <= NoteAttachments.maxBytes else { onError?(NoteAttachments.ImportError.tooLarge.localizedDescription); return true }
                if let data = try? Data(contentsOf: url) { datas.append(data) }
            }
        } else if pasteboard.string(forType: .string) == nil, let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            datas = [data]
        }
        guard !datas.isEmpty, isEditable, let links = onImages?(datas) else { return false }
        if !links.isEmpty { insertText("\n" + links.joined(separator: "\n") + "\n", replacementRange: selectedRange()) }
        return true
    }
}

// MARK: 预览

enum PreviewBlock: Identifiable {
    case heading(Int, String, Int)
    case paragraph(String, Int)
    case bullet(String, String, Int)
    case code(NoteSnippet)
    case image(String, String, Int)
    case rule(Int)

    var id: String {
        switch self {
        case .heading(_, _, let line), .paragraph(_, let line), .bullet(_, _, let line), .image(_, _, let line), .rule(let line): return "l\(line)"
        case .code(let snippet): return snippet.id
        }
    }

    /// 与 NoteSnippets.extract 使用同一套围栏规则，保证预览中的复制按钮与命令列表一致。
    static func parse(_ note: NoteDocument) -> [PreviewBlock] {
        let snippets = NoteSnippets.extract(from: note)
        let lines = note.body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [PreviewBlock] = []
        var paragraph: [String] = []
        var paragraphStart = 0
        var fence: String?
        var snippetIndex = 0
        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"), paragraphStart)); paragraph = [] }
        }
        for (number, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                if NoteSnippets.closesFence(trimmed, marker: marker) { fence = nil }
                continue
            }
            if let marker = NoteSnippets.fenceMarker(trimmed) {
                flushParagraph()
                fence = marker
                if snippetIndex < snippets.count { blocks.append(.code(snippets[snippetIndex])) }
                snippetIndex += 1
                continue
            }
            if trimmed.isEmpty { flushParagraph(); continue }
            if let image = imageLink(trimmed) { flushParagraph(); blocks.append(.image(image.alt, image.link, number)); continue }
            if trimmed == "---" || trimmed == "***" { flushParagraph(); blocks.append(.rule(number)); continue }
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                flushParagraph(); blocks.append(.heading(hashes, String(trimmed.dropFirst(hashes + 1)), number)); continue
            }
            if let bullet = bulletItem(trimmed) { flushParagraph(); blocks.append(.bullet(bullet.marker, bullet.text, number)); continue }
            if paragraph.isEmpty { paragraphStart = number }
            paragraph.append(line)
        }
        flushParagraph()
        return blocks
    }

    private static func imageLink(_ line: String) -> (alt: String, link: String)? {
        guard line.hasPrefix("!["), line.hasSuffix(")"), let close = line.range(of: "](") else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
        let link = String(line[close.upperBound..<line.index(before: line.endIndex)])
        return link.contains(" ") ? nil : (alt, link)
    }

    private static func bulletItem(_ line: String) -> (marker: String, text: String)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) { return ("•", String(line.dropFirst(2))) }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") { return (digits + ".", String(line.dropFirst(digits.count + 2))) }
        return nil
    }
}

struct MarkdownPreview: View {
    @EnvironmentObject var notes: NotesStore
    let note: NoteDocument

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(PreviewBlock.parse(note)) { block in
                    switch block {
                    case .heading(let level, let text, _):
                        inline(text).font(.system(size: level == 1 ? 22 : level == 2 ? 18 : 15, weight: .semibold)).padding(.top, 4)
                    case .paragraph(let text, _):
                        inline(text).fixedSize(horizontal: false, vertical: true)
                    case .bullet(let marker, let text, _):
                        HStack(alignment: .firstTextBaseline, spacing: 8) { Text(marker).foregroundStyle(.secondary); inline(text) }
                    case .code(let snippet):
                        CodeBlockView(snippet: snippet)
                    case .image(let alt, let link, _):
                        if let image = notes.attachmentImage(link: link) {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 640, maxHeight: 480, alignment: .leading)
                                .clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityLabel(alt.isEmpty ? L("笔记图片") : alt)
                        } else {
                            Label(L("图片不可显示（仅显示笔记库内的附件）"), systemImage: "photo.badge.exclamationmark")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    case .rule:
                        Divider()
                    }
                }
            }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }.background(Color(nsColor: .textBackgroundColor))
    }
}

struct CodeBlockView: View {
    @EnvironmentObject var notes: NotesStore
    let snippet: NoteSnippet
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(snippet.language.isEmpty ? (snippet.isCommand ? L("命令") : L("代码")) : snippet.language)
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                CopyButton(snippet: snippet)
            }.padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            ScrollView(.horizontal) {
                Text(snippet.code.isEmpty ? " " : snippet.code).font(.system(size: 12.5, design: .monospaced))
                    .fixedSize().padding(10)
            }
        }
        .background(AtlasStyle.raised)
        .clipShape(RoundedRectangle(cornerRadius: AtlasStyle.radius))
        .overlay(RoundedRectangle(cornerRadius: AtlasStyle.radius).stroke(AtlasStyle.border))
    }
}

struct CopyButton: View {
    @EnvironmentObject var notes: NotesStore
    let snippet: NoteSnippet
    var body: some View {
        let copied = notes.copiedSnippetID == snippet.id
        Button { notes.copy(snippet) } label: {
            Label(copied ? L("已复制") : L("复制"), systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption).foregroundStyle(copied ? Color.green : Color.accentColor)
        }.buttonStyle(.borderless).help(L("复制到剪贴板，由你自行粘贴执行")).disabled(snippet.code.isEmpty)
    }
}
