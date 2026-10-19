#!/bin/sh
# 窗口图鉴 WindowAtlas 命令行安装脚本（随每个 GitHub Release 发布）。
#
#   curl -fsSL https://github.com/kaizaoji/WindowAtlas/releases/latest/download/install.sh | sh
#
# 流程：检查系统 → 从 GitHub Releases 下载 DMG 与 SHA-256 → 核对哈希 → 校验签名身份 → 安装到「应用程序」。
# 用 curl 下载的文件不带隔离标记，因此不会出现 Gatekeeper「无法验证开发者」提示；应用本身未经 Apple 公证，
# 本脚本不会去除任何隔离标记、不使用 sudo、不关闭正在运行的应用；替换的旧版本移到废纸篓，可随时恢复。
#
# 可选环境变量：
#   WINDOWATLAS_VERSION=0.9.2          安装指定版本（默认最新版本）
#   WINDOWATLAS_INSTALL_DIR=~/Applications  安装位置（默认 /Applications）
#   WINDOWATLAS_NO_OPEN=1              安装后不自动打开
#   WINDOWATLAS_DMG_URL / WINDOWATLAS_SHA256_URL  自定义下载地址（镜像或本地测试）
#
# 整个脚本包在 main 中，只有完整下载后才会执行，网络中断不会执行半截脚本。

main() {
  set -eu
  REPO="kaizaoji/WindowAtlas"
  BUNDLE_ID="com.kaizaoji.windowatlas"
  # 正式版本签名证书「WindowAtlas Release」的根证书哈希；签名身份不符的安装包一律拒绝。
  CERT_ROOT='certificate root = H"f919e2e10b63947f883087c6bae06b6a61bd2d76"'
  INSTALL_DIR="${WINDOWATLAS_INSTALL_DIR:-/Applications}"
  TARGET="$INSTALL_DIR/WindowAtlas.app"

  say() { printf '%s\n' "$*"; }
  fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

  say "窗口图鉴 WindowAtlas 安装程序 · https://github.com/$REPO"

  # 1. 系统检查
  [ "$(uname -s)" = "Darwin" ] || fail "仅支持 macOS。/ macOS only."
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ] || fail "仅支持 Apple 芯片（M 系列）Mac。/ Apple silicon Macs only."
  major=$(sw_vers -productVersion | cut -d. -f1)
  [ "$major" -ge 14 ] 2>/dev/null || fail "需要 macOS 14 或更高版本，当前为 $(sw_vers -productVersion)。/ Requires macOS 14 or later."
  [ -d "$INSTALL_DIR" ] || fail "安装位置不存在：$INSTALL_DIR"
  [ -w "$INSTALL_DIR" ] || fail "没有写入 $INSTALL_DIR 的权限。可改装到个人目录：WINDOWATLAS_INSTALL_DIR=\"\$HOME/Applications\""

  # 目标位置的窗口图鉴正在运行时不替换，避免打断正在保存的笔记。
  if ps -axo comm= | grep -Fxq "$TARGET/Contents/MacOS/WindowAtlas"; then
    fail "窗口图鉴正在运行，请先退出（菜单栏图标 → 退出），再重新运行安装命令。/ Please quit WindowAtlas first."
  fi

  # 2. 确定下载地址
  if [ -n "${WINDOWATLAS_DMG_URL:-}" ]; then
    dmg_url="$WINDOWATLAS_DMG_URL"
    sha_url="${WINDOWATLAS_SHA256_URL:-$dmg_url.sha256}"
  else
    if [ -n "${WINDOWATLAS_VERSION:-}" ]; then
      api="https://api.github.com/repos/$REPO/releases/tags/v${WINDOWATLAS_VERSION#v}"
    else
      api="https://api.github.com/repos/$REPO/releases/latest"
    fi
    json=$(curl -fsSL -H "Accept: application/vnd.github+json" "$api") || fail "无法读取发布信息：$api"
    dmg_url=$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*-apple-silicon\.dmg"' | head -n 1 | sed 's/.*"\(https:[^"]*\)"$/\1/')
    [ -n "$dmg_url" ] || fail "该版本没有 Apple 芯片安装包。"
    case "$dmg_url" in
      "https://github.com/$REPO/releases/download/"*) ;;
      *) fail "下载地址不在官方仓库内，已停止：$dmg_url" ;;
    esac
    sha_url="$dmg_url.sha256"
  fi

  # 3. 下载并核对 SHA-256
  work=$(mktemp -d -t windowatlas-install)
  mount="$work/mount"
  cleanup() {
    [ -d "$mount" ] && hdiutil detach "$mount" -quiet >/dev/null 2>&1 || true
    rm -rf "$work"
  }
  trap cleanup EXIT INT TERM
  dmg="$work/WindowAtlas.dmg"
  say "→ 下载 $dmg_url"
  curl -fL --progress-bar -o "$dmg" "$dmg_url" || fail "下载失败。"
  expected=$(curl -fsSL "$sha_url" | awk '{print $1; exit}') || fail "无法下载 SHA-256 文件：$sha_url"
  actual=$(shasum -a 256 "$dmg" | awk '{print $1}')
  printf '%s' "$expected" | grep -Eq '^[0-9a-f]{64}$' || fail "SHA-256 文件格式不正确。"
  [ "$expected" = "$actual" ] || fail "SHA-256 不一致，安装包可能已损坏或被篡改，已停止。（期望 ${expected}，实际 ${actual}）"
  say "✓ SHA-256 校验通过：$actual"

  # 4. 挂载并校验签名身份
  mkdir -p "$mount"
  hdiutil attach "$dmg" -nobrowse -readonly -noautoopen -mountpoint "$mount" -quiet || fail "无法打开安装包。"
  source_app="$mount/WindowAtlas.app"
  [ -d "$source_app" ] || fail "安装包中没有 WindowAtlas.app。"
  verify_app() {
    codesign --verify --deep --strict "$1" 2>/dev/null || fail "应用签名校验失败，已停止。"
    requirement=$(codesign -d -r- "$1" 2>&1)
    case "$requirement" in
      *"identifier \"$BUNDLE_ID\""*"$CERT_ROOT"*) ;;
      *) fail "应用签名身份与官方版本不符，已停止。" ;;
    esac
  }
  verify_app "$source_app"
  version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$source_app/Contents/Info.plist")
  build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$source_app/Contents/Info.plist")
  say "✓ 签名校验通过：WindowAtlas ${version}（build ${build}）"

  # 5. 安装：先完整复制并复核，再把旧版本移到废纸篓，最后放到正式位置。
  staging="$INSTALL_DIR/.WindowAtlas.app.installing"
  rm -rf "$staging"
  ditto "$source_app" "$staging" || fail "复制应用失败。"
  verify_app "$staging"
  if [ -e "$TARGET" ]; then
    old=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$TARGET/Contents/Info.plist" 2>/dev/null || echo old)
    trash="$HOME/.Trash/WindowAtlas-$old-$(date +%Y%m%d-%H%M%S).app"
    mv "$TARGET" "$trash" || { rm -rf "$staging"; fail "无法移动旧版本，未做任何更改。"; }
    say "✓ 旧版本 $old 已移到废纸篓：${trash##*/}"
  fi
  mv "$staging" "$TARGET" || fail "安装失败。"
  say "✓ 已安装到 $TARGET"
  say ""
  say "首次使用需在「系统设置 → 隐私与安全性」中开启「屏幕录制」与「辅助功能」，应用内会引导你完成。"
  say "升级时系统授权通常会保留。说明文档：https://github.com/$REPO#readme"

  if [ "${WINDOWATLAS_NO_OPEN:-0}" != "1" ]; then open "$TARGET"; fi
}

main "$@"
