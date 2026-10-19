import AppKit
import CryptoKit

/// 一篇笔记即一个 Markdown 文件；命令和代码就是正文里的围栏代码块。
struct NoteDocument: Identifiable, Equatable {
    var id: String
    var title: String
    var body: String
    var favorite = false
    var sensitive = false
    var archived = false
    var created: Date
    var updated: Date
}

struct NoteSnippet: Identifiable, Equatable {
    let noteID: String
    let index: Int
    let language: String
    let label: String
    let code: String
    var id: String { "\(noteID)#\(index)" }
    var isCommand: Bool { NoteSnippet.commandLanguages.contains(language.lowercased()) }
    static let commandLanguages: Set<String> = ["", "sh", "bash", "zsh", "shell", "console", "fish", "powershell", "ps1", "cmd", "terminal"]
}

enum NoteFormat {
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func encode(_ note: NoteDocument) -> String {
        // 字符串统一用 JSON 引号转义，既是合法 YAML，又能安全容纳冒号、引号与换行。
        func quoted(_ value: String) -> String {
            let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
            return String(decoding: data, as: UTF8.self)
        }
        return """
        ---
        id: \(quoted(note.id))
        title: \(quoted(note.title))
        favorite: \(note.favorite)
        sensitive: \(note.sensitive)
        archived: \(note.archived)
        created: \(dateFormatter.string(from: note.created))
        updated: \(dateFormatter.string(from: note.updated))
        ---


        """ + note.body
    }

    /// 头部缺失或损坏时返回 nil，由调用方把整个文件当正文处理，避免误删用户内容。
    static func decode(_ text: String) -> NoteDocument? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return nil }
        let rest = normalized.dropFirst(4)
        guard let end = rest.range(of: "\n---\n") ?? (rest.hasSuffix("\n---") ? rest.range(of: "\n---", options: .backwards) : nil) else { return nil }
        var fields: [String: String] = [:]
        for line in rest[rest.startIndex..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        func string(_ key: String) -> String? {
            guard let raw = fields[key] else { return nil }
            if raw.hasPrefix("\"") { return try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) }
            return raw
        }
        func bool(_ key: String) -> Bool { fields[key] == "true" }
        guard let id = string("id"), !id.isEmpty else { return nil }
        var body = String(rest[end.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }
        let now = Date()
        return NoteDocument(id: id, title: string("title") ?? "未命名笔记", body: body,
            favorite: bool("favorite"), sensitive: bool("sensitive"), archived: bool("archived"),
            created: fields["created"].flatMap(dateFormatter.date(from:)) ?? now,
            updated: fields["updated"].flatMap(dateFormatter.date(from:)) ?? now)
    }

    /// 文件名可读、可在云盘中直接辨认；短 ID 保证同名笔记不冲突。
    static func fileName(title: String, id: String) -> String {
        let cleaned = sanitizedName(title, fallback: "未命名笔记")
        let shortID = String(id.filter { $0.isLetter || $0.isNumber }.prefix(8))
        return "\(cleaned)-\(shortID.isEmpty ? "note" : shortID).md"
    }

    /// 文件名 / 目录名清洗：去掉路径分隔符与控制字符，去掉首尾点号防止隐藏项与 ..，限制长度。
    static func sanitizedName(_ name: String, fallback: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let cleaned = name.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(60))
    }
}

enum NoteSnippets {
    /// 解析 ``` 与 ~~~ 围栏；代码原样保留，只去掉围栏行本身。未闭合的围栏仍收录到文末。
    static func extract(from note: NoteDocument) -> [NoteSnippet] {
        let lines = note.body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [NoteSnippet] = []
        var fence: (marker: String, language: String, label: String)?
        var buffer: [String] = []
        var previousText = ""
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if closesFence(trimmed, marker: open.marker) {
                    result.append(NoteSnippet(noteID: note.id, index: result.count, language: open.language, label: open.label, code: buffer.joined(separator: "\n")))
                    fence = nil; buffer = []
                } else {
                    buffer.append(line)
                }
                continue
            }
            if let marker = fenceMarker(trimmed) {
                let language = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
                fence = (marker, language, previousText.isEmpty ? note.title : previousText)
                previousText = ""
            } else if !trimmed.isEmpty {
                previousText = labelText(trimmed)
            }
        }
        if let open = fence {
            result.append(NoteSnippet(noteID: note.id, index: result.count, language: open.language, label: open.label, code: buffer.joined(separator: "\n")))
        }
        return result
    }

    /// 闭合围栏须使用相同字符、长度不短于开头，且其后没有其他内容。
    static func closesFence(_ trimmed: String, marker: String) -> Bool {
        guard let character = marker.first, trimmed.hasPrefix(marker) else { return false }
        return trimmed.drop(while: { $0 == character }).trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func fenceMarker(_ trimmed: String) -> String? {
        for character in ["`", "~"] {
            let count = trimmed.prefix(while: { String($0) == character }).count
            if count >= 3 { return String(repeating: character, count: count) }
        }
        return nil
    }

    private static func labelText(_ line: String) -> String {
        var text = line
        while let first = text.first, "#>-*+".contains(first) { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("：") || text.hasSuffix(":") { text.removeLast() }
        return String(text.prefix(80))
    }
}

enum SecretScanner {
    private static let patterns: [(name: String, regex: NSRegularExpression)] = [
        ("Anthropic / OpenAI 密钥", #"\bsk-(ant-)?[A-Za-z0-9_\-]{20,}"#),
        ("GitHub Token", #"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{30,}"#),
        ("AWS 访问密钥", #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#),
        ("Slack Token", #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#),
        ("Google API 密钥", #"\bAIza[0-9A-Za-z_\-]{35}"#),
        ("私钥", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        ("密码 / Token 赋值", #"(?i)\b[A-Z0-9_]*(api[_-]?key|token|secret|passw(or)?d)[A-Z0-9_]*\s*[:=]\s*["']?[^\s"'$<>{}]{8,}"#)
    ].compactMap { name, pattern in (try? NSRegularExpression(pattern: pattern)).map { (name, $0) } }

    /// 只返回命中的类型名，不返回密钥原文，避免在界面或日志中再次暴露。
    static func findings(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.filter { $0.regex.firstMatch(in: text, range: range) != nil }.map(\.name)
    }
}

enum NoteAttachments {
    static let maxBytes = 10 * 1024 * 1024
    static let maxPixels = 8000
    static let allowedExtensions: Set<String> = ["png", "jpg", "gif"]

    enum ImportError: LocalizedError {
        case tooLarge, undecodable, tooManyPixels
        var errorDescription: String? {
            switch self {
            case .tooLarge: return L("图片超过 10 MB，未插入。")
            case .undecodable: return L("无法识别的图片格式，未插入。")
            case .tooManyPixels: return L("图片边长超过 8000 像素，未插入。")
            }
        }
    }

    /// 只接受应用自己生成的哈希文件名，防止预览或备份读取任意路径。
    /// 前缀 `../` 的个数随笔记层级变化，只按文件名定位，层级不对也不影响显示。
    static func validatedName(fromLink link: String) -> String? {
        var rest = Substring(link)
        guard rest.hasPrefix("../") else { return nil }
        while rest.hasPrefix("../") { rest = rest.dropFirst(3) }
        guard rest.hasPrefix("attachments/") else { return nil }
        let name = String(rest.dropFirst("attachments/".count))
        return isValidName(name) ? name : nil
    }

    /// 位于容器层级 depth 的笔记引用附件时的相对前缀：notes/ 本身算一层。
    static func linkPrefix(depth: Int) -> String { String(repeating: "../", count: depth + 1) + "attachments/" }

    /// 笔记移动层级后改写图片链接前缀，让其他 Markdown 工具也能正确显示。
    static func normalizeLinks(in text: String, depth: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\]\((?:\.\./)+attachments/([0-9a-f]{64}\.(?:png|jpg|gif))\)"#) else { return text }
        let template = "](" + NSRegularExpression.escapedTemplate(for: linkPrefix(depth: depth)) + "$1)"
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func isValidName(_ name: String) -> Bool {
        let parts = name.split(separator: ".")
        guard parts.count == 2, allowedExtensions.contains(String(parts[1])) else { return false }
        return parts[0].count == 64 && parts[0].allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// PNG/JPEG/GIF 原样保存；其他可解码格式（TIFF、HEIC 等）转 PNG，保证其他 Markdown 工具也能显示。
    static func prepare(_ data: Data) throws -> (name: String, data: Data) {
        guard data.count <= maxBytes else { throw ImportError.tooLarge }
        guard let bitmap = NSBitmapImageRep(data: data) else { throw ImportError.undecodable }
        guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { throw ImportError.undecodable }
        guard bitmap.pixelsWide <= maxPixels, bitmap.pixelsHigh <= maxPixels else { throw ImportError.tooManyPixels }
        let bytes = [UInt8](data.prefix(8))
        let ext: String
        var output = data
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { ext = "png" }
        else if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { ext = "jpg" }
        else if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { ext = "gif" }
        else {
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ImportError.undecodable }
            guard png.count <= maxBytes else { throw ImportError.tooLarge }
            ext = "png"; output = png
        }
        return (sha256(output) + "." + ext, output)
    }

    static func referencedNames(in body: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)\s]+)\)"#) else { return [] }
        let range = NSRange(body.startIndex..., in: body)
        return Set(regex.matches(in: body, range: range).compactMap { match in
            Range(match.range(at: 1), in: body).flatMap { validatedName(fromLink: String(body[$0])) }
        })
    }
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
