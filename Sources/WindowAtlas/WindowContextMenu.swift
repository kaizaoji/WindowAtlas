import AppKit
import SwiftUI

extension View {
    func windowContextMenu(item: WindowItem, store: WindowStore) -> some View {
        background(WindowContextAnchor(item: item, store: store))
    }
}

// A local right-click monitor leaves ordinary clicks, selection and dragging untouched.
// NSMenu owns the submenu tracking and positioning, including leftward opening near screen edges.
struct WindowContextAnchor: NSViewRepresentable {
    let item: WindowItem
    let store: WindowStore
    func makeNSView(context: Context) -> ContextView { ContextView(item: item, store: store) }
    func updateNSView(_ view: ContextView, context: Context) { view.item = item; view.markUpdated() }
    static func dismantleNSView(_ view: ContextView, coordinator: ()) { view.stop() }

    final class ContextView: NSView {
        var item: WindowItem
        let store: WindowStore
        /// 最近一次被 SwiftUI 更新的序号。重新排序后，懒加载网格可能暂时保留已隐藏或位置过期的旧视图；
        /// 它们不再被更新，序号停留在旧值，右键时据此排除，避免弹出别的窗口的菜单。
        private(set) var updateStamp = 0
        private static var stampCounter = 0
        private static let anchors = NSHashTable<ContextView>.weakObjects()
        private static var monitor: Any?

        init(item: WindowItem, store: WindowStore) {
            self.item = item; self.store = store
            super.init(frame: .zero)
            markUpdated()
            Self.anchors.add(self)
            // 全局只装一个右键监听，由它挑选真正位于鼠标下的卡片；不再让每个视图各自抢先响应。
            if Self.monitor == nil {
                Self.monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
                    guard let anchor = Self.anchor(for: event) else { return event }
                    anchor.show(event)
                    return nil
                }
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func stop() { Self.anchors.remove(self) }
        func markUpdated() { Self.stampCounter += 1; updateStamp = Self.stampCounter }

        private static func anchor(for event: NSEvent) -> ContextView? {
            anchors.allObjects.filter { view in
                guard view.window === event.window, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return false }
                // 用视图在窗口中的实际矩形判断；visibleRect 对这些嵌在 SwiftUI 中的视图不可靠（曾对所有卡片都返回包含）。
                var area = view.convert(view.bounds, to: nil)
                // 只认滚动区域内可见的部分，滚出可见区的卡片不会接管顶部栏等位置的右键。
                if let scroll = view.enclosingScrollView { area = area.intersection(scroll.convert(scroll.bounds, to: nil)) }
                return area.contains(event.locationInWindow)
            }.max { $0.updateStamp < $1.updateStamp }
        }
        // NSMenuItem.target 是弱引用。菜单打开期间定时刷新可能让网格回收这张卡片的视图，
        // 若以视图为 target，点击后动作会静默丢失；因此每项自带由菜单项强引用的动作对象。
        func add(_ title: String, to menu: NSMenu, action: @escaping () -> Void) {
            let handler = MenuAction(action)
            let entry = NSMenuItem(title: title, action: #selector(MenuAction.invoke), keyEquivalent: "")
            entry.target = handler
            entry.representedObject = handler
            menu.addItem(entry)
        }

        func show(_ event: NSEvent) {
            let target = item
            let menu = NSMenu()
            add(L("切换到窗口"), to: menu) { self.store.focus(target) }
            add(store.favorites.contains(target.savedKey) ? L("取消收藏") : L("收藏窗口"), to: menu) { self.store.toggleFavorite(target) }
            menu.addItem(.separator())
            // 右键点在已选窗口上时作用于全部选中窗口。
            let ordering = store.actionTargets(for: target.id)
            let count = ordering.count > 1 ? L("（%d 个窗口）", ordering.count) : ""
            add(L("置顶排列") + count, to: menu) { self.store.moveWindowsToEdge(ordering, top: true) }
            add(L("移到末尾") + count, to: menu) { self.store.moveWindowsToEdge(ordering, top: false) }
            // 选中 2～9 个窗口时，可一键排列。
            if ordering.count >= 2 && ordering.count <= TileLayout.maxWindows {
                let tile = NSMenuItem(title: L("排列窗口") + count, action: nil, keyEquivalent: "")
                let tileMenu = NSMenu()
                for layout in TileLayout.allCases { add(layout.title, to: tileMenu) { self.store.tileWindows(ordering, layout: layout) } }
                if NSScreen.screens.count > 1 {
                    tileMenu.addItem(.separator())
                    let each = NSMenuItem(title: L("按各自所在的显示器排列"), action: nil, keyEquivalent: "")
                    let eachMenu = NSMenu()
                    for layout in TileLayout.allCases { add(layout.title, to: eachMenu) { self.store.tileWindows(ordering, layout: layout, perDisplay: true) } }
                    each.submenu = eachMenu
                    tileMenu.addItem(each)
                    for (index, screen) in NSScreen.screens.enumerated() {
                        let target = NSMenuItem(title: L("排到显示器 %d · %@", index + 1, screen.localizedName), action: nil, keyEquivalent: "")
                        let targetMenu = NSMenu()
                        let id = screen.atlasDisplayID
                        for layout in TileLayout.allCases { add(layout.title, to: targetMenu) { self.store.tileWindows(ordering, layout: layout, displayID: id) } }
                        target.submenu = targetMenu
                        tileMenu.addItem(target)
                    }
                }
                tile.submenu = tileMenu
                menu.addItem(tile)
            }
            menu.addItem(.separator())
            let entry = NSMenuItem(title: L("窗口显示位置"), action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: L("窗口显示位置"))
            let content = NSMenuItem()
            let host = NSHostingView(rootView: PlacementPicker(item: target, dismiss: { menu.cancelTracking() }).environmentObject(store))
            host.frame.size = host.fittingSize
            content.view = host
            submenu.addItem(content); entry.submenu = submenu; menu.addItem(entry)
            add(L("最小化"), to: menu) { Task { await self.store.performWindowAction(target, action: .minimize) } }
            menu.addItem(.separator())
            add(L("关闭窗口"), to: menu) { Task { await self.store.performWindowAction(target, action: .close) } }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

/// 菜单项的动作对象：由 NSMenuItem.representedObject 持有，生命周期与菜单项一致。
final class MenuAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}

