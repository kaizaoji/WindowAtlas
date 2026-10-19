#!/bin/zsh
# 从 source/*.svg 重新生成全部品牌资源。只依赖 Xcode 命令行工具（swiftc）与系统自带 iconutil、base64。
# 用法：zsh branding/tools/build.sh
set -euo pipefail
ROOT="${0:A:h:h}"
SRC="$ROOT/source"
WORK="$(mktemp -d -t windowatlas-brand)"
trap 'rm -rf "$WORK"' EXIT

echo "编译渲染工具…"
swiftc -O "$ROOT/tools/render.swift" -o "$WORK/render"
swiftc -O "$ROOT/tools/ico.swift" -o "$WORK/ico"

mkdir -p "$ROOT/png" "$ROOT/macos" "$ROOT/windows" "$ROOT/web" "$ROOT/preview"
# 小尺寸简化版的满版裁切（无外边距），用于 .ico 与 favicon 的 16/24/32 像素。
sed 's/viewBox="0 0 1024 1024"/viewBox="100 100 824 824"/' "$SRC/app-icon-small.svg" > "$WORK/app-icon-small-flat.svg"
# 总览图深色背景上的菜单栏示意用白色版本（实际菜单栏由系统按模板图自动反色）。
sed 's/#000/#FFF/g' "$SRC/menubar-template.svg" > "$WORK/menubar-white.svg"

jobs=()
add() { jobs+=("$1" "$2" "$3" "$4"); }

# macOS 应用图标：16/32 用简化版，其余用完整版；保留 Apple 图标网格外边距与投影。
ICONSET="$WORK/WindowAtlas.iconset"
mkdir -p "$ICONSET"
add "$SRC/app-icon-small.svg" "$ICONSET/icon_16x16.png" 16 16
add "$SRC/app-icon-small.svg" "$ICONSET/icon_16x16@2x.png" 32 32
add "$SRC/app-icon-small.svg" "$ICONSET/icon_32x32.png" 32 32
add "$SRC/app-icon.svg" "$ICONSET/icon_32x32@2x.png" 64 64
for size in 128 256 512; do
  add "$SRC/app-icon.svg" "$ICONSET/icon_${size}x${size}.png" $size $size
  add "$SRC/app-icon.svg" "$ICONSET/icon_${size}x${size}@2x.png" $((size * 2)) $((size * 2))
done
for size in 16 32; do add "$SRC/app-icon-small.svg" "$ROOT/png/app-icon-$size.png" $size $size; done
for size in 64 128 256 512 1024; do add "$SRC/app-icon.svg" "$ROOT/png/app-icon-$size.png" $size $size; done

# Windows / Web：满版无投影。
for size in 16 24 32; do add "$WORK/app-icon-small-flat.svg" "$WORK/flat-$size.png" $size $size; done
for size in 48 64 128 256; do add "$SRC/app-icon-flat.svg" "$WORK/flat-$size.png" $size $size; done
add "$WORK/app-icon-small-flat.svg" "$ROOT/web/favicon-32.png" 32 32
add "$SRC/app-icon-flat.svg" "$ROOT/web/apple-touch-icon-180.png" 180 180
add "$SRC/app-icon-flat.svg" "$ROOT/web/icon-192.png" 192 192
add "$SRC/app-icon-flat.svg" "$ROOT/web/icon-512.png" 512 512

# 图形标、单色版、菜单栏模板图标（18pt：@1x 18 像素、@2x 36 像素）。
for size in 256 512 1024; do add "$SRC/mark.svg" "$ROOT/png/mark-$size.png" $size $size; done
add "$SRC/mark-mono-white.svg" "$ROOT/png/mark-mono-white-512.png" 512 512
add "$SRC/mark-mono-navy.svg" "$ROOT/png/mark-mono-navy-512.png" 512 512
add "$SRC/menubar-template.svg" "$ROOT/png/menubar-template.png" 18 18
add "$SRC/menubar-template.svg" "$ROOT/png/menubar-template@2x.png" 36 36

# 组合标与横幅（@1x 与 @2x）。
for theme in light dark; do
  add "$SRC/logo-horizontal-$theme.svg" "$ROOT/png/logo-horizontal-$theme.png" 1240 360
  add "$SRC/logo-horizontal-$theme.svg" "$ROOT/png/logo-horizontal-$theme@2x.png" 2480 720
  add "$SRC/logo-vertical-$theme.svg" "$ROOT/png/logo-vertical-$theme.png" 760 860
  add "$SRC/logo-vertical-$theme.svg" "$ROOT/png/logo-vertical-$theme@2x.png" 1520 1720
done
add "$SRC/social-banner.svg" "$ROOT/png/social-banner.png" 1280 640
add "$SRC/social-banner.svg" "$ROOT/png/social-banner@2x.png" 2560 1280
add "$WORK/menubar-white.svg" "$WORK/menubar-white@2x.png" 36 36

# 应用内资源：侧栏品牌图标（满版，最大显示 38pt，提供 128 像素）与菜单栏模板图标。
APPRES="$ROOT/../Sources/WindowAtlas/Resources/Brand"
mkdir -p "$APPRES"
add "$SRC/app-icon-flat.svg" "$APPRES/BrandIcon.png" 128 128
add "$SRC/menubar-template.svg" "$APPRES/BrandMenubarTemplate.png" 18 18
add "$SRC/menubar-template.svg" "$APPRES/BrandMenubarTemplate@2x.png" 36 36

echo "渲染 $(( ${#jobs[@]} / 4 )) 个 PNG…"
"$WORK/render" "${jobs[@]}" > /dev/null

iconutil -c icns "$ICONSET" -o "$ROOT/macos/WindowAtlas.icns"
# 覆盖写入（文件名固定），不先删除整个目录。
ditto "$ICONSET" "$ROOT/macos/WindowAtlas.iconset"
"$WORK/ico" "$ROOT/windows/WindowAtlas.ico" "$WORK"/flat-{16,24,32,48,64,128,256}.png
"$WORK/ico" "$ROOT/web/favicon.ico" "$WORK"/flat-{16,32,48}.png

# 品牌总览图：PNG 以 data URI 内嵌，生成后渲染为 preview/brand-sheet.png。
uri() { print -n "data:image/png;base64,$(base64 -i "$1" | tr -d '\n')"; }
FONT="-apple-system, 'PingFang SC', 'Hiragino Sans GB', sans-serif"
swatch() { print "<rect x=\"$1\" y=\"1040\" width=\"150\" height=\"90\" rx=\"14\" fill=\"$2\" stroke=\"#D5DEE8\"/><text x=\"$1\" y=\"1160\" font-family=\"$FONT\" font-size=\"20\" fill=\"#10161F\">$3</text><text x=\"$1\" y=\"1186\" font-family=\"ui-monospace, Menlo\" font-size=\"18\" fill=\"#5B6B7E\">$2</text>"; }
cat > "$WORK/brand-sheet.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1600 1240">
<rect width="1600" height="1240" fill="#F3F6FA"/>
<text x="60" y="80" font-family="$FONT" font-size="40" font-weight="700" fill="#10161F">WindowAtlas 窗口图鉴 · 品牌资源</text>
<text x="60" y="120" font-family="$FONT" font-size="22" fill="#5B6B7E">层叠聚焦：层叠窗口 + 缩略图看板 + 聚焦取景框；深海军蓝底板与青蓝强调色，与应用设计系统一致</text>
<image href="$(uri "$ROOT/png/app-icon-512.png")" x="40" y="150" width="400" height="400"/>
<rect x="470" y="170" width="250" height="250" rx="24" fill="#FFFFFF" stroke="#D5DEE8"/><image href="$(uri "$ROOT/png/mark-512.png")" x="495" y="195" width="200" height="200"/>
<rect x="740" y="170" width="250" height="250" rx="24" fill="#10161F"/><image href="$(uri "$ROOT/png/mark-512.png")" x="765" y="195" width="200" height="200"/>
<rect x="1010" y="170" width="250" height="250" rx="24" fill="#10161F"/><image href="$(uri "$ROOT/png/mark-mono-white-512.png")" x="1035" y="195" width="200" height="200"/>
<rect x="1280" y="170" width="250" height="250" rx="24" fill="#FFFFFF" stroke="#D5DEE8"/><image href="$(uri "$ROOT/png/mark-mono-navy-512.png")" x="1305" y="195" width="200" height="200"/>
<g font-family="$FONT" font-size="18" fill="#5B6B7E"><text x="470" y="450">图形标 · 浅色背景</text><text x="740" y="450">图形标 · 深色背景</text><text x="1010" y="450">单色 · 白</text><text x="1280" y="450">单色 · 海军蓝</text></g>
<rect x="470" y="480" width="520" height="90" rx="18" fill="#FFFFFF" stroke="#D5DEE8"/>
<image href="$(uri "$ROOT/png/app-icon-16.png")" x="500" y="517" width="16" height="16"/><image href="$(uri "$ROOT/png/app-icon-32.png")" x="536" y="509" width="32" height="32"/>
<image href="$(uri "$ROOT/png/app-icon-64.png")" x="588" y="493" width="64" height="64"/><image href="$(uri "$ROOT/png/menubar-template@2x.png")" x="700" y="516" width="18" height="18"/>
<rect x="1010" y="480" width="520" height="90" rx="18" fill="#10161F"/>
<image href="$(uri "$ROOT/png/app-icon-16.png")" x="1040" y="517" width="16" height="16"/><image href="$(uri "$ROOT/png/app-icon-32.png")" x="1076" y="509" width="32" height="32"/>
<image href="$(uri "$ROOT/png/app-icon-64.png")" x="1128" y="493" width="64" height="64"/><image href="$(uri "$WORK/menubar-white@2x.png")" x="1240" y="516" width="18" height="18"/>
<g font-family="$FONT" font-size="18" fill="#5B6B7E"><text x="740" y="531">← 16 / 32 / 64 · 菜单栏模板</text></g>
<rect x="40" y="610" width="740" height="250" rx="24" fill="#FFFFFF" stroke="#D5DEE8"/><image href="$(uri "$ROOT/png/logo-horizontal-light@2x.png")" x="80" y="645" width="660" height="192"/>
<rect x="820" y="610" width="740" height="250" rx="24" fill="#10161F"/><image href="$(uri "$ROOT/png/logo-horizontal-dark@2x.png")" x="860" y="645" width="660" height="192"/>
<text x="60" y="920" font-family="$FONT" font-size="26" font-weight="700" fill="#10161F">配色</text>
<text x="60" y="960" font-family="$FONT" font-size="20" fill="#5B6B7E">与 DesignSystem.swift 中 AtlasStyle 一致；图标渐变在强调色两端扩展了高光青与深青</text>
$(swatch 60 "#10161F" "深海军蓝 Canvas")
$(swatch 250 "#18212D" "表面 Surface")
$(swatch 440 "#54C7EB" "青蓝强调 · 深色")
$(swatch 630 "#0876A3" "深青强调 · 浅色")
$(swatch 820 "#B4F3FF" "高光青 Glow")
$(swatch 1010 "#F3F6FA" "浅色 Canvas")
$(swatch 1200 "#8FA3B8" "辅助文字")
</svg>
SVG
"$WORK/render" "$WORK/brand-sheet.svg" "$ROOT/preview/brand-sheet.png" 1600 1240 > /dev/null
echo "完成：$ROOT"
