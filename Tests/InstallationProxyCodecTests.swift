import Foundation

/// installation_proxy 的纯协议逻辑测试:plist 帧编码 + 回复解释。
/// 真正装/卸到设备是集成动作(AMDServiceConnection + 真机),不在此测。
///
/// 期望输出:`ALL PASS`,否则 `FAIL: ...` 到 stderr + exit(1)。

@main
struct InstallationProxyCodecTests {
    static func main() {
        // —— AMDPlistCodec.frame:4 字节大端长度前缀 + 可回解的 XML plist ——
        let dict: [String: Any] = ["Command": "Uninstall", "ApplicationIdentifier": "com.example.app"]
        let framed = try! AMDPlistCodec.frame(dict)
        expect(framed.count > 4, "帧应含长度前缀 + plist 体")
        let prefix = framed.prefix(4)
        let declared = AMDPlistCodec.bodyLength(prefix: Data(prefix))
        expect(declared == framed.count - 4, "长度前缀应等于 plist 体长度(声明 \(declared ?? -1),实际 \(framed.count - 4))")
        let body = framed.suffix(from: framed.index(framed.startIndex, offsetBy: 4))
        let decoded = try? PropertyListSerialization.propertyList(from: Data(body), options: [], format: nil) as? [String: Any]
        expect((decoded?["Command"] as? String) == "Uninstall", "plist 体应可回解出 Command")
        expect((decoded?["ApplicationIdentifier"] as? String) == "com.example.app", "plist 体应可回解出 bundleId")

        // —— bodyLength 往返 ——
        var be = UInt32(305_419_896).bigEndian   // 0x12345678
        let p = Data(bytes: &be, count: 4)
        expect(AMDPlistCodec.bodyLength(prefix: p) == 305_419_896, "长度前缀应按大端解析")
        expect(AMDPlistCodec.bodyLength(prefix: Data([1, 2, 3])) == nil, "不足 4 字节应返回 nil")

        // —— InstallReply.interpret:进度 / 完成 / 错误 ——
        expect(InstallReply.interpret(["Status": "Complete"]) == .complete,
               "Status=Complete 应判为 .complete")
        expect(InstallReply.interpret(["PercentComplete": 42, "Status": "Installing"]) == .progress(percent: 42, status: "Installing"),
               "含 PercentComplete/Status 应判为 .progress")
        expect(InstallReply.interpret(["Status": "CreatingStagingDirectory"]) == .progress(percent: nil, status: "CreatingStagingDirectory"),
               "只有 Status 也应是 .progress(无百分比)")
        expect(InstallReply.interpret(["Error": "ApplicationVerificationFailed", "ErrorDescription": "签名无效"]) == .failed("ApplicationVerificationFailed: 签名无效"),
               "含 Error 应判为 .failed,并带 ErrorDescription")
        expect(InstallReply.interpret(["Error": "MismatchedApplicationIdentifierEntitlement"]) == .failed("MismatchedApplicationIdentifierEntitlement"),
               "只有 Error 无描述时,.failed 用 Error 本身")

        print("ALL PASS")
    }

    static func expect(_ c: Bool, _ m: String) {
        if !c {
            FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8))
            exit(1)
        }
    }
}
