//
//  ServiceConnectionIO.swift
//  EasySign
//
//  AMDServiceConnection 上的共享 socket 原语:SSL 服务启动(带瞬时错误重试)、
//  send-all、recv-exact。HouseArrestClient / InstallationProxyClient /
//  AFCServiceConnectionTransport 原先各自复制了这套循环,这里归一。
//  各调用方仍抛自己的错误类型(读取全局 errno 的时机与原实现一致)。
//

import Foundation

enum ServiceConnectionIO {
    /// lockdownd 的瞬时错误码(资源暂缺/超时/忙),遇到可退避重试。
    static func isTransient(_ code: Int32) -> Bool {
        switch UInt32(bitPattern: code) {
        case 0xE8000003, 0xE8000004, 0xE8000005, 0xE800000C, 0xE8000012:
            return true
        default:
            return false
        }
    }

    /// 起 SSL 服务,瞬时错误退避重试(默认 3 次,0.3s * (n+1))。
    /// 返回原始结果码 + 连接;调用方据此抛自己的 startServiceFailed。
    static func secureStartWithRetry(
        deviceRef: AMDeviceRef,
        service: String,
        attempts: Int = 3
    ) -> (result: Int32, connection: AMDServiceConnectionRef?) {
        var conn: AMDServiceConnectionRef?
        var result: Int32 = -1
        for attempt in 0..<attempts {
            conn = nil
            result = AMDeviceSecureStartService(deviceRef, service as CFString, nil, &conn)
            if result == AMDAppLEDETECT_SUCCESS, conn != nil { break }
            if !isTransient(result) { break }
            Thread.sleep(forTimeInterval: 0.3 * Double(attempt + 1))
        }
        return (result, conn)
    }

    /// 发送整块数据。成功返回 true;失败返回 false(全局 errno 保留失败 send 时的值,
    /// 调用方紧接着读取 errno 即与原内联循环一致)。
    static func sendAll(_ connection: AMDServiceConnectionRef, _ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < data.count {
                let n = AMDServiceConnectionSend(connection, base.advanced(by: sent), data.count - sent)
                if n <= 0 { return false }
                sent += Int(n)
            }
            return true
        }
    }

    enum RecvResult: Equatable {
        case ok
        case eof(read: Int)    // 对端关闭(n==0);调用方按需区分 shortRead
        case failed            // n<0;全局 errno 保留
    }

    /// 精确读取 count 字节到 pointer。
    static func recvExact(
        _ connection: AMDServiceConnectionRef,
        into pointer: UnsafeMutableRawPointer,
        count: Int
    ) -> RecvResult {
        var read = 0
        while read < count {
            let n = AMDServiceConnectionReceive(connection, pointer.advanced(by: read), count - read)
            if n == 0 { return .eof(read: read) }
            if n < 0 { return .failed }
            read += Int(n)
        }
        return .ok
    }
}
