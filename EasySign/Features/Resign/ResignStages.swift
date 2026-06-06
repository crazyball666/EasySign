import Foundation

/// 重签流水线 11 个阶段（按 ResignTask.Start 顺序）。
public enum ResignStage: String, CaseIterable, Identifiable {
    case extract           = "解压"
    case updateMetadata    = "元信息"
    case cleanupMac        = "清理"
    case injectDylib       = "注入"
    case installCert       = "装证书"
    case installProfile    = "装描述"
    case signDylib         = "签dylib"
    case signAppex         = "签appex"
    case applyEntitlements = "权限"
    case signApp           = "签app"
    case exportIPA         = "导出"

    public var id: String { rawValue }
}
