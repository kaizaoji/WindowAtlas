import AppKit
import PDFKit

/// 把常用文档转换为笔记：Markdown/文本原样保留，配置与代码包成代码块，富文本与 PDF 提取纯文本。
/// 全部使用系统能力离线完成；HTML 不经 WebKit 渲染，避免加载远程资源。
enum NoteImporter {
    static let maxBytes = 5 * 1024 * 1024
    static let maxFiles = 2000

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt", "text"]
    static let codeLanguages: [String: String] = [
        "json": "json", "jsonc": "json", "yaml": "yaml", "yml": "yaml", "toml": "toml", "xml": "xml", "plist": "xml",
        "sh": "sh", "bash": "bash", "zsh": "zsh", "fish": "fish", "ps1": "powershell", "bat": "bat", "cmd": "bat",
        "py": "python", "js": "javascript", "mjs": "javascript", "cjs": "javascript", "ts": "typescript", "tsx": "tsx", "jsx": "jsx",
        "swift": "swift", "go": "go", "rs": "rust", "rb": "ruby", "java": "java", "kt": "kotlin", "c": "c", "h": "c",
        "cpp": "cpp", "hpp": "cpp", "cs": "csharp", "php": "php", "lua": "lua", "sql": "sql", "css": "css", "scss": "scss",
        "vue": "vue", "ini": "ini", "conf": "conf", "cfg": "ini", "env": "sh", "properties": "properties", "gradle": "groovy",
        "csv": "csv", "log": "text", "dockerfile": "dockerfile", "makefile": "makefile"
    ]
    static let fileNameLanguages: [String: String] = [
        "dockerfile": "dockerfile", "makefile": "makefile", ".env": "sh", ".zshrc": "zsh", ".bashrc": "bash", ".gitignore": "text"
    ]
    static let richExtensions: Set<String> = ["rtf", "rtfd", "doc", "docx", "odt"]
    static let htmlExtensions: Set<String> = ["html", "htm"]

    enum ImportError: LocalizedError, Equatable {
        case unsupported, tooLarge, unreadable
        var errorDescription: String? {
            switch self {
            case .unsupported: return L("不支持的文件类型")
            case .tooLarge: return L("文件超过 5 MB")
            case .unreadable: return L("无法读取文件内容")
            }
        }
    }

    static func language(for url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        return fileNameLanguages[name] ?? codeLanguages[url.pathExtension.lowercased()]
    }

    /// 只有 Markdown / 纯文本需要处理本地图片链接；代码文件按原文保存。
    static func isMarkdown(_ url: URL) -> Bool { markdownExtensions.contains(url.pathExtension.lowercased()) }

    /// RTFD 在磁盘上是文件夹形式的文档包，导入时视为单个文档，不按普通文件夹展开。
    static func isDocumentPackage(_ url: URL) -> Bool { url.pathExtension.lowercased() == "rtfd" }

    static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return markdownExtensions.contains(ext) || language(for: url) != nil || richExtensions.contains(ext)
            || htmlExtensions.contains(ext) || ext == "pdf"
    }

    /// 返回笔记标题与正文。Markdown 带本应用头部时沿用其标题、收藏和敏感标记（ID 由调用方重新分配）。
    static func convert(_ url: URL) throws -> NoteDocument {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isDirectoryKey])
        if isDocumentPackage(url) {
            guard values?.isDirectory == true || values?.isRegularFile == true else { throw ImportError.unreadable }
            guard packageSize(url) <= maxBytes else { throw ImportError.tooLarge }
        } else {
            guard values?.isRegularFile == true else { throw ImportError.unreadable }
            guard (values?.fileSize ?? 0) <= maxBytes else { throw ImportError.tooLarge }
        }
        let ext = url.pathExtension.lowercased()
        let fileTitle = url.deletingPathExtension().lastPathComponent.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let now = Date()
        func make(_ title: String, _ body: String) -> NoteDocument {
            NoteDocument(id: UUID().uuidString, title: title, body: body, created: now, updated: now)
        }
        if markdownExtensions.contains(ext) {
            let text = try readText(url)
            if var existing = NoteFormat.decode(text) {
                existing.id = UUID().uuidString
                existing.archived = false
                return existing
            }
            return make(firstHeading(text) ?? fileTitle, text)
        }
        if let language = language(for: url) {
            let code = try readText(url)
            let fence = fenceFor(code)
            return make(url.lastPathComponent, "来源：\(url.lastPathComponent)\n\n\(fence)\(language)\n\(code.hasSuffix("\n") ? String(code.dropLast()) : code)\n\(fence)\n")
        }
        if htmlExtensions.contains(ext) {
            let html = try readText(url)
            return make(htmlTitle(html) ?? fileTitle, htmlToText(html))
        }
        if richExtensions.contains(ext) {
            guard let text = try? NSAttributedString(url: url, options: [:], documentAttributes: nil).string else { throw ImportError.unreadable }
            return make(fileTitle, text)
        }
        if ext == "pdf" {
            guard let text = PDFDocument(url: url)?.string, !text.isEmpty else { throw ImportError.unreadable }
            return make(fileTitle, text)
        }
        throw ImportError.unsupported
    }

    private static func packageSize(_ url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return enumerator.reduce(0) { total, item in total + (((item as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]) })?.fileSize ?? 0) }
    }

    private static func readText(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url), let text = decodeText(data) else { throw ImportError.unreadable }
        return text
    }

    /// 文本编码识别顺序：BOM → 无 BOM UTF-16（空字节分布）→ UTF-8 → 看起来像中英文的 UTF-16LE → GB18030。
    /// UTF-16LE 的英文部分在 UTF-8 下也「合法」但带空字符，因此必须先于 UTF-8 判断。
    static func decodeText(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if bytes.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if bytes.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        if bytes.count >= 2, bytes.count % 2 == 0 {
            let sample = bytes.prefix(4096)
            let pairs = max(1, sample.count / 2)
            let oddZeros = stride(from: 1, to: sample.count, by: 2).filter { sample[sample.startIndex + $0] == 0 }.count
            let evenZeros = stride(from: 0, to: sample.count, by: 2).filter { sample[sample.startIndex + $0] == 0 }.count
            if Double(oddZeros) / Double(pairs) > 0.2, evenZeros == 0, let text = String(data: data, encoding: .utf16LittleEndian) { return text }
            if Double(evenZeros) / Double(pairs) > 0.2, oddZeros == 0, let text = String(data: data, encoding: .utf16BigEndian) { return text }
        }
        if let text = String(data: data, encoding: .utf8), !text.contains("\0") { return text }
        if bytes.count % 2 == 0, let text = String(data: data, encoding: .utf16LittleEndian), looksLikeText(text) { return text }
        // 兼容 GBK 等旧编码的中文文本。
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = String(data: data, encoding: gb18030), !text.contains("\0") { return text }
        return nil
    }

    /// 绝大部分字符属于常见中英文范围时才认为解码正确，避免把其他编码误读成乱码。
    private static func looksLikeText(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return false }
        let common = scalars.filter { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0D, 0x20...0x7E, 0x3000...0x303F, 0x4E00...0x9FFF, 0xFF00...0xFFEF: return true
            default: return false
            }
        }.count
        return Double(common) / Double(scalars.count) >= 0.9
    }

    static func firstHeading(_ text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(40) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") { return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// 代码本身含 ``` 时使用更长的围栏，保证复制内容完整。
    static func fenceFor(_ code: String) -> String {
        var longest = 0, current = 0
        for character in code { current = character == "`" ? current + 1 : 0; longest = max(longest, current) }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    private static func htmlTitle(_ html: String) -> String? {
        guard let range = html.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let title = decodeEntities(html[range].replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// 简单离线转换：去掉脚本样式，<pre> 转代码块，块级标签换行，其余标签移除并解码常见实体。
    static func htmlToText(_ html: String) -> String {
        var text = html
        func replace(_ pattern: String, _ template: String) {
            text = text.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        replace(#"<(script|style|head)[^>]*>[\s\S]*?</\1>"#, "")
        // <pre> 先整体取出用占位符替换，正文整理（去行首尾空白）不能碰预格式化代码的缩进。
        var preBlocks: [String] = []
        if let regex = try? NSRegularExpression(pattern: #"<pre[^>]*>([\s\S]*?)</pre>"#, options: [.caseInsensitive]) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let whole = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: text) else { continue }
                var code = decodeEntities(text[inner].replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
                if code.hasPrefix("\n") { code.removeFirst() }
                if code.hasSuffix("\n") { code.removeLast() }
                preBlocks.insert(code, at: 0)
                text.replaceSubrange(whole, with: "\n\u{1}PRE\u{1}\n")
            }
        }
        replace(#"<br\s*/?>"#, "\n")
        replace(#"<h([1-6])[^>]*>"#, "\n## ")
        replace(#"<li[^>]*>"#, "\n- ")
        replace(#"</(p|div|h[1-6]|li|tr|ul|ol|table|section|article)>"#, "\n")
        replace(#"<[^>]+>"#, "")
        var blocks = preBlocks.makeIterator()
        return decodeEntities(text).split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed == "\u{1}PRE\u{1}", let code = blocks.next() else { return trimmed }
            let fence = fenceFor(code)
            return "\(fence)\n\(code)\n\(fence)"
        }.joined(separator: "\n")
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        if let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let whole = Range(match.range, in: result), let digits = Range(match.range(at: 2), in: result) else { continue }
                let hex = Range(match.range(at: 1), in: result).map { !result[$0].isEmpty } ?? false
                if let code = UInt32(result[digits], radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    result.replaceSubrange(whole, with: String(Character(scalar)))
                }
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Markdown 中引用的本地相对路径图片导入为附件并改写链接；网络图片、绝对路径和非图片保持原样。
    static func rewriteLocalImages(in body: String, baseDirectory: URL, depth: Int, importer: (Data) throws -> String) -> (body: String, imported: Int) {
        guard let regex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(<?([^)<>\s]+)>?\)"#) else { return (body, 0) }
        var result = body
        var imported = 0
        let protected = codeRanges(in: body)
        for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).reversed() {
            // 代码围栏与行内代码里的 ![](…) 是代码文本，必须原样保留。
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            guard let whole = Range(match.range, in: body), let altRange = Range(match.range(at: 1), in: body),
                  let linkRange = Range(match.range(at: 2), in: body) else { continue }
            let link = String(body[linkRange])
            let lower = link.lowercased()
            guard !lower.contains("://"), !lower.hasPrefix("data:"), !link.hasPrefix("/"), !link.hasPrefix("~"),
                  NoteAttachments.validatedName(fromLink: link) == nil else { continue }
            let decoded = link.removingPercentEncoding ?? link
            let file = baseDirectory.appendingPathComponent(decoded).standardizedFileURL
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true, (values?.fileSize ?? .max) <= NoteAttachments.maxBytes,
                  let data = try? Data(contentsOf: file), let name = try? importer(data) else { continue }
            let replacement = "![\(body[altRange])](\(NoteAttachments.linkPrefix(depth: depth))\(name))"
            guard let target = Range(NSRange(whole, in: body), in: result) else { continue }
            result.replaceSubrange(target, with: replacement)
            imported += 1
        }
        return (result, imported)
    }
}

extension NoteImporter {
    /// 围栏代码块（与 NoteSnippets 相同的开闭规则，未闭合则到文末）及其余行内 `…` 代码的范围。
    static func codeRanges(in body: String) -> [NSRange] {
        let text = body as NSString
        var ranges: [NSRange] = []
        var location = 0
        var fence: (marker: String, start: Int)?
        var outside: [NSRange] = []
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let trimmed = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if let open = fence {
                if NoteSnippets.closesFence(trimmed, marker: open.marker) {
                    ranges.append(NSRange(location: open.start, length: NSMaxRange(line) - open.start)); fence = nil
                }
            } else if let marker = NoteSnippets.fenceMarker(trimmed) {
                fence = (marker, line.location)
            } else {
                outside.append(line)
            }
            location = NSMaxRange(line)
        }
        if let open = fence { ranges.append(NSRange(location: open.start, length: text.length - open.start)) }
        if let inline = try? NSRegularExpression(pattern: "(`+)[^`\\n]*?\\1") {
            for line in outside { ranges += inline.matches(in: body, range: line).map(\.range) }
        }
        return ranges
    }
}

extension NotesLibrary {
    /// 导入文件夹时按原结构建目录：逐级清洗名称，已存在则直接使用。
    func ensureFolder(_ path: String) throws {
        guard !readOnly else { throw LibraryError.readOnly }
        guard path.isEmpty || Self.isSafeRelativePath(path) else { throw LibraryError.invalidLocation }
        try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
    }
}

extension NotesStore {
    func chooseDocumentsToImport(into container: String? = nil) {
        let target = container ?? currentContainer
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = L("导入")
        panel.message = String(format: L("导入到「%@」。支持 Markdown、文本、JSON/YAML 等配置与代码、Word/RTF、HTML、PDF；选择文件夹会按原目录结构导入。"), String(describing: breadcrumb(target)))
        guard panel.runModal() == .OK else { return }
        importDocuments(panel.urls, into: target)
    }

    /// 转换在后台进行，写入在主线程；只新建笔记，不修改或删除任何已有笔记和原文件。
    func importDocuments(_ urls: [URL], into container: String) {
        guard let library else { return }
        guard !readOnly else { message = NotesLibrary.LibraryError.readOnly.localizedDescription; return }
        guard flush() else { return }
        var jobs: [(file: URL, container: String)] = []
        var folders: [String] = []
        var skipped = 0
        let fileManager = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { skipped += 1; continue }
            guard isDirectory.boolValue, !NoteImporter.isDocumentPackage(url) else {
                if NoteImporter.isSupported(url) { jobs.append((url, container)) } else { skipped += 1 }
                continue
            }
            guard let top = try? library.createFolder(named: url.lastPathComponent, in: container) else { skipped += 1; continue }
            let base = url.resolvingSymlinksInPath().standardizedFileURL.path
            let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let item = enumerator?.nextObject() as? URL, jobs.count < NoteImporter.maxFiles {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                let full = item.resolvingSymlinksInPath().standardizedFileURL.path
                guard full.hasPrefix(base + "/") else { continue }
                let parts = full.dropFirst(base.count + 1).split(separator: "/").map { NoteFormat.sanitizedName(String($0), fallback: "未命名") }
                if values?.isDirectory == true, !NoteImporter.isDocumentPackage(item) {
                    folders.append(([top] + parts).joined(separator: "/"))
                } else if NoteImporter.isSupported(item) {
                    jobs.append((item, ([top] + parts.dropLast()).joined(separator: "/")))
                } else {
                    skipped += 1
                }
            }
        }
        message = String(format: L("正在导入 %@ 个文件…"), String(describing: jobs.count))
        Task {
            let converted = await Task.detached { jobs.map { job in (job, Result { try NoteImporter.convert(job.file) }) } }.value
            // 转换期间仍可编辑当前笔记；保存失败时必须保留内存编辑并停止导入。
            guard flush() else { return }
            var created: [String] = []
            var failed = 0, images = 0
            for folder in folders { try? library.ensureFolder(folder) }
            for (job, result) in converted {
                guard case .success(var note) = result else { failed += 1; continue }
                let depth = NotesLibrary.depth(of: job.container)
                let rewritten = NoteImporter.isMarkdown(job.file)
                    ? NoteImporter.rewriteLocalImages(in: note.body, baseDirectory: job.file.deletingLastPathComponent(), depth: depth) {
                        try library.importAttachment($0)
                    }
                    : (body: note.body, imported: 0)
                note.body = rewritten.body
                images += rewritten.imported
                do {
                    try library.ensureFolder(job.container)
                    _ = try library.save(note, previousPath: nil, expectedModified: nil, container: job.container)
                    created.append(note.id)
                } catch {
                    failed += 1
                }
            }
            reload()
            if let first = created.first { query = ""; filter = .active; select(first) }
            var summary = String(format: L("已导入 %@ 篇笔记"), String(describing: created.count))
            if images > 0 { summary += String(format: L("、%@ 张图片"), String(describing: images)) }
            if skipped + failed > 0 { summary += String(format: L("；跳过 %@ 个不支持、过大或无法读取的文件"), String(describing: skipped + failed)) }
            message = summary + "。"
        }
    }
}
