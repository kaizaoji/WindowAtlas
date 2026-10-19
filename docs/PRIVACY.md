# 窗口图鉴 WindowAtlas 隐私说明

生效日期：2026-10-19。适用于 macOS 应用「窗口图鉴 WindowAtlas」（Bundle ID `com.kaizaoji.windowatlas`）。

## 一句话

窗口图鉴是完全在你的 Mac 本机运行的工具：**没有账号、没有服务器、不收集任何个人信息，也不包含统计、广告、崩溃上报或自动更新组件。**

## 应用会读取什么、用来做什么

| 数据 | 用途 | 处理方式 |
|---|---|---|
| 各应用窗口的画面（需屏幕录制授权） | 生成窗口缩略图 | 只在内存中处理，**不保存到磁盘、不上传**；退出应用即释放 |
| 窗口标题、应用名称、位置尺寸 | 分类、搜索、排序、摆放窗口 | 本机内存；首次发现时间、收藏、排序偏好保存在本机设置中 |
| 辅助功能接口（需辅助功能授权） | 把你点击的窗口切到前台，摆放、最小化、关闭窗口 | 只对你操作的窗口执行；不读取窗口内的文字内容 |
| Chrome、Edge、Safari 标签页标题与网址（可选，需自动化授权，按浏览器分别开启） | 在应用内列出、搜索、切换、关闭标签页 | 本机内存，不上传；可随时在应用中停止读取 |
| Terminal / iTerm2 会话编号、TTY 与进程状态（可选，需自动化授权） | 显示终端任务是否在运行、是否空闲 | **不读取终端内容、不执行任何命令**；本机内存 |
| 你写的项目笔记、图片与快捷命令 | 笔记与命令库功能 | 保存在 `~/Library/Application Support/WindowAtlas/`，仅你本人可见 |

## 数据会离开你的 Mac 吗

- 应用自身**不会发起任何网络请求**。
- **笔记备份**只在你主动添加备份位置后进行，写入你选择的文件夹。如果该文件夹是 Google Drive、iCloud 云盘等同步目录，同步由对应的云盘客户端完成，受其服务条款约束；窗口图鉴不接触你的云盘账号。
- 标记为「敏感 · 不备份」的笔记不会写入任何备份位置。**主动导出迁移包（.zip）时**，你可以自行选择是否包含敏感笔记（默认不包含）；导出文件的保存与传递由你决定。
- 应用中的「获取更多」及命令来源等链接，只有在你点击时才会用浏览器打开对应网页。

## 敏感信息提醒

保存笔记时，应用会在本机检测常见的密钥格式（如 API Key、Token、私钥）并给出提醒，检测结果不会离开本机，也不会自动更改你的备份设置。

## 你的控制权

- 可随时在「系统设置 → 隐私与安全性」中撤销屏幕录制、辅助功能与自动化授权。
- 删除应用及 `~/Library/Application Support/WindowAtlas/` 即可清除全部数据，详见 [安装与使用说明](INSTALL.md) 的「卸载」一节。

## 变更

本说明如有变化，将随新版本一同发布，并在发布说明中注明。

## 联系

问题与建议请通过项目的 GitHub Issues 反馈。

---

## Privacy (English summary)

WindowAtlas runs entirely on your Mac. It has **no account, no server, no analytics, no ads, no crash reporting and no auto-updater, and it makes no network requests of its own.** Window previews (including the last-seen picture of browser tabs) are processed in memory and never written to disk or uploaded. Accessibility is used only to act on windows you choose. Optional Chrome, Edge, Safari and Terminal/iTerm2 automation reads tab titles/URLs and session status (never terminal contents) locally. Notes and commands are stored in `~/Library/Application Support/WindowAtlas/`. Note backups are written only to folders you add; cloud sync of those folders is handled by your cloud provider. Notes marked "Sensitive · No backup" are excluded from backups; when you explicitly export a migration .zip you may choose to include them (off by default).
