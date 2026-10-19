# 窗口图鉴 WindowAtlas · 安装与使用说明

适用版本：0.9.x 起。系统要求：**macOS 14 或更高，Apple 芯片（M 系列）Mac**。Intel Mac 暂不支持。

## 1. 下载与校验

1. 从 [GitHub Releases](https://github.com/kaizaoji/WindowAtlas/releases) 下载 `WindowAtlas-<版本>-apple-silicon.dmg`。
2. （建议）校验文件完整：在「终端」中执行下面的命令，结果应与发布页给出的 SHA-256 完全一致。

   ```sh
   shasum -a 256 ~/Downloads/WindowAtlas-<版本>-apple-silicon.dmg
   ```

## 2. 安装

**方式一：DMG**

1. 双击打开 DMG，把「WindowAtlas」拖到旁边的「应用程序」文件夹。
2. 推出 DMG。

**方式二：命令行一键安装（跳过第 1 节和第 3 节）**

在「终端」中执行：

```sh
curl -fsSL https://github.com/kaizaoji/WindowAtlas/releases/latest/download/install.sh | sh
```

脚本会检查系统、下载最新版本、核对 SHA-256、校验应用签名是否为官方证书，再安装到「应用程序」；已有旧版本时移到废纸篓（可恢复）。安装前请先退出正在运行的窗口图鉴。脚本内容可先在浏览器中打开上面的地址查看。

- 指定版本：`curl -fsSL …/install.sh | WINDOWATLAS_VERSION=0.9.2 sh`
- 装到个人目录：`curl -fsSL …/install.sh | WINDOWATLAS_INSTALL_DIR="$HOME/Applications" sh`

> 为什么命令行安装不会出现「无法验证开发者」：macOS 只对浏览器等程序下载、带有「隔离标记」的文件做 Gatekeeper 检查，`curl` 下载的文件没有这个标记。脚本不会去除任何标记、不使用管理员权限；应用本身仍**未经 Apple 公证**，安全性依赖你对本仓库与签名证书的信任，脚本的哈希与签名校验就是为此而设。屏幕录制、辅助功能等系统授权仍需按第 4 节开启。

## 3. 首次打开（必读）

窗口图鉴目前**未经过 Apple 公证**（个人开发者暂未加入 Apple 付费开发者计划）。第一次打开时，macOS 会提示「无法验证开发者」或「Apple 无法检查其是否包含恶意软件」，这是系统对未公证应用的正常拦截：

1. 在「应用程序」中双击 WindowAtlas，看到提示后点「完成」或「取消」。
2. 打开「系统设置 → 隐私与安全性」，向下滚动到「安全性」部分，会看到「已阻止使用“WindowAtlas”」，点「**仍要打开**」。
3. 输入登录密码确认，再点「打开」。之后即可正常启动，不会再次提示。

> 不需要、也不建议关闭 Gatekeeper 或修改系统安全设置。如果提示「已损坏，无法打开」，请重新下载并核对 SHA-256；仍有问题请在 GitHub Issues 反馈。

## 4. 系统授权

首次启动会显示引导页，逐项完成：

| 授权 | 用途 | 位置 |
|---|---|---|
| 屏幕录制 | 显示各应用窗口的缩略图 | 系统设置 → 隐私与安全性 → 屏幕录制（部分系统版本名为「屏幕与系统音频录制」）；引导页的「去授权」会直接打开该页面 |
| 辅助功能 | 点击缩略图切换窗口，摆放、最小化、关闭窗口 | 系统设置 → 隐私与安全性 → 辅助功能 |
| 自动化（可选） | 读取 Chrome、Edge、Safari 标签页；读取 Terminal / iTerm2 的会话状态 | 首次在应用内启用时系统弹窗询问 |

- 打开屏幕录制开关后，通常需要**退出并重新打开**窗口图鉴（引导页有按钮）。
- 开关已打开但应用仍显示未开启：在对应列表中选中 WindowAtlas，点「−」移除，再点「+」从「应用程序」中重新添加。
- 终端状态只读取会话编号、TTY 和进程信息，**不读取终端内容、不执行命令**。

## 5. 升级

1. 在窗口图鉴菜单中选择「退出窗口图鉴」。
2. 用新版本 DMG 覆盖安装到「应用程序」，或再次运行第 2 节的一键安装命令。
3. 打开新版本。由于未公证，可能需要再次在「隐私与安全性」中点「仍要打开」；系统也可能要求重新授权屏幕录制和辅助功能，按第 4 节操作即可。

笔记、命令库和设置会保留，不受升级影响。从 0.9.1 及更早版本升级时，旧设置会在首次启动时自动迁移。

> **从 0.9.1 及更早的内部测试版升级**：应用的签名身份已变更，系统设置里看到的「WindowAtlas」开关可能仍属于旧版本，打开后应用依然显示未授权。请在「屏幕录制」（以及「辅助功能」，如同样未识别）列表中选中 WindowAtlas，点「−」移除，再点「+」从「应用程序」重新添加，然后在应用中点「退出并重新打开」。此后的正式版本使用同一签名，升级不会再出现这种情况。

## 6. 数据位置

| 内容 | 位置 |
|---|---|
| 项目笔记（Markdown）与图片 | `~/Library/Application Support/WindowAtlas/Notes/` |
| 快捷命令库 | `~/Library/Application Support/WindowAtlas/Commands/` |
| 恢复前自动保存的副本 | `~/Library/Application Support/WindowAtlas/Notes/restore-backups/` |
| 设置 | `~/Library/Preferences/com.kaizaoji.windowatlas.plist` |

窗口缩略图只在内存中处理，不保存到磁盘。

## 7. 备份、恢复与换机

- **备份**：项目笔记 → 云盘图标 → 添加备份位置（Google Drive、iCloud 云盘、本地文件夹或移动硬盘均可，可同时添加多个），点「立即备份」或开启每 10 分钟自动备份。标记为「敏感 · 不备份」的笔记不会写入备份位置。
- **写入云盘目录 ≠ 上传完成**：何时同步到云端由 Google Drive / iCloud 客户端决定。
- **恢复**：在快照列表中点「恢复…」。应用会先校验快照完整性，确认后按笔记合并（覆盖同一笔记、新增缺少的笔记，备份里没有的本地笔记保留），并在恢复前自动保存当前笔记库。
- **换机**：旧电脑「导出备份文件…」得到一个 .zip（导出时可选择是否包含敏感笔记，默认不包含）；新电脑安装后「导入备份…」选择该 .zip，或直接选择云盘中的「WindowAtlas 笔记备份」文件夹。
- 快捷命令库目前**不包含**在笔记备份与导出中，换机时如需保留，请手动复制 `~/Library/Application Support/WindowAtlas/Commands/`。

### 恢复失败后的手动复原

如果恢复时提示「未能确认回滚完成」，说明自动回滚没能确认成功。你的原笔记完整保存在提示中给出的「恢复前备份」目录里，按以下步骤手动复原：

1. 退出窗口图鉴。
2. 在访达中按 ⇧⌘G，前往提示中的目录（形如 `~/Library/Application Support/WindowAtlas/Notes/restore-backups/<时间>/notes`）。
3. 把该 `notes` 文件夹中的全部内容复制到 `~/Library/Application Support/WindowAtlas/Notes/notes/`，遇到同名文件选择「替换」。
4. 重新打开窗口图鉴，核对笔记。

## 8. 卸载

1. 退出窗口图鉴，把「应用程序」中的 WindowAtlas 移到废纸篓。
2. （可选）删除数据：上表中的 `WindowAtlas` 文件夹与设置文件。**删除前请确认已备份需要的笔记。**
3. （可选）清除系统授权记录，在「终端」中执行：

   ```sh
   tccutil reset ScreenCapture com.kaizaoji.windowatlas
   tccutil reset Accessibility com.kaizaoji.windowatlas
   tccutil reset AppleEvents com.kaizaoji.windowatlas
   ```

## 9. 反馈

问题与建议请提交到 [GitHub Issues](https://github.com/kaizaoji/WindowAtlas/issues)，附上 macOS 版本、窗口图鉴版本（主窗口左下角）与复现步骤。请勿在反馈中粘贴笔记里的密钥、密码等敏感内容。

## 10. 许可证

窗口图鉴以 MIT 许可证开源，可免费用于个人或商业用途，分发时须保留版权与许可声明；软件按「原样」提供、不附带任何担保。许可全文位于应用内 `WindowAtlas.app/Contents/Resources/LICENSE`、DMG 中的 `LICENSE.txt` 与 GitHub 仓库根目录的 LICENSE。

---

## English quick guide

- Requires **macOS 14+ on Apple silicon**. Intel Macs are not supported yet.
- Install from the Terminal (no Gatekeeper prompt, because files downloaded with `curl` carry no quarantine flag; the script verifies the SHA-256 and the signing certificate): `curl -fsSL https://github.com/kaizaoji/WindowAtlas/releases/latest/download/install.sh | sh`
- Or drag WindowAtlas from the DMG into Applications. The app is **not notarized**: on first launch macOS will block it — open *System Settings → Privacy & Security* and click **Open Anyway**, then confirm. Do not disable Gatekeeper.
- Grant **Screen Recording** (thumbnails) and **Accessibility** (switching and placing windows). Quit and reopen after enabling Screen Recording. If a switch is on but not recognized, remove WindowAtlas from the list with “−” and add it again with “+”.
- Notes live in `~/Library/Application Support/WindowAtlas/Notes/`; the command library in `…/WindowAtlas/Commands/` (not included in note backups). Thumbnails are never written to disk.
- License: MIT — free for personal and commercial use; keep the copyright and license notice when redistributing; provided “as is” without warranty. See `LICENSE` in the repository or `WindowAtlas.app/Contents/Resources/LICENSE`.
- Uninstall: move the app to the Trash; optionally delete the folders above and run `tccutil reset ScreenCapture|Accessibility|AppleEvents com.kaizaoji.windowatlas`.


## 列表与多屏操作

列表模式下单击选中，双击或按回车打开原窗口；上下/左右方向键选择上一项或下一项，长列表自动滚动。列表与预览模式同时更新右侧预览。搜索框内方向键仍用于编辑。

点击窗口卡片的「调整窗口位置」，在「显示器」中选择目标屏幕，再选择半屏、九宫格或铺满。窗口尺寸受目标应用自身最小/最大尺寸限制时会显示提示。


缩略图模式同样支持键盘：左右移动一项，上下移动一行；单击选中、双击或回车打开。列表及缩略图中 Home/End 跳到首尾，Esc 清除选择（紧凑键盘可使用 Fn+左/右实现 Home/End）。
