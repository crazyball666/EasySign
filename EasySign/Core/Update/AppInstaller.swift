import Foundation
import AppKit

/// 不签名前提下的「自动安装 + 重启」。下载好的新版 .app 替换当前 bundle,
/// 替换后对新 bundle 去 quarantine(否则未签名 + 带隔离会被 Gatekeeper 拦),再重启。
/// 仅在 App 已正经装入(非 App Translocation)且安装目录可写时执行;否则调用方回退到「打开 DMG」。
enum AppInstaller {
    enum InstallError: LocalizedError {
        case mountFailed(String)
        case noAppInDMG
        case bundleIdMismatch(expected: String, got: String)
        case stageFailed(String)

        var errorDescription: String? {
            switch self {
            case .mountFailed(let m):    return "挂载安装包失败:\(m)"
            case .noAppInDMG:            return "安装包里找不到 App"
            case let .bundleIdMismatch(e, g): return "App 标识不匹配(期望 \(e),实际 \(g))"
            case .stageFailed(let m):    return "准备安装文件失败:\(m)"
            }
        }
    }

    // MARK: - 纯逻辑(可单测)

    /// App 是否被 Gatekeeper App Translocation 转移到只读随机路径(从 DMG/下载目录直接运行所致)。
    /// 转移态下 bundleURL 指向只读路径,无法替换真实 bundle。
    static func isTranslocated(_ bundleURL: URL) -> Bool {
        return bundleURL.path.contains("/AppTranslocation/")
    }

    /// 生成「等退出 → 备份 → 替换 → 去隔离 → 失败回滚 → 重开 → 清理」的脱壳安装脚本(纯文本)。
    /// 所有路径用单引号包裹并转义内部单引号,避免空格/特殊字符把参数拆开。
    static func installerScript(pid: Int32, stagedPath: String, destPath: String, stagingDir: String) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let staged = q(stagedPath)
        let dest = q(destPath)
        let bak = q(destPath + ".bak")
        let staging = q(stagingDir)
        return """
        #!/bin/sh
        # 等当前 App(PID \(pid))退出后再替换,避免替换正在运行的 bundle。
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        sleep 0.3
        if /bin/mv \(dest) \(bak) 2>/dev/null; then
          if /usr/bin/ditto \(staged) \(dest); then
            /usr/bin/xattr -dr com.apple.quarantine \(dest) 2>/dev/null
            /bin/rm -rf \(bak)
          else
            # 替换失败 → 回滚到旧版,保证 App 不丢。
            /bin/rm -rf \(dest)
            /bin/mv \(bak) \(dest)
          fi
        fi
        /bin/rm -rf \(staging)
        /usr/bin/open \(dest)
        """
    }

    // MARK: - 前置判定

    /// 能否就地自替换:非 translocation 且安装目录(及 bundle 本身)可写。
    static func canSelfReplace(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        if isTranslocated(bundleURL) { return false }
        let fm = FileManager.default
        let parent = bundleURL.deletingLastPathComponent().path
        return fm.isWritableFile(atPath: parent) && fm.isWritableFile(atPath: bundleURL.path)
    }

    // MARK: - 集成动作(挂载 / 复制 / 重启;靠手动 E2E)

    /// 挂载 DMG,把里面的 .app(校验 bundle id 一致)`ditto` 到临时 staging,再卸载。返回 staged .app。
    static func mountAndStage(dmg: URL) throws -> URL {
        let fm = FileManager.default
        let mountPoint = fm.temporaryDirectory.appendingPathComponent("easysign-mnt-\(UUID().uuidString)")
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let attach = run("/usr/bin/hdiutil",
                         ["attach", "-nobrowse", "-noverify", "-quiet", "-mountpoint", mountPoint.path, dmg.path])
        guard attach.status == 0 else { throw InstallError.mountFailed(attach.err) }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint.path])
            try? fm.removeItem(at: mountPoint)
        }

        let contents = (try? fm.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else { throw InstallError.noAppInDMG }

        // 防呆:新包的 bundle id 必须和本机一致(避免误装成别的 App)。
        if let expected = Bundle.main.bundleIdentifier, let got = bundleIdentifier(ofAppAt: app), expected != got {
            throw InstallError.bundleIdMismatch(expected: expected, got: got)
        }

        let stagingDir = fm.temporaryDirectory.appendingPathComponent("easysign-stage-\(UUID().uuidString)")
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let staged = stagingDir.appendingPathComponent(app.lastPathComponent)
        let dit = run("/usr/bin/ditto", [app.path, staged.path])
        guard dit.status == 0 else { throw InstallError.stageFailed(dit.err) }
        return staged
    }

    /// 写脱壳脚本并分离启动(不 wait;脚本等本进程退出后替换+重启),随后退出当前 App。
    static func installAndRelaunch(stagedApp: URL) throws {
        let dest = Bundle.main.bundleURL
        let stagingDir = stagedApp.deletingLastPathComponent()
        let script = installerScript(pid: ProcessInfo.processInfo.processIdentifier,
                                     stagedPath: stagedApp.path, destPath: dest.path, stagingDir: stagingDir.path)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("easysign-install-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptURL.path]
        try p.run()   // 不 waitUntilExit:GUI App 退出后该子进程由 launchd 接管继续跑。
        NSApp.terminate(nil)
    }

    // MARK: - 私有

    private static func bundleIdentifier(ofAppAt app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict["CFBundleIdentifier"] as? String
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        do { try p.run() } catch { return (-1, "", "\(error)") }
        let outD = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errD = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus,
                String(data: outD, encoding: .utf8) ?? "",
                String(data: errD, encoding: .utf8) ?? "")
    }
}
