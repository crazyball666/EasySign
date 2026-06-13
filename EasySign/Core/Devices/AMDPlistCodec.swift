import Foundation

/// lockdownd plist-RPC 服务(installation_proxy / house_arrest 等)的线缆编码:
/// 每条消息 = 4 字节**大端**长度前缀 + XML plist 体。此处只放纯编码/解析(不引用任何
/// MobileDevice 符号),便于独立 swiftc 测试;实际 send/recv 在 InstallationProxyClient 里。
enum AMDPlistCodec {
    enum CodecError: Error { case encodeFailed }

    /// 编码一条消息:4 字节大端长度前缀 + XML plist。
    static func frame(_ dict: [String: Any]) throws -> Data {
        let body: Data
        do {
            body = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        } catch {
            throw CodecError.encodeFailed
        }
        var lengthBE = UInt32(body.count).bigEndian
        var out = Data()
        out.append(Data(bytes: &lengthBE, count: 4))
        out.append(body)
        return out
    }

    /// 解析 4 字节大端长度前缀;不足 4 字节返回 nil。
    static func bodyLength(prefix: Data) -> Int? {
        guard prefix.count >= 4 else { return nil }
        let be = prefix.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Int(be)
    }
}
