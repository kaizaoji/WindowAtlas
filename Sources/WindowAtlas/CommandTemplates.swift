import Foundation

/// 首次建库的可编辑示例；只在用户尚无命令库时写入，不随版本覆盖。
enum CommandTemplates {
    static var entries: [CommandEntry] {
        let codex = URL(string: "https://learn.chatgpt.com/docs/reference/slash-commands")!
        let claude = URL(string: "https://code.claude.com/docs/en/commands")!
        return [
            CommandEntry(title: L("持续目标 · Goal"), tool: "Codex", command: "/goal",
                purpose: L("让 AI 围绕明确目标持续推进，适合需要多步实现与验收的任务。"),
                example: L("修复登录页在手机上的布局问题，保留现有登录逻辑，运行相关测试并展示验收结果。"),
                notes: L("在 Codex 应用输入框选择 /goal，再填写目标；可先用 /plan 明确方案。通过目标进度栏暂停、继续或清除。是否可用以当前版本菜单为准。"), sourceURL: codex),
            CommandEntry(title: L("先规划再实施"), tool: "Codex", command: "/plan",
                purpose: L("先梳理实施步骤、影响范围和验证方法。"),
                example: L("规划将命令库与项目笔记分离的实现步骤，列出数据兼容和验收要点。"),
                notes: L("先选择指令，再输入案例中的任务描述；它用于切换规划模式。"), sourceURL: codex),
            CommandEntry(title: L("检查代码变更"), tool: "Codex", command: "/review",
                purpose: L("审查未提交的改动或与基准分支比较，定位代码问题。"),
                example: L("重点检查保存失败、并发请求和窗口切换是否存在回归。"),
                notes: L("在 Codex 输入框选择 /review，并按界面选择检查范围。"), sourceURL: codex),
            CommandEntry(title: L("查看会话状态"), tool: "Codex", command: "/status",
                purpose: L("查看当前会话标识、上下文用量和速率限制。"),
                example: "/status", notes: L("在对应 AI 会话内使用，不是终端 shell 命令。"), sourceURL: codex),
            CommandEntry(title: L("定时检查 · Loop"), tool: "Claude Code", command: "/loop 5m 检查当前项目的构建是否结束，只报告状态，不修改文件。",
                purpose: L("在当前 Claude Code 会话中按间隔重复一个提示词。"),
                example: "/loop 10m 检查当前分支 CI 状态，汇报失败原因和下一步建议，不推送代码。",
                notes: L("5m 表示每五分钟；将示例中的任务替换为你的任务。需要会话保持运行。可用自然语言列出或取消定时任务；具体可用性以当前版本为准。"),
                sourceURL: URL(string: "https://code.claude.com/docs/en/scheduled-tasks")),
            CommandEntry(title: L("压缩长会话"), tool: "Claude Code", command: "/compact 保留当前目标、已完成事项、关键文件和待处理问题。",
                purpose: L("总结已有对话，减少上下文占用，继续当前工作。"),
                example: "/compact 重点保留数据库迁移约束、测试结果和未解决的问题。",
                notes: L("在 Claude Code 输入框使用。可在指令后写明需要保留的重点。"), sourceURL: claude)
        ]
    }
}
