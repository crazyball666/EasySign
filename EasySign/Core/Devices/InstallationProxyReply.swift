import Foundation

/// installation_proxy 的一条回复语义。Install/Uninstall 是流式:发一次请求后读多条回复,
/// 每条用 interpret 归类为「进度 / 完成 / 失败」。纯逻辑,便于独立 swiftc 测试。
enum InstallReply: Equatable {
    case progress(percent: Int?, status: String?)
    case complete
    case failed(String)

    /// 解释一条 installation_proxy 回复 plist。
    /// 规则:有 Error → .failed(Error[: ErrorDescription]);Status=="Complete" → .complete;否则 .progress。
    static func interpret(_ dict: [String: Any]) -> InstallReply {
        if let err = dict["Error"] as? String {
            if let desc = dict["ErrorDescription"] as? String, !desc.isEmpty {
                return .failed("\(err): \(desc)")
            }
            return .failed(err)
        }
        let status = dict["Status"] as? String
        if status == "Complete" { return .complete }
        let pct = dict["PercentComplete"] as? Int
        return .progress(percent: pct, status: status)
    }
}
