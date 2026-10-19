#!/bin/zsh
# 发布打包：Release 构建 → 签名 → DMG（应用 + 「应用程序」快捷方式 + 安装说明）→ 可选公证 → 校验 → SHA-256。
# 用法：
#   zsh scripts/release.sh                                   # ad hoc 签名，仅供本机或内测
#   SIGN_IDENTITY="WindowAtlas Release" zsh scripts/release.sh   # 固定自签名证书，升级后系统授权可保留
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=windowatlas zsh scripts/release.sh
#     # 正式签名 + 公证；NOTARY_PROFILE 需先由本人执行 xcrun notarytool store-credentials 保存到钥匙串
set -euo pipefail
cd "${0:A:h:h}"
# 未指定时优先使用固定的自签名证书「WindowAtlas Release」：签名身份不变，用户升级后系统授权可保留。
if [[ -z "${SIGN_IDENTITY:-}" ]] && security find-certificate -c "WindowAtlas Release" >/dev/null 2>&1; then
  SIGN_IDENTITY="WindowAtlas Release"
fi
export SIGN_IDENTITY="${SIGN_IDENTITY:--}"
[[ "$SIGN_IDENTITY" == "-" ]] && echo "提示：使用 ad hoc 签名，用户每次升级都需重新授权。" >&2

zsh scripts/build.sh
APP="dist/WindowAtlas.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
ARCHS=$(lipo -archs "$APP/Contents/MacOS/WindowAtlas")
[[ "$ARCHS" == "arm64" ]] || { echo "首发仅支持 Apple Silicon，但二进制架构为：$ARCHS" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

DMG="dist/WindowAtlas-$VERSION-apple-silicon.dmg"
STAGE="$(mktemp -d -t windowatlas-dmg)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/WindowAtlas.app"
ln -s /Applications "$STAGE/Applications"
[[ -f docs/INSTALL.md ]] && cp docs/INSTALL.md "$STAGE/安装说明.md"
cp "$APP/Contents/Resources/LICENSE" "$STAGE/LICENSE.txt" 2>/dev/null || echo "提示：应用内缺少 LICENSE，DMG 未附带许可文本。" >&2
hdiutil create -volname "WindowAtlas $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" > /dev/null

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  DMG_TIMESTAMP=(--timestamp=none)
  [[ "$SIGN_IDENTITY" == *"Developer ID"* ]] && DMG_TIMESTAMP=(--timestamp)
  codesign --force --sign "$SIGN_IDENTITY" "${DMG_TIMESTAMP[@]}" "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

hdiutil verify "$DMG" > /dev/null
(cd dist && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256")
# 命令行安装脚本随每个 Release 一起上传：releases/latest/download/install.sh 始终指向最新版本。
cp scripts/install.sh dist/install.sh
echo "完成：$DMG（$VERSION，build $BUILD，$ARCHS，签名：$SIGN_IDENTITY）"
echo "SHA-256：$(cut -d' ' -f1 "$DMG.sha256")"
echo "上传到 GitHub Release（标签 v$VERSION）：${DMG:t}、${DMG:t}.sha256、install.sh"
# Gatekeeper 评估仅供参考：未公证的包会显示 rejected，用户需在「隐私与安全性」中点「仍要打开」。
spctl --assess --type execute --verbose=2 "$APP" 2>&1 | sed 's/^/Gatekeeper：/' || true
