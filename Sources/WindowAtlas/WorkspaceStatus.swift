import AppKit
import SwiftUI

struct ActivityObservation {
    var signature: [UInt8]?
    var started: Date?
    var sampled: Date?
    var lastChange: Date?
    mutating func observe(_ next: [UInt8], at date: Date) {
        // A gap starts a new observation interval; never infer idle across unobserved time.
        if sampled == nil || date.timeIntervalSince(sampled!) > 30 { started = date; lastChange = nil; signature = nil }
        if let previous = signature, previous.count == next.count, !next.isEmpty {
            let changes = zip(previous, next).filter { abs(Int($0) - Int($1)) > 20 }.count
            if Double(changes) / Double(next.count) > 0.008 { lastChange = date }
        }
        signature = next; sampled = date
    }
    func label(at now: Date) -> String {
        guard let sampled, now.timeIntervalSince(sampled) <= 30 else { return L("未在观察") }
        if let lastChange, now.timeIntervalSince(lastChange) <= 20 { return L("近期变化") }
        let unchanged = now.timeIntervalSince(lastChange ?? started ?? now)
        return unchanged >= 300 ? L("长时无变化") : L("观察中 · 暂无变化")
    }
}

func activitySignature(_ image: CGImage) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: 96 * 64)
    let success = bytes.withUnsafeMutableBytes { data -> Bool in
        guard let context = CGContext(data: data.baseAddress, width: 96, height: 64, bitsPerComponent: 8,
            bytesPerRow: 96, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 64))
        return true
    }
    return success ? bytes : nil
}

/// 缩小到 16×10 检查透明度：全部像素透明即视为没有拍到窗口内容。
func isBlankCapture(_ image: CGImage) -> Bool {
    let width = 16, height = 10
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return false }
    return stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 0 }
}

struct ActivityBadge: View {
    @EnvironmentObject var store: WindowStore
    let item: WindowItem
    var compact = false
    var body: some View { ActivityBadgeContent(item: item, compact: compact, preview: store.preview(item.id)) }
}

/// 观察单个窗口的内容变化，状态更新只重绘这一枚徽标。
private struct ActivityBadgeContent: View {
    @EnvironmentObject var store: WindowStore
    let item: WindowItem
    let compact: Bool
    @ObservedObject var preview: WindowPreview
    var body: some View {
        TimelineView(.periodic(from: .now, by: 6)) { context in
            let task = store.terminalStatus(item)
            let fresh = task?.isFresh(at: context.date) == true
            let label = item.isTerminal
                ? (task?.title(at: context.date) ?? (store.terminalErrors[item.appID] != nil ? L("需授权读取任务") : TerminalTaskBridge.supported.contains(item.appID) ? L("未读取任务状态") : L("暂不支持任务检测")))
                : (item.isOnScreen ? (preview.activity?.label(at: context.date) ?? L("等待观察")) : item.onOtherSpace ? L("在其他桌面") : L("未在屏幕显示"))
            let color: Color = item.isTerminal
                ? (fresh && task?.kind.isRunning == true ? .green : fresh && task?.kind == .idle ? .orange : .secondary)
                : (label == L("近期变化") ? .green : label == L("长时无变化") ? .orange : .secondary)
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }.padding(.horizontal, compact ? 0 : 8).padding(.vertical, compact ? 0 : 5)
                // 不用毛玻璃：每张卡片实时模糊在滚动时开销很大，改用接近不透明的底色。
                .background(compact ? Color.clear : AtlasStyle.surface.opacity(0.94), in: Capsule())
                .overlay(Capsule().strokeBorder(compact ? Color.clear : color.opacity(0.16)))
                .help(item.isTerminal ? (task?.detail ?? L("在任务状态菜单启用读取。终端任务检测不依赖窗口是否显示在屏幕上，不读取终端内容。")) : L("只记录可见预览的内容变化；不代表任务停止或网页离线。"))
                .accessibilityLabel((item.isTerminal ? L("终端任务状态：") : L("窗口内容状态：")) + label)
        }
    }
}

struct WorkspaceSearch: View {
    @EnvironmentObject var store: WindowStore
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            // 窗口和标签页用同一个提示与匹配规则：标题、应用名、网址或路径都能搜。
            TextField(L("搜索窗口、标签、应用或路径"), text: $store.query)
                .textFieldStyle(.plain).focused($focused)
            if !store.query.isEmpty {
                Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L("清除搜索"))
                    .accessibilityLabel(L("清除搜索"))
            }
            Divider().frame(height: 18)
            Picker(L("搜索范围"), selection: $store.searchAll) {
                Text(L("当前栏目")).tag(false)
                Text(L("全部应用窗口")).tag(true)
            }.labelsHidden().fixedSize()
        }.padding(.horizontal, 12).frame(height: 38)
            .background(AtlasStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? AtlasStyle.accent.opacity(0.65) : AtlasStyle.border))
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("WindowAtlas.focusSearch"))) { _ in focused = true }
    }
}


struct TerminalTaskControls: View {
    @EnvironmentObject var store: WindowStore
    var body: some View {
        if store.selection == "terminals" || store.windows.contains(where: { $0.appID == store.selection && $0.isTerminal }) || store.selection == "all" {
            HStack(spacing: 8) {
                Menu {
                    ForEach(TerminalTaskBridge.supported, id: \.self) { appID in
                        let name = appID == "com.apple.Terminal" ? "Terminal" : "iTerm2"
                        if store.terminalEnabled.contains(appID) {
                            Button(L("停止读取 %@", name)) { store.disableTerminalTasks(appID) }
                        } else {
                            Button(L("读取 %@ 任务状态", name)) { store.enableTerminalTasks(appID) }
                        }
                        if let error = store.terminalErrors[appID] { Text(name + "：" + error) }
                    }
                    Divider()
                    Button(L("自动化权限设置")) { store.openPrivacy("Privacy_Automation") }
                } label: { Label(L("任务状态"), systemImage: "waveform.path.ecg") }
                Toggle(L("只看有任务"), isOn: $store.taskOnly).toggleStyle(.button)
                    .help(L("显示有命令或 AI 会话运行的终端；不等于 AI 当前正在生成"))
            }.controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}
