import AppKit
import ApplicationServices

/// 桌面空间（Space）支持。macOS 没有公开接口，这里在运行时从 SkyLight 动态查找私有函数（AltTab 等窗口工具同样使用）；
/// 找不到时所有能力返回「不可用」，应用退回到只列出当前桌面窗口的行为，不会因此启动失败。
/// 风险：系统升级可能改变这些私有函数的行为，升级 macOS 后需复测「其他桌面窗口的显示与切换」。
enum SpaceSupport {
    private typealias MainConnection = @convention(c) () -> UInt32
    private typealias CopyDisplaySpaces = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let skyLight, let pointer = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
    private static let mainConnection = symbol("SLSMainConnectionID", as: MainConnection.self)
    private static let copyDisplaySpaces = symbol("SLSCopyManagedDisplaySpaces", as: CopyDisplaySpaces.self)
    private static let copySpacesForWindows = symbol("SLSCopySpacesForWindows", as: CopySpacesForWindows.self)
    private static let setFrontProcess = symbol("_SLPSSetFrontProcessWithOptions", as: SetFrontProcess.self)
    // GetProcessForPID 在 Swift 中被标为不可用，但系统仍提供；同样运行时查找。
    private typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private static let processForPID: ProcessForPID? = {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let pointer = dlsym(handle, "GetProcessForPID") else { return nil }
        return unsafeBitCast(pointer, to: ProcessForPID.self)
    }()

    static var isAvailable: Bool { mainConnection != nil && copyDisplaySpaces != nil && copySpacesForWindows != nil }

    /// 各显示器当前显示的桌面编号（「显示器使用独立空间」时每块屏各有一个）。
    static func currentSpaceIDs() -> Set<UInt64> {
        guard let mainConnection, let copyDisplaySpaces,
              let displays = copyDisplaySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return Set(displays.compactMap { (($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value })
    }

    /// 位于其他（当前未显示的）桌面上的窗口。不属于任何桌面的窗口（已关闭仍驻留、标签页等）不算。
    static func windowsOnOtherSpaces(_ ids: [CGWindowID]) -> Set<CGWindowID> {
        guard let mainConnection, let copySpacesForWindows, !ids.isEmpty else { return [] }
        let current = currentSpaceIDs()
        guard !current.isEmpty else { return [] }
        let connection = mainConnection()
        var result: Set<CGWindowID> = []
        for id in ids {
            let spaces = (copySpacesForWindows(connection, 7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber] ?? [])
                .map(\.uint64Value)
            if !spaces.isEmpty, current.isDisjoint(with: spaces) { result.insert(id) }
        }
        return result
    }

    /// 把指定窗口所在的桌面切到前台并激活该窗口。成功返回 true。
    @discardableResult
    static func bringToFront(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let setFrontProcess, let processForPID else { return false }
        var psn = ProcessSerialNumber()
        guard processForPID(pid, &psn) == noErr else { return false }
        // 0x200：用户发起的切换，系统会切换到窗口所在的桌面。
        return setFrontProcess(&psn, windowID, 0x200) == .success
    }

    /// 窗口当前是否显示在屏幕上（切换桌面后用于等待）。
    static func isOnScreen(_ id: CGWindowID) -> Bool {
        guard let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let entry = entries.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }) else { return false }
        return (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }
}
