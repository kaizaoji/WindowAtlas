import Foundation

// 用法：ico <输出.ico> <16.png> <32.png> ...
// 把多张 PNG 打包成 .ico（条目内直接存 PNG，Windows Vista 及以后均支持）。尺寸从 PNG 头读取。
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { print("用法：ico <输出.ico> <png>..."); exit(1) }
let images = try args.dropFirst().map { try Data(contentsOf: URL(fileURLWithPath: $0)) }

func le16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
func le32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
func pngSize(_ data: Data) -> (Int, Int) {
    let bytes = [UInt8](data.prefix(24))
    precondition(bytes.count == 24 && bytes[1] == 0x50, "不是 PNG 文件")
    let width = Int(bytes[16]) << 24 | Int(bytes[17]) << 16 | Int(bytes[18]) << 8 | Int(bytes[19])
    let height = Int(bytes[20]) << 24 | Int(bytes[21]) << 16 | Int(bytes[22]) << 8 | Int(bytes[23])
    return (width, height)
}

var header = le16(0) + le16(1) + le16(images.count)
var payload = Data()
var offset = 6 + 16 * images.count
for image in images {
    let (width, height) = pngSize(image)
    precondition(width <= 256 && height <= 256, "ICO 单张最大 256 像素")
    // 宽高字节为 0 表示 256。
    header += Data([UInt8(width == 256 ? 0 : width), UInt8(height == 256 ? 0 : height), 0, 0])
    header += le16(1) + le16(32) + le32(image.count) + le32(offset)
    payload += image
    offset += image.count
}
try (header + payload).write(to: URL(fileURLWithPath: args[0]))
print("✓ \((args[0] as NSString).lastPathComponent) \(images.count) 种尺寸")
