// Manual UI regression fixture. This app contains no user tasks or documents.
import AppKit

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var timer: Timer?
    var count = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let root = NSMenu(); let item = NSMenuItem(); let app = NSMenu()
        app.addItem(withTitle: "退出测试窗口", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app; root.addItem(item); NSApp.mainMenu = root
        let dynamic = makeWindow(title: "WindowAtlas QA · 动态标题 0", frame: CGRect(x: 450, y: 200, width: 620, height: 380))
        let modal = makeWindow(title: "WindowAtlas QA · 对话框父窗口", frame: CGRect(x: 600, y: 250, width: 560, height: 340))
        let alert = NSAlert()
        alert.messageText = "WindowAtlas QA · 测试对话框"
        alert.informativeText = "这是安全的附属对话框，用于验证缩略图定位。不包含正在运行的终端任务。"
        alert.addButton(withTitle: "仅关闭测试对话框")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: modal) { _ in }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self, weak dynamic] _ in
            guard let self else { return }; self.count += 1
            dynamic?.title = "WindowAtlas QA · 动态标题 \(self.count)"
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func makeWindow(title: String, frame: CGRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        let label = NSTextField(wrappingLabelWithString: "WindowAtlas QA\n\n可安全移动、最小化和关闭的测试窗口。\n不包含用户会话或文档。")
        label.font = .systemFont(ofSize: 20); label.frame = CGRect(x: 30, y: 50, width: 480, height: 200)
        window.contentView?.addSubview(label)
        window.makeKeyAndOrderFront(nil); windows.append(window); return window
    }
}

@main struct FixtureMain {
    static func main() {
        let app = NSApplication.shared; let delegate = FixtureDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
