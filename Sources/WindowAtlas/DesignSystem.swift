import AppKit
import SwiftUI

/// 统一界面层次；动态 NSColor 确保跟随系统和应用内主题切换都能即时生效。
enum AtlasStyle {
    static let canvas = adaptive("canvas", light: 0xF3F6FA, dark: 0x10161F)
    static let surface = adaptive("surface", light: 0xFFFFFF, dark: 0x18212D)
    static let raised = adaptive("raised", light: 0xEAF0F6, dark: 0x222E3D)
    static let accent = adaptive("accent", light: 0x0876A3, dark: 0x54C7EB)
    static let border = adaptive("border", light: 0xD5DEE8, dark: 0x354354)
    static let radius: CGFloat = 12
    static let spacing: CGFloat = 12

    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("WindowAtlas." + name)) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                           green: CGFloat((value >> 8) & 0xff) / 255,
                           blue: CGFloat(value & 0xff) / 255, alpha: 1)
        })
    }
}

private struct AtlasPanelModifier: ViewModifier {
    let padding: CGFloat
    let raised: Bool
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(raised ? AtlasStyle.raised : AtlasStyle.surface,
                        in: RoundedRectangle(cornerRadius: AtlasStyle.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AtlasStyle.radius, style: .continuous)
                    .strokeBorder(AtlasStyle.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func atlasPanel(padding: CGFloat = 16, raised: Bool = false) -> some View {
        modifier(AtlasPanelModifier(padding: padding, raised: raised))
    }
}

struct AtlasHoverButtonStyle: ButtonStyle {
    var accented = false
    func makeBody(configuration: Configuration) -> some View {
        AtlasHoverButtonBody(configuration: configuration, accented: accented)
    }
}

private struct AtlasHoverButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let accented: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(accented ? AtlasStyle.accent : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(hovered && isEnabled ? AtlasStyle.accent.opacity(0.5) : AtlasStyle.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private var background: Color {
        if isEnabled && configuration.isPressed { return AtlasStyle.accent.opacity(0.22) }
        if isEnabled && hovered { return AtlasStyle.accent.opacity(0.12) }
        return accented ? AtlasStyle.accent.opacity(0.08) : AtlasStyle.surface
    }
}
