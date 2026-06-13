import Foundation

/// AppInstaller 的纯逻辑测试:translocation 判定 + 脱壳安装脚本生成。
/// 挂载/替换/重启是集成动作(hdiutil/Process/NSApp),靠真机手动 E2E,不在此测。
///
/// 期望输出:`ALL PASS`,否则 `FAIL: ...` 到 stderr + exit(1)。

@main
struct AppInstallerTests {
    static func main() {
        // —— isTranslocated ——
        expect(AppInstaller.isTranslocated(URL(fileURLWithPath:
            "/private/var/folders/ab/cd/AppTranslocation/ABC-123/d/EasySign.app")),
            "转移路径应判为 translocated")
        expect(!AppInstaller.isTranslocated(URL(fileURLWithPath: "/Applications/EasySign.app")),
            "/Applications 不应判为 translocated")

        // —— installerScript:必须备份 + 失败回滚 + 去 quarantine + 路径带空格仍安全 ——
        let s = AppInstaller.installerScript(
            pid: 4242,
            stagedPath: "/tmp/easysign-stage-x/EasySign.app",
            destPath: "/Applications/Easy Sign.app",
            stagingDir: "/tmp/easysign-stage-x")
        expect(s.contains("kill -0 4242"), "应等待目标 PID 退出")
        expect(s.contains("ditto"), "应用 ditto 复制新版")
        expect(s.contains("com.apple.quarantine"), "应去 quarantine,否则重启被 Gatekeeper 拦")
        expect(s.contains(".bak"), "应先把旧版备份(.bak)")
        expect(s.contains("open"), "应重新打开新版")
        // 带空格的目标路径必须被单引号包裹(否则脚本会把它拆成两个参数)
        expect(s.contains("'/Applications/Easy Sign.app'"),
            "带空格路径应被单引号包裹,实际脚本:\n\(s)")

        // 脚本做 rm/mv 等破坏性操作,必须是语法合法的 sh —— 用 `sh -n` 静态检查(不执行,无副作用)。
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eztx-script-check-\(getpid()).sh")
        try? s.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/sh")
        check.arguments = ["-n", scriptURL.path]
        let errPipe = Pipe(); check.standardError = errPipe
        try? check.run()
        let errOut = errPipe.fileHandleForReading.readDataToEndOfFile()
        check.waitUntilExit()
        expect(check.terminationStatus == 0,
            "生成的安装脚本应是合法 sh,`sh -n` 报错:\(String(data: errOut, encoding: .utf8) ?? "")")

        print("ALL PASS")
    }

    static func expect(_ c: Bool, _ m: String) {
        if !c {
            FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8))
            exit(1)
        }
    }
}
