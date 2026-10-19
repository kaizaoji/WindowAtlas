import AppKit
import ScriptingBridge

struct TerminalSessionSnapshot: Sendable {
    let id: String
    let tty: String
    let busy: Bool?
    let processing: Bool?
    let processes: [String]
}
struct TerminalWindowSnapshot: Sendable {
    let id: CGWindowID
    let sessions: [TerminalSessionSnapshot]
}
struct TerminalProcess: Sendable {
    let pid: Int, group: Int, foreground: Int
    let tty: String, state: String, command: String
    let cpu: Double
    var name: String { URL(fileURLWithPath: command).lastPathComponent.lowercased() }
    var isAgent: Bool { name == "codex" || name == "claude" || name == "claude-code" || name.hasPrefix("codex-") || command.lowercased().contains("/claude/versions/") }
    var isShell: Bool { ["zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "nu", "login", "-zsh", "-bash"].contains(name) }
    static func parse(_ line: String) -> TerminalProcess? {
        let parts = line.split(maxSplits: 7, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count == 8, let pid = Int(parts[0]), let group = Int(parts[1]), let foreground = Int(parts[2]) else { return nil }
        // Fields: pid, pgid, tpgid, tty, state, CPU time, elapsed time, executable (never arguments).
        let time = parts[5].split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
        return TerminalProcess(pid: pid, group: group, foreground: foreground, tty: parts[3], state: parts[4], command: parts[7], cpu: time)
    }
}

enum TerminalTaskKind: Int, Sendable {
    case unknown, idle, paused, command, agent, active, output
    var isRunning: Bool { [.command, .agent, .active, .output].contains(self) }
    var title: String {
        switch self {
        case .unknown: return L("任务状态未知")
        case .idle: return L("终端空闲")
        case .paused: return L("任务已暂停")
        case .command: return L("命令运行中")
        case .agent: return L("AI 会话运行中")
        case .active: return L("任务活跃")
        case .output: return L("任务有输出")
        }
    }
}
struct TerminalTaskStatus: Sendable {
    var kind: TerminalTaskKind
    var sampled: Date
    var activeAt: Date?
    var idleSince: Date?
    var sessions: Int
    var detail: String
    func isFresh(at now: Date) -> Bool { now.timeIntervalSince(sampled) <= 30 }
    func title(at now: Date) -> String {
        guard isFresh(at: now) else { return L("任务状态待刷新") }
        if kind == .idle, let idleSince {
            let minutes = Int(now.timeIntervalSince(idleSince) / 60)
            if minutes >= 1 { return L("已空闲 %d 分钟", minutes) }
        }
        return kind.title
    }
}
struct TerminalTaskEvaluator {
    static func normalizedTTY(_ value: String) -> String {
        let device = value.hasPrefix("/dev/") ? String(value.dropFirst(5)) : value
        return device.hasPrefix("tty") ? String(device.dropFirst(3)) : device
    }
    static func evaluate(session: TerminalSessionSnapshot, processes: [TerminalProcess], previousCPU: [Int: Double]) -> (TerminalTaskKind, [String]) {
        let tty = normalizedTTY(session.tty)
        guard !tty.isEmpty else { return (.unknown, []) }
        let attached = processes.filter { normalizedTTY($0.tty) == tty && !$0.state.contains("Z") }
        let agents = attached.filter(\.isAgent)
        let foreground = attached.filter { $0.foreground > 0 && $0.group == $0.foreground && !$0.isShell }
        let commands = foreground.isEmpty ? attached.filter { !$0.isShell } : foreground
        let tasks = agents.isEmpty ? commands : attached.filter { !$0.isShell }
        let names = Array(Set(tasks.map(\.name))).sorted()
        if !tasks.isEmpty && tasks.allSatisfy({ $0.state.contains("T") }) { return (.paused, names) }
        if !tasks.isEmpty {
            if session.processing == true { return (.output, names) }
            if tasks.contains(where: { process in
                guard let before = previousCPU[process.pid], process.cpu >= before else { return false }
                return process.cpu - before >= 0.05
            }) { return (.active, names) }
            return (agents.isEmpty ? .command : .agent, names)
        }
        // Terminal's own busy bit remains useful when process metadata is unavailable.
        let reported = session.processes.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }
        if reported.contains(where: { $0 == "codex" || $0 == "claude" || $0 == "claude-code" }) { return (.agent, reported) }
        if session.busy == true { return (session.processing == true ? .output : .command, reported) }
        if session.busy == false { return (.idle, []) }
        if !attached.isEmpty && attached.contains(where: { $0.foreground > 0 }) { return (.idle, []) }
        return (.unknown, [])
    }
}

enum TerminalTaskBridge {
    private static let queue = DispatchQueue(label: "WindowAtlas.TerminalTasks", qos: .utility)
    static let supported = ["com.apple.Terminal", "com.googlecode.iterm2"]
    private static func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    private final class EventErrors: NSObject, SBApplicationDelegate {
        var error: Error?
        func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? { self.error = error; return nil }
        func check() throws { if let error { throw error } }
    }
    private static func children(_ object: SBObject, _ kind: String, _ errors: EventErrors) throws -> [SBObject] {
        let result = object.elementArray(withCode: code(kind)).get() as? [SBObject] ?? []
        try errors.check(); return result
    }
    private static func value(_ object: SBObject, _ property: String, _ errors: EventErrors) throws -> Any? {
        let result = object.property(withCode: code(property)).get()
        try errors.check(); return result
    }
    static func snapshot(pid: pid_t, appID: String) async throws -> [TerminalWindowSnapshot] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { autoreleasepool {
                do {
                    guard let app = SBApplication(processIdentifier: pid) else { throw NSError(domain: "WindowAtlas.Terminal", code: -600) }
                    let errors = EventErrors(); app.delegate = errors; app.timeout = 5 * 60
                    let isTerminal = appID == "com.apple.Terminal"
                    var snapshots: [TerminalWindowSnapshot] = []
                    for window in try children(app, "cwin", errors) {
                        guard let windowID = try value(window, "ID  ", errors) as? NSNumber else { continue }
                        var sessions: [TerminalSessionSnapshot] = []
                        for (index, tab) in try children(window, isTerminal ? "ttab" : "Trmt", errors).enumerated() {
                            let entries = isTerminal ? [tab] : try children(tab, "Trms", errors)
                            for session in entries {
                                let tty = try value(session, isTerminal ? "ttty" : "Stty", errors) as? String ?? ""
                                let busy = isTerminal ? try (value(session, "busy", errors) as? NSNumber)?.boolValue : nil
                                let processing = !isTerminal ? try (value(session, "Prcs", errors) as? NSNumber)?.boolValue : nil
                                let names = isTerminal ? try value(session, "prcs", errors) as? [String] ?? [] : []
                                // Only read session metadata, never contents/history or command arguments.
                                sessions.append(TerminalSessionSnapshot(id: "\(windowID):\(index):\(tty)", tty: tty, busy: busy, processing: processing, processes: names))
                            }
                        }
                        snapshots.append(TerminalWindowSnapshot(id: windowID.uint32Value, sessions: sessions))
                    }
                    continuation.resume(returning: snapshots)
                } catch { continuation.resume(throwing: error) }
            } }
        }
    }
    static func processes() async throws -> [TerminalProcess] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let command = Process(); let pipe = Pipe()
                    command.executableURL = URL(fileURLWithPath: "/bin/ps")
                    command.arguments = ["-axo", "pid=,pgid=,tpgid=,tty=,stat=,time=,etime=,comm="]
                    command.standardOutput = pipe; command.standardError = FileHandle.nullDevice
                    try command.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile(); command.waitUntilExit()
                    guard command.terminationStatus == 0 else { throw NSError(domain: "WindowAtlas.Processes", code: Int(command.terminationStatus)) }
                    continuation.resume(returning: String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { TerminalProcess.parse(String($0)) })
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

@MainActor
extension WindowStore {
    func enableTerminalTasks(_ appID: String) {
        terminalEnabled.insert(appID)
        UserDefaults.standard.set(Array(terminalEnabled), forKey: "terminalTaskApps")
        terminalErrors.removeValue(forKey: appID)
        Task { await refreshTerminalTasks() }
    }
    func disableTerminalTasks(_ appID: String) {
        terminalEnabled.remove(appID)
        UserDefaults.standard.set(Array(terminalEnabled), forKey: "terminalTaskApps")
        terminalStatuses = terminalStatuses.filter { key, _ in windows.first(where: { $0.id == key })?.appID != appID }
    }
    func refreshTerminalTasks() async {
        guard !terminalFetching else { return }
        terminalFetching = true
        defer { terminalFetching = false }
        let targets = windows.filter { terminalEnabled.contains($0.appID) }
        guard !targets.isEmpty else { return }
        let now = Date()
        // CPU sampling is independent of captures, window visibility, selected category and scrolling.
        let processes = (try? await TerminalTaskBridge.processes()) ?? []
        var next: [CGWindowID: TerminalTaskStatus] = [:]
        for pid in Set(targets.map(\.pid)) {
            guard let item = targets.first(where: { $0.pid == pid }) else { continue }
            do {
                let snapshots = try await TerminalTaskBridge.snapshot(pid: pid, appID: item.appID)
                if terminalErrors[item.appID] != nil { terminalErrors.removeValue(forKey: item.appID) }
                for snapshot in snapshots {
                    // Exact ID+pid association only; never guess another terminal from similar titles.
                    guard windows.contains(where: { $0.pid == pid && $0.id == snapshot.id }) else { continue }
                    var kinds: [TerminalTaskKind] = []; var names: Set<String> = []
                    for session in snapshot.sessions {
                        let (kind, commands) = TerminalTaskEvaluator.evaluate(session: session, processes: processes, previousCPU: terminalPreviousCPU)
                        kinds.append(kind); names.formUnion(commands)
                    }
                    // Unknown sessions prevent claiming that the whole window is idle.
                    var kind = kinds.max(by: { $0.rawValue < $1.rawValue }) ?? .unknown
                    if kind == .idle && kinds.contains(.unknown) { kind = .unknown }
                    let old = terminalStatuses[snapshot.id]
                    let continuous = old?.isFresh(at: now) == true
                    let idleSince = kind == .idle ? (continuous && old?.kind == .idle ? old?.idleSince : now) : nil
                    let activeAt = [.active, .output].contains(kind) ? now : (continuous ? old?.activeAt : nil)
                    let detail = L("%d 个会话 · ", snapshot.sessions.count) + (names.isEmpty ? L("按终端会话与进程状态判断") : names.sorted().joined(separator: "、"))
                    next[snapshot.id] = TerminalTaskStatus(kind: kind, sampled: now, activeAt: activeAt, idleSince: idleSince, sessions: snapshot.sessions.count,
                        detail: detail + L("。AI 会话运行中表示进程仍在，不等于当前正在生成；精确等待输入状态尚不可用。"))
                }
            } catch {
                terminalErrors[item.appID] = (error as NSError).code == -1743 ? L("需要允许读取终端会话状态") : L("任务状态读取失败，请重试")
                // Disable automatic retries on permission/error; the user explicitly retries from the task menu.
                terminalEnabled.remove(item.appID)
                UserDefaults.standard.set(Array(terminalEnabled), forKey: "terminalTaskApps")
            }
        }
        terminalStatuses = next
        terminalPreviousCPU = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0.cpu) })
    }
    func terminalStatus(_ item: WindowItem) -> TerminalTaskStatus? { terminalStatuses[item.id] }
    func matchesTaskFilter(_ item: WindowItem) -> Bool {
        guard taskOnly else { return true }
        guard let status = terminalStatus(item), status.isFresh(at: Date()) else { return false }
        return status.kind.isRunning
    }
    func taskSortPriority(_ item: WindowItem) -> Int {
        guard let status = terminalStatus(item), status.isFresh(at: Date()) else { return 0 }
        return status.kind.isRunning ? 10 + status.kind.rawValue : status.kind.rawValue
    }
}
