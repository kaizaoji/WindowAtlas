import AppKit
import SwiftUI

struct WorkspaceHeader: View {
    @EnvironmentObject var store: WindowStore
    private var title: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(store.heading).font(.system(size: 26, weight: .bold, design: .rounded)).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 6)) { context in
                    let count = store.windows.filter { item in
                        guard let status = store.terminalStatuses[item.id] else { return false }
                        return status.isFresh(at: context.date) && status.kind == .agent
                    }.count
                    if count > 0 {
                        Label(L("AI 会话窗口 %d", count), systemImage: "sparkles")
                            .font(.system(size: 10, weight: .semibold)).lineLimit(1)
                            .foregroundStyle(AtlasStyle.accent)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(AtlasStyle.accent.opacity(0.1), in: Capsule())
                            .help(L("仅统计近期检测到 AI 会话进程的窗口，不代表 AI 正在生成。"))
                    }
                }
            }
            Text(L(store.showingTabs ? "%d 个标签页 · 每个应用独立记住视图" : "%d 个窗口 · 每个应用独立记住视图", store.displayCount))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(minWidth: 150, alignment: .leading)
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                title
                Spacer(minLength: 12)
                WorkspaceSearch().frame(width: 340)
            }
            VStack(alignment: .leading, spacing: 12) {
                title
                WorkspaceSearch()
            }
        }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
    }
}

struct DesktopOrganizationSettings: View {
    @State private var minimizeIntoIcon = false
    private func refresh() {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        minimizeIntoIcon = (CFPreferencesCopyAppValue("minimize-to-application" as CFString, "com.apple.dock" as CFString) as? NSNumber)?.boolValue == true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L("桌面整理设置"), systemImage: "dock.rectangle").font(.headline)
            Text(L("收起 Dock 中的窗口缩略图")).font(.subheadline.weight(.semibold))
            HStack {
                Circle().fill(minimizeIntoIcon ? .green : .secondary).frame(width: 7, height: 7)
                Text(minimizeIntoIcon ? L("已最小化至应用图标") : L("最小化窗口单独显示")).font(.callout)
            }
            Text(L("在系统设置中开启“将窗口最小化至应用程序图标”，最小化窗口就会收进各自的应用图标。此选项对整台电脑的应用生效。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(L("打开桌面与程序坞设置")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") { NSWorkspace.shared.open(url) }
            }.buttonStyle(.borderedProminent)
            Text(L("窗口仍可从工作台切换；如有旧缩略图残留，可在需要时恢复窗口后再次最小化。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 340).onAppear { refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }
}
