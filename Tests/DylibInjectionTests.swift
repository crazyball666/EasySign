import Foundation

@main
struct DylibInjectionTests {
    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        if actual != expected {
            fputs("FAIL: \(message)\nactual: \(actual)\nexpected: \(expected)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        expectEqual(
            DylibInjection.paths(from: " /tmp/A.dylib ;\n/Users/me/B.dylib;; "),
            ["/tmp/A.dylib", "/Users/me/B.dylib"],
            "解析应支持分号、换行、空白裁剪和空项过滤"
        )

        expectEqual(
            DylibInjection.displayText(from: ["/tmp/A.dylib", "/Users/me/B.dylib"]),
            "/tmp/A.dylib; /Users/me/B.dylib",
            "展示文本应使用分号加空格连接多个路径"
        )

        expectEqual(
            DylibInjection.mergePaths(existing: ["/tmp/A.dylib"], adding: ["/tmp/A.dylib", "/Users/me/B.dylib"]),
            ["/tmp/A.dylib", "/Users/me/B.dylib"],
            "追加选择动态库时应保留已有路径并按完整路径去重"
        )

        expectEqual(
            DylibInjection.removePath(at: 1, from: ["/tmp/A.dylib", "/Users/me/B.dylib"]),
            ["/tmp/A.dylib"],
            "界面逐个移除动态库时应删除指定位置"
        )

        let duplicates = DylibInjection.duplicateFileNames(in: [
            URL(fileURLWithPath: "/tmp/A.dylib"),
            URL(fileURLWithPath: "/Users/me/A.dylib"),
            URL(fileURLWithPath: "/Users/me/B.dylib")
        ])
        expectEqual(duplicates, ["A.dylib"], "同名 dylib 会覆盖 App 根目录目标文件，应被检测出来")

        expectEqual(
            DylibInjection.loadCommandName(for: URL(fileURLWithPath: "/tmp/A.dylib")),
            "@executable_path/A.dylib",
            "注入 load command 应指向 App 可执行文件同级 dylib"
        )
    }
}
