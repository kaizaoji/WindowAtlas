import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ApplicationOrderDrop: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let store: WindowStore
    func validateDrop(info: DropInfo) -> Bool { dragging != nil && info.hasItemsConforming(to: [UTType.text]) }
    func dropEntered(info: DropInfo) {
        guard let source = dragging, source != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) { store.moveApp(source, to: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

/// 窗口卡片与列表行的拖拽排列：拖到另一项上方时实时让位，松手后保存为当前栏目的手动顺序。
struct WindowOrderDrop: DropDelegate {
    let target: CGWindowID
    let store: WindowStore
    func validateDrop(info: DropInfo) -> Bool { !store.draggingWindowIDs.isEmpty && info.hasItemsConforming(to: [UTType.text]) }
    func dropEntered(info: DropInfo) {
        let moving = store.draggingWindowIDs
        guard !moving.isEmpty, !moving.contains(target) else { return }
        withAnimation(.easeInOut(duration: 0.18)) { store.moveWindows(moving, to: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { store.draggingWindowIDs = []; return true }
}

extension View {
    func windowReordering(item: WindowItem, store: WindowStore) -> some View {
        onDrag {
            // 拖动已选中的窗口时整组移动，否则只移动这一个。
            store.draggingWindowIDs = store.actionTargets(for: item.id)
            return NSItemProvider(object: ("windowatlas-window:\(item.id)") as NSString)
        }
        .onDrop(of: [UTType.text], delegate: WindowOrderDrop(target: item.id, store: store))
    }
}

struct PlacementDiagram: View {
    let placement: WindowPlacement
    var body: some View {
        GeometryReader { proxy in
            let frame = placedFrame(placement, current: CGRect(x: 0, y: 0, width: 18, height: 12),
                usable: CGRect(origin: .zero, size: proxy.size))
            RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.4), lineWidth: 1)
            if placement.gridIndex != nil {
                Path { path in
                    for n in 1...2 {
                        let x = proxy.size.width * CGFloat(n) / 3
                        let y = proxy.size.height * CGFloat(n) / 3
                        path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                        path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                    }
                }.stroke(.secondary.opacity(0.2), lineWidth: 0.5)
            }
            RoundedRectangle(cornerRadius: 2).fill(AtlasStyle.accent.opacity(0.85))
                .frame(width: max(1, frame.width - 3), height: max(1, frame.height - 3))
                .offset(x: frame.minX + 1.5, y: frame.minY + 1.5)
        }.frame(width: 40, height: 25).accessibilityHidden(true)
    }
}

struct PlacementPicker: View {
    @EnvironmentObject var store: WindowStore
    let item: WindowItem
    var dismiss: () -> Void
    @State private var displayID: CGDirectDisplayID = 0
    @State private var screens = NSScreen.screens
    private func apply(_ placement: WindowPlacement) {
        dismiss()
        Task { await store.performWindowAction(item, action: .place(placement, displayID == 0 ? nil : displayID)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.3.group").foregroundStyle(AtlasStyle.accent)
                Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).help(item.title)
            }
            // 单屏没有可切换目标，避免选择器挤占菜单空间。
            if screens.count > 1 {
                Picker(L("显示器"), selection: $displayID) {
                    Text(L("窗口所在屏幕")).tag(CGDirectDisplayID(0))
                    ForEach(Array(screens.enumerated()), id: \.element.atlasDisplayID) { index, screen in
                        Text("\(index + 1) · \(screen.localizedName)").tag(screen.atlasDisplayID)
                    }
                }
                .controlSize(.small)
            }
            HStack { Text(L("九宫格")); Spacer(); Text(L("每格 1/9")).foregroundStyle(.secondary) }
                .font(.system(size: 11))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
                ForEach(WindowPlacement.grid, id: \.self) { placement in
                    choice(placement)
                }
            }
            Divider()
            HStack(spacing: 5) {
                ForEach([WindowPlacement.left, .right, .top, .bottom], id: \.self) { placement in choice(placement) }
            }
            HStack(spacing: 6) {
                Button(L("铺满屏幕")) { apply(.maximize) }
                Button(L("居中")) { apply(.center) }
                Spacer()
                Button(L("还原位置")) { apply(.restore) }
            }.controlSize(.small)
        }.padding(12).frame(width: 268)
            .help(L("点击图示立即应用；部分应用有最小尺寸限制。"))
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                screens = NSScreen.screens
                if !screens.contains(where: { $0.atlasDisplayID == displayID }) { displayID = 0 }
            }
    }
    private func choice(_ placement: WindowPlacement) -> some View {
        Button { apply(placement) } label: {
            VStack(spacing: 3) {
                PlacementDiagram(placement: placement)
                Text(placement.title).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.7)
            }.frame(maxWidth: .infinity).padding(.vertical, 5)
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(PlacementChoiceStyle()).accessibilityLabel(placement.title)
            .help(placement.title)
    }
}

private struct PlacementChoiceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlacementChoiceBody(configuration: configuration)
    }

    private struct PlacementChoiceBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(configuration.isPressed ? AtlasStyle.accent.opacity(0.25)
                    : hovered ? AtlasStyle.accent.opacity(0.14) : AtlasStyle.raised,
                    in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(hovered ? AtlasStyle.accent.opacity(0.5) : AtlasStyle.border))
                .onHover { hovered = $0 }
        }
    }
}
