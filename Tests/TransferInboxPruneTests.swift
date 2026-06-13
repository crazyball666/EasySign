import Foundation

/// 坐实「按天清理」会正确删旧文件、留新文件。这是有数据删除副作用的逻辑(误删 = 丢用户文件),
/// 所以单独抽出 TransferPaths.pruneFiles(in:olderThan:) 来测。
///
/// 造两份文件:old.bin 回拨到 10 天前,new.bin 保持现在;以「7 天前」为 cutoff 跑清理,
/// 断言 old 被删、new 保留、返回删除数 = 1。
///
/// 期望输出:`ALL PASS`,否则 `FAIL: ...` 到 stderr + exit(1)。

@main
struct TransferInboxPruneTests {
    static func main() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("eztx-prune-\(getpid())", isDirectory: true)
        try? fm.removeItem(at: dir)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let oldFile = dir.appendingPathComponent("old.bin")
        let newFile = dir.appendingPathComponent("new.bin")
        try! Data([1, 2, 3]).write(to: oldFile)
        try! Data([4, 5, 6]).write(to: newFile)

        // old.bin 的修改时间回拨到 10 天前;new.bin 保持「现在」。
        let tenDaysAgo = Date().addingTimeInterval(-10 * 86400)
        try! fm.setAttributes([.modificationDate: tenDaysAgo], ofItemAtPath: oldFile.path)

        let cutoff = Date().addingTimeInterval(-7 * 86400)   // 7 天保留期
        let deleted = TransferPaths.pruneFiles(in: dir, olderThan: cutoff)

        expect(!fm.fileExists(atPath: oldFile.path), "10 天前的旧文件应被删除")
        expect(fm.fileExists(atPath: newFile.path), "刚写入的新文件应保留")
        expect(deleted == 1, "应报告删除 1 个文件,实际 \(deleted)")

        print("ALL PASS")
    }

    static func expect(_ c: Bool, _ m: String) {
        if !c {
            FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8))
            exit(1)
        }
    }
}
