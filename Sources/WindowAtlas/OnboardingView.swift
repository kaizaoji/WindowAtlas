import AppKit
import SwiftUI

/// 首次启动 / 未授权时的引导页：逐项说明两项系统授权的用途与状态，给出常见问题的处理方法。
struct PermissionOnboarding: View {
    @EnvironmentObject var store: WindowStore

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 12) {
                    BrandMark(size: 72)
                    Text(L("欢迎使用窗口图鉴")).font(.system(size: 26, weight: .bold))
                    Text(L("完成下面两项系统授权，就能用大缩略图查看并切换所有窗口。窗口预览只在本机内存中处理，不上传、不保存截图。"))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 520)
                }
                VStack(spacing: 10) {
                    PermissionStep(index: 1, symbol: "rectangle.dashed.badge.record", title: L("屏幕录制"),
                                   detail: L("用于显示各应用窗口的实时缩略图。"),
                                   granted: store.screenAllowed) { store.requestScreen() }
                    PermissionStep(index: 2, symbol: "hand.point.up.left", title: L("辅助功能"),
                                   detail: L("用于点击缩略图切换到真实窗口，以及摆放、最小化和关闭窗口。"),
                                   granted: store.accessAllowed) { store.requestAccessibility() }
                }.frame(maxWidth: 560)
                VStack(alignment: .leading, spacing: 8) {
                    Label(L("授权小贴士"), systemImage: "lightbulb").font(.subheadline.weight(.semibold))
                    tip(L("在系统设置中打开开关后，回到这里点「重新检查」；屏幕录制通常需要退出并重新打开窗口图鉴才会生效。"))
                    tip(L("如果开关已经打开却仍显示未开启，请在系统设置的列表中选中 WindowAtlas，点「−」移除后再点「+」重新添加。"))
                    tip(L("更新到新版本后，系统可能要求重新授权一次，这是 macOS 的安全机制。"))
                }
                .padding(16).frame(maxWidth: 560, alignment: .leading).atlasPanel(padding: 0, raised: true)
                HStack(spacing: 10) {
                    Button(L("重新检查")) { Task { await store.refresh() } }.buttonStyle(AtlasHoverButtonStyle())
                    Button(L("退出并重新打开")) { AppRelauncher.relaunch() }.buttonStyle(AtlasHoverButtonStyle(accented: true))
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 40).frame(maxWidth: .infinity)
        }
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(AtlasStyle.accent).frame(width: 5, height: 5).offset(y: -2)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PermissionStep: View {
    let index: Int
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill((granted ? Color.green : AtlasStyle.accent).opacity(0.14))
                Image(systemName: granted ? "checkmark" : symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(granted ? Color.green : AtlasStyle.accent)
            }.frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(index). \(title)").font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Label(L("已开启"), systemImage: "checkmark.circle.fill").font(.callout.weight(.medium)).foregroundStyle(.green)
            } else {
                Button(L("去授权"), action: request).buttonStyle(AtlasHoverButtonStyle(accented: true))
            }
        }
        .padding(14).atlasPanel(padding: 0)
        .accessibilityElement(children: .combine)
        .accessibilityValue(granted ? L("已开启") : L("未开启"))
    }
}

/// 屏幕录制授权通常要重启进程才生效。等当前进程退出（释放笔记库锁）后再打开，避免新实例变成只读。
enum AppRelauncher {
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
