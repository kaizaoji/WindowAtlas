import SwiftUI

// 让窗口和标签列表共用焦点规则；输入框获得焦点时不接管方向键。
struct ListKeyboardNavigation<ID: Hashable>: ViewModifier {
    let ids: [ID]
    @Binding var selection: ID?
    var columns: Int = 1
    var activate: (ID) -> Void
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .simultaneousGesture(TapGesture().onEnded { focused = true })
                .onAppear { focused = true }
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .home, .end, .escape]) { press in
                    guard press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .ignored }
                    if press.key == .return {
                        guard let selection, ids.contains(selection) else { return .ignored }
                        activate(selection)
                    } else if press.key == .home {
                        selection = ids.first
                    } else if press.key == .end {
                        selection = ids.last
                    } else if press.key == .escape {
                        selection = nil
                    } else {
                        let forward = press.key == .downArrow || press.key == .rightArrow
                        let stride = press.key == .upArrow || press.key == .downArrow ? max(1, columns) : 1
                        selection = adjacentListSelection(ids, current: selection, forward: forward, stride: stride)
                    }
                    return .handled
                }
                .onChange(of: selection) { _, selected in
                    if let selected {
                        focused = true
                        proxy.scrollTo(selected)
                    }
                }
        }
    }
}

func adjacentListSelection<ID: Equatable>(_ ids: [ID], current: ID?, forward: Bool, stride: Int = 1) -> ID? {
    guard !ids.isEmpty else { return nil }
    guard let current, let index = ids.firstIndex(of: current) else {
        return forward ? ids.first : ids.last
    }
    return ids[max(0, min(ids.count - 1, index + (forward ? max(1, stride) : -max(1, stride))))]
}

// 与网格的横向留白、列间距保持一致，缩放后上下方向仍落到相邻行。
func windowGridColumns(width: CGFloat, cardWidth: CGFloat) -> Int {
    let usable = max(1, width - 48)
    return max(1, Int((usable + 12) / (min(max(1, cardWidth), usable) + 12)))
}
