import AppKit
import ApplicationServices
import ScreenCaptureKit

enum ManagedWindowAction {
    case focus, close, minimize
    case place(WindowPlacement, CGDirectDisplayID?)
    /// 批量布局：直接设为指定位置与尺寸（屏幕坐标）。
    case frame(CGRect)
}

struct AccessibleWindow {
    let element: AXUIElement
    let parent: AXUIElement
    let descriptor: WindowDescriptor
    let isSheet: Bool
}

@MainActor
extension WindowStore {
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    func accessibleWindows(pid: pid_t) -> [AccessibleWindow] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let roots = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        var output: [AccessibleWindow] = []
        var visited: [AXUIElement] = []
        func append(_ element: AXUIElement, parent: AXUIElement, depth: Int) {
            guard depth < 8, visited.count < 300, !visited.contains(where: { CFEqual($0, element) }) else { return }
            visited.append(element)
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
            let dialog = role == kAXSheetRole || role == "AXDialog" || subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole
            if (role == kAXWindowRole || dialog), let frame = axFrame(element) {
                output.append(AccessibleWindow(element: element, parent: parent,
                    descriptor: WindowDescriptor(title: attribute(element, kAXTitleAttribute) as? String ?? "", frame: frame),
                    isSheet: dialog || !CFEqual(element, parent)))
            }
            // Sheets may be wrapped in an AXGroup rather than direct children.
            // Do not traverse text/scroll areas containing terminal session contents.
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            for child in children {
                let role = attribute(child, kAXRoleAttribute) as? String ?? ""
                if [kAXSheetRole, "AXDialog", kAXWindowRole, kAXGroupRole, kAXSplitGroupRole].contains(role) {
                    append(child, parent: parent, depth: depth + 1)
                }
            }
        }
        for root in roots { append(root, parent: root, depth: 0) }
        // Some applications expose a dialog only through the focused UI element.
        if let focused = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            var element = focused as! AXUIElement
            for _ in 0..<8 {
                let role = attribute(element, kAXRoleAttribute) as? String ?? ""
                let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
                if role == kAXSheetRole || subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole {
                    let value = attribute(element, kAXWindowAttribute)
                    let parent = value.map { CFGetTypeID($0) == AXUIElementGetTypeID() ? $0 as! AXUIElement : element } ?? element
                    append(element, parent: parent, depth: 0)
                    break
                }
                guard let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                element = parent as! AXUIElement
            }
        }
        return output
    }

    func cancelButton(_ dialog: AXUIElement) -> CFTypeRef? {
        if let button = attribute(dialog, kAXCancelButtonAttribute) { return button }
        var inspected = 0
        func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth < 7, inspected < 150 else { return nil }
            inspected += 1
            if (attribute(element, kAXRoleAttribute) as? String) == kAXButtonRole,
               isSafeCancelTitle(attribute(element, kAXTitleAttribute) as? String ?? "") { return element }
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let button = find(child, depth: depth + 1) { return button }
            }
            return nil
        }
        return find(dialog, depth: 0)
    }

    func resolveWindow(_ item: WindowItem) async throws -> AccessibleWindow? {
        // Refresh the target by stable window-server ID, not by the thumbnail's old title.
        let live = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let source = live.windows.first(where: { $0.windowID == item.id && $0.owningApplication?.processID == item.pid }) else {
            errorMessage = L("这个窗口已经关闭，列表将自动更新。"); return nil
        }
        let candidates = accessibleWindows(pid: item.pid)
        let liveTitle = source.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let uniqueFrame = live.windows.filter {
            $0.windowLayer == 0 && $0.owningApplication?.processID == item.pid && geometryDistance($0.frame, source.frame) <= 24
        }.count == 1
        guard let index = matchingWindowIndex(title: liveTitle.isEmpty ? item.appName : liveTitle,
            appName: item.appName, frame: source.frame, candidates: candidates.map(\.descriptor), allowUniqueGeometry: uniqueFrame, geometryTolerance: 24) else {
            if !source.isOnScreen {
                staleWindowIDs.insert(item.id)
                errorMessage = L("这个预览对应的窗口已不再显示，已清理过期预览。重新显示的窗口会自动出现。")
            } else {
                errorMessage = L("无法识别这个确认框。请在原应用点击取消；不会自动停止正在运行的任务。")
            }
            return nil
        }
        return candidates[index]
    }

    /// 把选中的窗口（按看板显示顺序，最多 9 个）排到一块显示器上。默认用第一个窗口所在的显示器。
    /// perDisplay：多显示器时窗口留在各自所在的屏幕，每块屏幕上的窗口分别排列。
    func tileWindows(_ ids: [CGWindowID], layout: TileLayout, displayID: CGDirectDisplayID? = nil, perDisplay: Bool = false) {
        // 按传入顺序（看板或标签的显示顺序）取窗口；标签页视图下这些窗口可能不在当前栏目的窗口列表里。
        var seen = Set<CGWindowID>()
        let items = ids.filter { seen.insert($0).inserted }.compactMap { id in windows.first { $0.id == id } }
        guard items.count >= 1 else { return }
        guard items.count <= TileLayout.maxWindows else {
            errorMessage = L("一次最多排列 %d 个窗口，请减少选择。", TileLayout.maxWindows); return
        }
        func screenOf(_ item: WindowItem) -> NSScreen? {
            NSScreen.screens.max(by: { intersectionArea(item.frame, quartzFrame($0.visibleFrame)) < intersectionArea(item.frame, quartzFrame($1.visibleFrame)) })
        }
        var placements: [(WindowItem, CGRect)] = []
        if perDisplay {
            let groups = Dictionary(grouping: items) { screenOf($0)?.atlasDisplayID ?? 0 }
            for (id, group) in groups {
                guard let screen = NSScreen.screens.first(where: { $0.atlasDisplayID == id }) ?? screenOf(group[0]) else { continue }
                // 保持看板中的先后顺序
                let ordered = items.filter { item in group.contains { $0.id == item.id } }
                placements += zip(ordered, tileFrames(count: ordered.count, layout: layout, usable: quartzFrame(screen.visibleFrame))).map { ($0, $1) }
            }
        } else {
            let screen = displayID.flatMap { id in NSScreen.screens.first { $0.atlasDisplayID == id } } ?? screenOf(items[0])
            guard let screen else { return }
            placements = Array(zip(items, tileFrames(count: items.count, layout: layout, usable: quartzFrame(screen.visibleFrame))))
        }
        let frames = placements.map(\.1)
        // 标记已排列的窗口和所在显示器，方便给另一块屏幕挑窗口时避开。
        for (item, frame) in placements {
            let index = NSScreen.screens.firstIndex { quartzFrame($0.visibleFrame).intersects(frame) } ?? 0
            let name = NSScreen.screens.count > 1 ? L("显示器 %d", index + 1) : L("当前屏幕")
            arrangedWindows[item.id] = ArrangedMark(display: name, frame: frame, date: Date())
        }
        Task {
            // 各窗口属于不同应用，并行设置以缩短等待；全部完成后按顺序带到前面，避免被其他窗口挡住。
            await withTaskGroup(of: Void.self) { group in
                for (item, frame) in zip(placements.map(\.0), frames) {
                    group.addTask { await self.performWindowAction(item, action: .frame(frame)) }
                }
            }
            for item in items.reversed() { await performWindowAction(item, action: .focus) }
        }
    }

    func performWindowAction(_ item: WindowItem, action: ManagedWindowAction) async {
        accessAllowed = AXIsProcessTrusted()
        guard accessAllowed else { requestAccessibility(); return }
        errorMessage = nil
        // 其他桌面空间的窗口不在辅助功能列表里：先切换到它所在的桌面，等它出现在屏幕上再按常规流程操作。
        if item.onOtherSpace, !SpaceSupport.isOnScreen(item.id) {
            guard SpaceSupport.bringToFront(pid: item.pid, windowID: item.id) else {
                errorMessage = L("无法切换到这个窗口所在的桌面，请在调度中心中切换后再试。"); return
            }
            for _ in 0..<15 where !SpaceSupport.isOnScreen(item.id) { try? await Task.sleep(for: .milliseconds(100)) }
        }
        do {
            // 普通窗口先按窗口服务器的实时 ID 校验，避免每次点击等待整份捕获列表。
            var resolved: AccessibleWindow?
            if case .focus = action { resolved = resolveFocusWindow(item) }
            if resolved == nil { resolved = try await resolveWindow(item) }
            guard let target = resolved, let app = NSRunningApplication(processIdentifier: item.pid) else {
                await refresh(); return
            }
            let root = target.parent
            switch action {
            case .focus:
                app.unhide()
                AXUIElementSetAttributeValue(root, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                app.activate(options: [])
                let result = AXUIElementPerformAction(root, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(root, kAXMainAttribute as CFString, kCFBooleanTrue)
                if target.isSheet { AXUIElementPerformAction(target.element, kAXRaiseAction as CFString) }
                if result != .success { errorMessage = L("该应用暂时没有接受窗口置前请求。") }
                // 切换不改变窗口集合，预览交给已有刷新周期，避免连续切换触发重复捕获。
                return
            case .close:
                // Only native close / cancel controls. Never terminate a process or accept a destructive dialog.
                let button: CFTypeRef?
                if target.isSheet {
                    button = cancelButton(target.element)
                } else { button = attribute(target.element, kAXCloseButtonAttribute) }
                guard let button, CFGetTypeID(button) == AXUIElementGetTypeID() else {
                    if target.isSheet {
                        var actions: CFArray?
                        if AXUIElementCopyActionNames(target.element, &actions) == .success,
                           (actions as? [String])?.contains(kAXCancelAction as String) == true,
                           AXUIElementPerformAction(target.element, kAXCancelAction as CFString) == .success { await refresh(); return }
                    }
                    errorMessage = target.isSheet ? L("这个确认框没有可识别的取消按钮，请在原应用取消；不会自动终止任务。") : L("该窗口没有可用的关闭按钮，请切换到原应用处理。")
                    return
                }
                if AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) != .success {
                    errorMessage = L("应用未接受关闭请求。")
                } else {
                    // A close request may open a save dialog; hide only after AX confirms
                    // removal. ScreenCaptureKit can retain a closed NSWindow's old surface.
                    try? await Task.sleep(for: .milliseconds(250))
                    if !accessibleWindows(pid: item.pid).contains(where: { CFEqual($0.element, target.element) }) {
                        closedTargets[item.id] = (item.pid, target.element)
                    }
                }
            case .minimize:
                if AXUIElementSetAttributeValue(root, kAXMinimizedAttribute as CFString, kCFBooleanTrue) != .success {
                    errorMessage = L("该应用不支持最小化这个窗口。")
                }
            case .place(let placement, let displayID):
                guard let current = axFrame(root) else { errorMessage = L("无法读取窗口位置。"); return }
                if let displayID, !NSScreen.screens.contains(where: { $0.atlasDisplayID == displayID }) {
                    errorMessage = L("目标显示器已断开，请重新选择。"); return
                }
                let screen = displayID.flatMap { id in NSScreen.screens.first { $0.atlasDisplayID == id } }
                    ?? NSScreen.screens.max(by: { intersectionArea(current, quartzFrame($0.visibleFrame)) < intersectionArea(current, quartzFrame($1.visibleFrame)) })
                guard let screen else { return }
                if originalFrames[item.id] == nil { originalFrames[item.id] = current }
                let targetFrame = placement == .restore ? originalFrames[item.id] ?? current
                    : placedFrame(placement, current: current, usable: quartzFrame(screen.visibleFrame))
                await applyFrame(root, targetFrame)
                if placement == .restore { originalFrames.removeValue(forKey: item.id) }
            case .frame(let targetFrame):
                guard let current = axFrame(root) else { errorMessage = L("无法读取窗口位置。"); return }
                // 记下布局前的位置，之后可用「还原调整前的位置」恢复。
                if originalFrames[item.id] == nil { originalFrames[item.id] = current }
                await applyFrame(root, targetFrame)
            }
            await refresh()
        } catch { errorMessage = L("窗口操作失败：%@", error.localizedDescription) }
    }

    /// 把窗口设为指定位置与尺寸（屏幕坐标，左上角原点）。先改尺寸再移位置，并有限重试，兼容跨屏与应用自身的约束。
    private func applyFrame(_ root: AXUIElement, _ targetFrame: CGRect) async {
        AXUIElementSetAttributeValue(root, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        var point = targetFrame.origin, size = targetFrame.size
        if let position = AXValueCreate(.cgPoint, &point), let dimensions = AXValueCreate(.cgSize, &size) {
            let b = AXUIElementSetAttributeValue(root, kAXSizeAttribute as CFString, dimensions)
            // AX frame changes can be queued by the target app. Let its resize
            // finish before sending a position based on the new dimensions.
            try? await Task.sleep(for: .milliseconds(200))
            // AppKit resizing preserves the old top-left origin. Move after resize
            // so that the resize cannot overwrite the requested placement.
            let a = AXUIElementSetAttributeValue(root, kAXPositionAttribute as CFString, position)
            try? await Task.sleep(for: .milliseconds(200))
            // 小屏上的应用可能把第一次调整限制在原屏尺寸；跨屏后重新应用目标尺寸。
            let resized = AXUIElementSetAttributeValue(root, kAXSizeAttribute as CFString, dimensions)
            try? await Task.sleep(for: .milliseconds(150))
            let positioned = AXUIElementSetAttributeValue(root, kAXPositionAttribute as CFString, position)
            if a != .success || b != .success || resized != .success || positioned != .success {
                errorMessage = L("该应用限制了窗口的位置或尺寸，已应用支持的部分。")
            }
            // 跨屏动画可能稍后再次约束窗口，有限重试并校验实际结果。
            for _ in 0..<3 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let actual = axFrame(root), geometryDistance(actual, targetFrame) > 4 else { break }
                AXUIElementSetAttributeValue(root, kAXSizeAttribute as CFString, dimensions)
                try? await Task.sleep(for: .milliseconds(350))
                AXUIElementSetAttributeValue(root, kAXPositionAttribute as CFString, position)
            }
            try? await Task.sleep(for: .milliseconds(250))
            if let actual = axFrame(root), geometryDistance(actual, targetFrame) > 4 {
                errorMessage = L("该应用限制了窗口的位置或尺寸，已应用支持的部分。")
            }
        }
    }

    private func resolveFocusWindow(_ item: WindowItem) -> AccessibleWindow? {
        guard let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, item.id) as? [[String: Any]],
              let entry = entries.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == item.id }),
              (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == item.pid,
              let bounds = entry[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        let application = AXUIElementCreateApplication(item.pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let roots = attribute(application, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        let candidates = roots.compactMap { element -> AccessibleWindow? in
            guard let frame = axFrame(element) else { return nil }
            return AccessibleWindow(element: element, parent: element,
                descriptor: WindowDescriptor(title: attribute(element, kAXTitleAttribute) as? String ?? "", frame: frame),
                isSheet: false)
        }
        guard let index = matchingWindowIndex(title: entry[kCGWindowName as String] as? String ?? item.title,
            appName: item.appName, frame: frame, candidates: candidates.map(\.descriptor),
            allowUniqueGeometry: true, geometryTolerance: 24),
              geometryDistance(candidates[index].descriptor.frame, frame) <= 24 else { return nil }
        return candidates[index]
    }

    func quartzFrame(_ rect: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? rect.maxY
        return quartzScreenFrame(rect, primaryTop: top)
    }

    func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b); return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    func locationLabel(_ item: WindowItem) -> String {
        let screen = NSScreen.screens.max(by: { intersectionArea(item.frame, quartzFrame($0.visibleFrame)) < intersectionArea(item.frame, quartzFrame($1.visibleFrame)) })
        return "\(screen?.localizedName ?? L("屏幕")) · \(Int(item.frame.minX)), \(Int(item.frame.minY))"
    }
}


extension NSScreen {
    var atlasDisplayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

func quartzScreenFrame(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
}

/// 不在屏幕上的窗口里，有些只是应用的内部窗口或已关闭后仍驻留的窗口（如 Chrome 的弹出层、500×500 隐藏占位窗口、
/// 关闭后保留的「活动监视器」窗口），辅助功能接口里没有对应窗口，既无法预览也无法打开。刷新时在后台识别并不列出。
/// 最小化窗口、终端的其他标签页（与所在窗口尺寸相同）都有对应窗口，会保留。
/// 辅助功能接口只返回当前桌面空间的窗口；其他桌面空间里的窗口由 SpaceSupport 另行识别后保留，不在此处隐藏。
enum OffscreenWindowFilter {
    struct Candidate: Sendable { let id: CGWindowID; let pid: pid_t; let frame: CGRect }

    /// 返回应隐藏的窗口编号。某个应用读取失败（未授权、超时）时不隐藏它的任何窗口。
    static func unreachable(_ candidates: [Candidate]) -> Set<CGWindowID> {
        var hidden: Set<CGWindowID> = []
        for (pid, windows) in Dictionary(grouping: candidates, by: \.pid) {
            guard let frames = accessibleFrames(pid: pid) else { continue }
            for window in windows where !frames.contains(where: { geometryDistance($0, window.frame) <= 24 }) {
                hidden.insert(window.id)
            }
        }
        return hidden
    }

    private static func accessibleFrames(pid: pid_t) -> [CGRect]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let roots = value as? [AXUIElement] else { return nil }
        return roots.compactMap { element in
            var position: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
                  let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, extent = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
            return CGRect(origin: point, size: extent)
        }
    }
}

