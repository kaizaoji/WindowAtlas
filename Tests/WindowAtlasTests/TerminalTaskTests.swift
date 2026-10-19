import XCTest
@testable import WindowAtlas

final class TerminalTaskTests: XCTestCase {
    private func session(_ tty: String = "/dev/ttys001", busy: Bool? = nil, processing: Bool? = nil, names: [String] = []) -> TerminalSessionSnapshot {
        TerminalSessionSnapshot(id: "test", tty: tty, busy: busy, processing: processing, processes: names)
    }
    private func process(_ name: String = "codex", tty: String = "ttys001", cpu: Double = 10, state: String = "S+", pid: Int = 100, group: Int = 100, foreground: Int = 100) -> TerminalProcess {
        TerminalProcess(pid: pid, group: group, foreground: foreground, tty: tty, state: state, command: name, cpu: cpu)
    }
    func testBackgroundAgentNeedsNoScreenshotOrVisibleWindow() {
        XCTAssertEqual(TerminalTaskEvaluator.evaluate(session: session(), processes: [process()], previousCPU: [:]).0, .agent)
    }
    func testOutputAndCPUAreActivitySignalsNotAgentPresenceAlone() {
        let agent = process()
        XCTAssertEqual(TerminalTaskEvaluator.evaluate(session: session(processing: true), processes: [agent], previousCPU: [:]).0, .output)
        XCTAssertEqual(TerminalTaskEvaluator.evaluate(session: session(), processes: [agent], previousCPU: [100: 9]).0, .active)
        XCTAssertEqual(TerminalTaskEvaluator.evaluate(session: session(), processes: [agent], previousCPU: [100: 10]).0, .agent)
    }
    func testDarwinPSAbbreviatedTTYMatchesTerminalDevice() {
        XCTAssertEqual(TerminalTaskEvaluator.evaluate(session: session(), processes: [process(tty: "s001")], previousCPU: [:]).0, .agent)
    }
    func testOtherTerminalCannotSupplyRunningStatus() {
        XCTAssertEqual(TerminalTaskEvaluator.evaluate(session: session(busy: false), processes: [process(tty: "ttys999")], previousCPU: [:]).0, .idle)
    }
    func testMissingMetadataNeverClaimsIdle() {
        XCTAssertEqual(TerminalTaskEvaluator.evaluate(session: session(), processes: [], previousCPU: [:]).0, .unknown)
    }
    func testPromptVersusCommandAndStoppedProcess() {
        XCTAssertEqual(TerminalTaskEvaluator.evaluate(session: session(), processes: [process("/bin/zsh")], previousCPU: [:]).0, .idle)
        XCTAssertEqual(TerminalTaskEvaluator.evaluate(session: session(busy: true), processes: [], previousCPU: [:]).0, .command)
        XCTAssertEqual(TerminalTaskEvaluator.evaluate(session: session(), processes: [process(state: "T")], previousCPU: [:]).0, .paused)
    }
    func testBackgroundCommandDoesNotDisappearAtShellPrompt() {
        let background = process("python3", group: 101, foreground: 200)
        XCTAssertEqual(TerminalTaskEvaluator.evaluate(session: session(), processes: [background, process("zsh", pid: 200, group: 200, foreground: 200)], previousCPU: [:]).0, .command)
    }
    func testZombieAgentDoesNotCountAsRunning() {
        XCTAssertEqual(TerminalTaskEvaluator.evaluate(session: session(busy: false), processes: [process(state: "Z")], previousCPU: [:]).0, .idle)
    }
    func testParseMetadataPreservesExecutableWithSpaces() {
        let parsed = TerminalProcess.parse(" 123 100 100 ttys001 S+ 1:02.50 02:10 /Applications/Some App/claude")
        XCTAssertEqual(parsed?.command, "/Applications/Some App/claude")
        XCTAssertEqual(parsed?.cpu, 62.5)
        XCTAssertEqual(parsed?.isAgent, true)
        XCTAssertNil(TerminalProcess.parse("invalid data"))
    }
    func testIdleDurationAndExpiredStatus() {
        let now = Date()
        let status = TerminalTaskStatus(kind: .idle, sampled: now, idleSince: now.addingTimeInterval(-600), sessions: 1, detail: "")
        XCTAssertEqual(status.title(at: now), "已空闲 10 分钟")
        XCTAssertEqual(status.title(at: now.addingTimeInterval(31)), "任务状态待刷新")
        XCTAssertFalse(TerminalTaskKind.paused.isRunning)
    }
}
