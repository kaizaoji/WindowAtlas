#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
APP="$PWD/dist/WindowAtlas.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/WindowAtlas "$APP/Contents/MacOS/WindowAtlas"
ditto .build/release/WindowAtlas_WindowAtlas.bundle "$APP/Contents/Resources/WindowAtlas_WindowAtlas.bundle"
# 应用图标来自 branding/（由 branding/tools/build.sh 生成），程序坞、访达与「关于」窗口使用。
cp branding/macos/WindowAtlas.icns "$APP/Contents/Resources/AppIcon.icns"
# MIT 许可要求副本附带版权与许可声明；公开仓库在根目录，开发仓库在 opensource/。
for license in LICENSE opensource/LICENSE; do
  [[ -f "$license" ]] && { cp "$license" "$APP/Contents/Resources/LICENSE"; break; }
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.kaizaoji.windowatlas</string>
<key>CFBundleName</key><string>WindowAtlas</string>
<key>CFBundleDisplayName</key><string>WindowAtlas</string>
<key>CFBundleExecutable</key><string>WindowAtlas</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>0.9.3</string>
<key>CFBundleVersion</key><string>50</string>
<key>NSAppleEventsUsageDescription</key><string>读取 Chrome、Edge、Safari 标签页，以及 Terminal/iTerm2 会话编号、TTY 和任务运行状态。终端检测不读取内容、不执行命令，数据仅在本机处理。</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSHumanReadableCopyright</key><string>© 2026 开造记 kaizaoji</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAccessibilityUsageDescription</key><string>窗口图鉴使用辅助功能权限，将你点击的窗口切换到前台。</string>
<key>NSScreenCaptureUsageDescription</key><string>窗口图鉴在本机显示打开窗口的缩略图，不保存或上传窗口内容。</string>
</dict></plist>
PLIST
# 早期内部测试版的偏好域只在需要迁移的本机构建时传入，不写进源码。
if [[ -n "${LEGACY_DEFAULTS_DOMAIN:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :WALegacyDefaultsDomain string $LEGACY_DEFAULTS_DOMAIN" "$APP/Contents/Info.plist"
fi
# 签名身份由环境变量 SIGN_IDENTITY 指定，默认 ad hoc（仅本机）。正式证书启用 Hardened Runtime 与 Apple Events 授权；
# 只有 Developer ID 证书才加安全时间戳（公证要求）。证书与凭据只放钥匙串，不写进仓库。
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - --identifier com.kaizaoji.windowatlas "$APP"
else
  TIMESTAMP=(--timestamp=none)
  [[ "$SIGN_IDENTITY" == *"Developer ID"* ]] && TIMESTAMP=(--timestamp)
  codesign --force --sign "$SIGN_IDENTITY" --identifier com.kaizaoji.windowatlas --options runtime \
    --entitlements scripts/WindowAtlas.entitlements "${TIMESTAMP[@]}" "$APP"
fi
echo "Built $APP"
