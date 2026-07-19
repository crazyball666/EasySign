import Foundation

/// `.apple` 重签后端的可用性探测。
///
/// 为什么需要:codesign 本身是 macOS 自带的真实二进制(实测把 DEVELOPER_DIR 指向
/// 不存在的目录仍能正常工作,otool 也看不到任何 Xcode 路径依赖),但 `.apple` 这条
/// 路径签完之后还要跑 `xcodebuild -exportArchive`(见 ResignTask.xcodebuildExportArchive),
/// 而 `/usr/bin/xcodebuild` 是 xcode-select 转发壳 —— 只装命令行工具时它会直接报
/// 「requires Xcode, but active developer directory ... is a command line tools instance」。
/// 所以判据是**有没有完整 Xcode**,不是有没有 codesign。
enum XcodeAvailability {
    /// 探测结果。`developerDirectory` 仅用于给用户提示当前指向哪里。
    struct Probe {
        let isAvailable: Bool
        let developerDirectory: String?
        let failureReason: String?
    }

    /// 探测一次。会起子进程,**不要在主线程调用**。
    ///
    /// 判据用 `xcodebuild -version` 的退出码,而不是去猜路径:它正是重签实际要跑的
    /// 命令,xcode-select 指向被改过、Xcode 被删了一半等情况都能如实反映。实测约 0.08s。
    static func probe() -> Probe {
        let developerDir = try? TaskCenter.execute(
            lanuchPath: "/usr/bin/xcode-select",
            arguments: ["-p"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            _ = try TaskCenter.execute(lanuchPath: "/usr/bin/xcodebuild", arguments: ["-version"])
            return Probe(isAvailable: true, developerDirectory: developerDir, failureReason: nil)
        } catch {
            let reason: String
            if let taskError = error as? TaskError, !taskError.output.isEmpty {
                reason = taskError.output.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                reason = error.localizedDescription
            }
            return Probe(isAvailable: false, developerDirectory: developerDir, failureReason: reason)
        }
    }
}
