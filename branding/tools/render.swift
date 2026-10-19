import AppKit
import WebKit

// 用法：render <svg> <out.png> <宽像素> [<高像素>] [<svg> <out.png> <宽> <高> ...]
// 用 WebKit 完整支持 SVG 渐变、滤镜与文字，按精确像素输出透明 PNG。
struct Job { let svg: URL; let out: URL; let width: Int; let height: Int }

var jobs: [Job] = []
var args = Array(CommandLine.arguments.dropFirst())
while args.count >= 4 {
    jobs.append(Job(svg: URL(fileURLWithPath: args[0]), out: URL(fileURLWithPath: args[1]), width: Int(args[2])!, height: Int(args[3])!))
    args.removeFirst(4)
}

final class Renderer: NSObject, WKNavigationDelegate {
    var queue: [Job]
    let web: WKWebView
    init(_ jobs: [Job]) {
        queue = jobs
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        super.init()
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
    }
    func next() {
        guard let job = queue.first else { exit(0) }
        // 以 1:1 点尺寸布局，再按目标像素重采样，避免屏幕缩放倍率影响输出尺寸。
        let layout = CGFloat(max(job.width, job.height)) >= 512 ? 1.0 : 512.0 / CGFloat(max(job.width, job.height))
        let w = CGFloat(job.width) * layout, h = CGFloat(job.height) * layout
        web.frame = NSRect(x: 0, y: 0, width: w, height: h)
        // 读不到源文件时立即失败，避免静默输出空白图片。
        guard let svg = try? String(contentsOf: job.svg, encoding: .utf8), svg.contains("<svg") else {
            FileHandle.standardError.write("无法读取 SVG：\(job.svg.path)\n".data(using: .utf8)!)
            exit(1)
        }
        let html = "<html><head><style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}svg{display:block;width:\(Int(w))px;height:\(Int(h))px}</style></head><body>\(svg)</body></html>"
        web.loadHTMLString(html, baseURL: job.svg.deletingLastPathComponent())
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.snapshot() }
    }
    func snapshot() {
        let job = queue.removeFirst()
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        web.takeSnapshot(with: config) { image, error in
            guard let image else { FileHandle.standardError.write("失败 \(job.out.lastPathComponent): \(String(describing: error))\n".data(using: .utf8)!); exit(1) }
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: job.width, pixelsHigh: job.height, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: job.width, height: job.height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: job.width, height: job.height), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            try? FileManager.default.createDirectory(at: job.out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! rep.representation(using: .png, properties: [:])!.write(to: job.out)
            print("✓ \(job.out.lastPathComponent) \(job.width)×\(job.height)")
            self.next()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = Renderer(jobs)
renderer.next()
app.run()
