# 窗口图鉴 WindowAtlas · 命名与产品文案

日期：2026-10-18，对应版本 0.9.1。本文是对外介绍、发布、网站与应用商店文案的统一来源；功能描述均以已实现能力为准，新增或调整功能后同步更新。

## 1. 命名

| 项目 | 定名 |
|---|---|
| 中文名 | **窗口图鉴** |
| 英文名 | **WindowAtlas**（连写，W 与 A 大写，不加空格） |
| 组合写法 | 窗口图鉴 WindowAtlas；中英并列时中文在前 |
| 可执行文件 / 安装包 | `WindowAtlas.app` |
| 系统显示名（进程、活动监视器、程序坞、权限列表） | `WindowAtlas`（0.9.2 build 40 起；应用内界面仍用中文名「窗口图鉴」） |
| Bundle ID | `com.kaizaoji.windowatlas`（0.9.2 起；更早的内部测试版设置会在首次启动时自动迁移，系统授权需重新设置一次） |

**命名理由**

- **图鉴**：像翻看图鉴一样，用大缩略图把所有窗口按应用分门别类摆开，看内容就知道是哪个窗口。这比「切换器」「管理器」更能说明它「先看清、再点到」的核心体验。
- **Atlas**：地图集，寓意把散落在各个桌面、层层叠叠的窗口收进一张全局总览图；也和 logo「层叠聚焦」呼应。
- **辨识度**：同类 macOS 工具多叫 Rectangle、Magnet、yabai、WindowSwitcher、WindowShelf，偏「布局 / 切换 / 收纳」；WindowAtlas 强调「总览 + 图鉴」，不与它们混淆。2026-10-18 网页检索未发现同名窗口管理产品；正式商用前仍建议做商标与应用商店重名检索。

**不建议的叫法**：窗口管理器（太泛）、窗口切换器（只覆盖一个功能）、终端管理器（产品不局限于终端）、Window Atlas（加空格）、Windows Atlas（易误解为 Windows 平台）。

## 2. 口号

| 用途 | 中文 | English |
|---|---|---|
| 主口号（应用内已使用） | 所有窗口，一个工作台 | Every window, one workspace |
| 体验口号 | 看得见内容，点得到窗口 | See it. Click it. Be there. |
| 场景口号（AI 编程） | 多个 Codex、Claude Code 同时开，也不再找窗口 | Run every coding agent. Never lose a window. |

## 3. 一句话介绍

- **中文（30 字内）**：原生 macOS 跨应用窗口工作台，用大缩略图看清并切换每个窗口。
- **English**：A native macOS workspace that shows every window as a live-ish thumbnail and takes you there in one click.

## 4. 短描述（GitHub 简介、应用商店副标题、社交平台）

**中文（约 80 字）**
窗口图鉴是原生 macOS 跨应用窗口工作台：按应用分类的大缩略图看板与常驻侧栏，一键回到真实窗口；附带终端任务状态、窗口九宫格摆放、快捷命令库与项目笔记。预览只在本机处理。

**English (~200 characters)**
WindowAtlas is a native macOS window workspace: big per-app thumbnail boards and an always-on sidebar take you straight to the real window, plus terminal task status, grid placement, a command library and project notes. Previews stay on your Mac.

## 5. 完整介绍（官网、发布页、应用商店描述）

### 中文

同时开着多个 Codex、Claude Code、Terminal、iTerm2、浏览器和 Finder，窗口越叠越乱，想找的那个总被压在最下面？

窗口图鉴把桌面上所有打开的窗口，像图鉴一样按应用分门别类摆在一个工作台里。左侧是分类和应用列表，右侧是可自由调整大小的窗口缩略图网格；看内容、看标题，点一下就回到那个真实窗口，正在运行的会话不会被打断。

**看清每一个窗口**
- 全部窗口、收藏、终端、浏览器与各应用独立分类，应用顺序可拖动调整。
- 缩略图、列表、列表与大预览三种排列，每个应用分别记住视图、尺寸与排序。
- 常驻缩略图侧栏可跨桌面空间显示；关掉主看板，侧栏照样可用。
- Google Chrome 可展开全部窗口里的标签页，按标题和网址搜索、切换、关闭。

**更懂 AI 编程的终端**
- 启用后，Terminal 与 iTerm2 即使在后台，也能显示命令或 AI 会话是否在运行、近期是否有输出或活动、是否暂停及空闲了多久。
- 支持「只看有任务」与「任务优先」排序，一眼找到还在跑的会话。
- 只读取会话编号、TTY 与进程元数据，不读取终端内容，也不执行任何命令。

**一键摆好窗口**
- 右键窗口即可使用九宫格摆放，也可选半屏、居中、铺满、还原，并支持多显示器。

**命令和笔记随手可查**
- 快捷命令库按 Codex、Claude Code 与自定义工具分类，记录指令、用途和案例，⌘K 随时搜索复制。
- 项目笔记使用 Markdown，支持多级目录与子笔记、代码块一键复制、图片，以及导入 Markdown、JSON、代码、Word、HTML、PDF。
- 可同时备份到 Google Drive、iCloud 云盘、本地磁盘或移动硬盘；导出 .zip 后可在另一台 Mac 上导入。标记为「敏感 · 不备份」的笔记不进入任何备份位置；主动导出迁移包时可自行选择是否包含（默认不包含）。

**为你的隐私设计**
- 窗口预览只在本机内存中处理，不上传，也不保存截图文件。
- 没有账号，没有云服务，没有第三方依赖。

支持浅色、深色和跟随系统外观，提供简体中文与 English 界面。需要 macOS 14 或更高版本，支持 Apple 芯片 Mac。

### English

Running several coding agents, terminals, browsers and Finder windows at once — and the one you need is always buried at the bottom?

WindowAtlas lays out every open window like an atlas, organized by app in one workspace. Pick a category or app on the left and browse resizable window thumbnails on the right. Recognize a window by its content, click it, and you are back in the real window — running sessions are never interrupted.

**See every window**
- Categories for all windows, favorites, terminals, browsers and each app; drag to reorder apps.
- Grid, list, or list with a large preview; each app remembers its own layout, size and sort order.
- An always-on thumbnail sidebar that follows you across Spaces and keeps working when the main board is closed.
- Expand Google Chrome into all of its tabs across windows; search by title or URL, switch or close.

**A terminal view built for AI coding**
- When enabled, Terminal and iTerm2 show whether a command or AI session is running, has recent output or activity, is paused, or how long it has been idle — even in the background.
- Filter to windows with tasks, or sort tasks first.
- Reads only session IDs, TTYs and process metadata; never terminal contents, and never runs commands.

**Place windows in one click**
- Right-click any window for a 3×3 placement grid, halves, center, fill or restore, with multi-display support.

**Commands and notes at hand**
- A command library organized by Codex, Claude Code and custom tools, with purpose and examples; press ⌘K to search and copy.
- Markdown project notes with nested folders and sub-notes, one-click code copying, images, and import from Markdown, JSON, code, Word, HTML and PDF.
- Back up to Google Drive, iCloud Drive, a local disk or an external drive at the same time, or export a .zip to move to another Mac. Notes marked "Sensitive · No backup" are excluded from every backup location; when you export a migration .zip you can choose whether to include them (off by default).

**Private by design**
- Window previews are processed in memory on your Mac; nothing is uploaded and no screenshots are saved.
- No account, no cloud service, no third-party dependencies.

Light, dark and system appearance; Simplified Chinese and English. Requires macOS 14 or later on Apple silicon.

## 6. 核心卖点（演示、海报、发布页四格）

| 卖点 | 中文 | English |
|---|---|---|
| 看板 | 大缩略图看板，按应用分类，看内容找窗口 | Thumbnail boards by app — find windows by what's in them |
| 侧栏 | 常驻缩略图侧栏，跨桌面始终在手边 | An always-on sidebar across Spaces |
| 终端 | 后台终端也能看到任务与 AI 会话状态，不读终端内容 | Task and AI-session status for background terminals, without reading their contents |
| 命令笔记 | ⌘K 命令库 + Markdown 项目笔记，多处备份 | ⌘K command library and Markdown notes with multi-location backup |

## 7. 目标用户与场景

- **AI 编程开发者**：同时运行多个 Codex / Claude Code / 终端会话，需要快速找到并回到正在跑的那个。
- **多窗口重度用户**：同时开着大量浏览器、Finder 和工具窗口，希望像 Finder 一样按应用整理和浏览窗口。
- **需要沉淀常用命令的人**：繁琐命令记不住，想在工作台里随手记录、搜索、复制。

## 8. 关键词

- **App Store 关键词（100 字符内）**：窗口管理,窗口切换,缩略图,工作台,侧栏,终端,iTerm2,AI编程,Codex,Claude,命令,笔记,分屏,效率
- **英文关键词**：window manager, window switcher, thumbnails, workspace, sidebar, terminal, iTerm2, AI coding, Codex, Claude Code, command library, notes, tiling, productivity
- **GitHub Topics**：`macos` `swift` `swiftui` `window-manager` `screencapturekit` `accessibility` `productivity` `terminal` `ai-coding` `markdown-notes`

## 9. 隐私与权限说明（对外统一口径）

- **屏幕录制**：仅用于在本机显示窗口缩略图；预览只在内存中，不上传、不落盘。
- **辅助功能**：用于把你点击的窗口切换到前台，以及调整位置、最小化、关闭。
- **自动化（可选）**：读取 Chrome 标签页；读取 Terminal / iTerm2 的会话编号、TTY 与运行状态。不读取终端内容，不执行命令。
- **笔记备份（可选）**：只写入你选择的目录；写入云盘同步目录后，何时上传由云盘客户端决定。

## 10. 用语规范

| 统一用 | 不要用 |
|---|---|
| 窗口看板 / 主看板 | 主界面、监控面板 |
| 常驻侧栏 | 悬浮窗、小窗 |
| 快捷命令库（Command Library） | 命令管理、脚本库 |
| 项目笔记（Project Notes） | 记事本、知识库 |
| 任务状态 / AI 会话运行中 | AI 正在写代码、实时监控 AI（无法精确判断生成或等待输入） |
| 缩略图每 6 秒更新 | 实时预览、视频直播 |
| 窗口预览只在本机处理 | 录屏、截屏保存 |

## 11. 系统要求与当前状态

- macOS 14 或更高，仅支持 Apple 芯片（首发不提供 Intel 版本）；已在 macOS 26.4 实测，macOS 14 尚未实测。
- 通过 GitHub Releases 以 DMG 分发，**未经 Apple 公证**（暂无 Apple 付费开发者账号），首次打开需在「隐私与安全性」中点「仍要打开」，详见 `docs/INSTALL.md`。对外宣传不得暗示已通过 Apple 审核或公证。
