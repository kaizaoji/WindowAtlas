import AppKit
import SwiftUI

/// 品牌图片由 branding/tools/build.sh 生成并同步到 Resources/Brand；加载失败时回退系统符号，界面不会出现空白。
enum BrandAssets {
    /// 菜单栏模板图标：纯黑 + 透明度，系统按菜单栏深浅自动反色。
    static let menubarIcon: NSImage? = {
        guard let image = Localization.resourceBundle.image(forResource: "BrandMenubarTemplate") else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    /// 满版圆角品牌图标，用于侧栏标题等应用内位置。
    static let icon: NSImage? = Localization.resourceBundle.image(forResource: "BrandIcon")
}

/// 应用内品牌标志：优先品牌图标，缺失时使用原系统符号样式。
struct BrandMark: View {
    var size: CGFloat = 38
    var body: some View {
        if let icon = BrandAssets.icon {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
                .accessibilityLabel(L("窗口图鉴"))
        } else {
            Image(systemName: "rectangle.3.group.fill")
                .font(.system(size: size * 0.52, weight: .medium)).foregroundStyle(AtlasStyle.accent)
                .frame(width: size, height: size).background(AtlasStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: size * 0.29))
        }
    }
}
