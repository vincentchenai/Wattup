import Foundation
import IOKit

/// 只读电池实时电流，不写入 SMC，也不改变充电策略。
enum SMCBatterySampler {
    static func currentMA() -> Int? {
        // ponytail: 仅使用已在 Apple Silicon 实测的 B0AC/si16 协议；其他平台回退原有数据源。
        #if arch(arm64)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connection) }

        // AppleSMC 的 80 字节请求：key=0，keyInfo=28，result=40，command=42，bytes=48。
        // 协议参考：https://github.com/exelban/stats/blob/master/SMC/smc.swift
        var request = [UInt8](repeating: 0, count: 80)
        let key: UInt32 = 0x42304143 // B0AC
        request.replaceSubrange(0..<4, with: withUnsafeBytes(of: key, Array.init))
        request[42] = 9 // 读取键元数据
        guard let info = read(connection, request: request),
              Array(info[28..<32]) == [2, 0, 0, 0],
              Array(info[32..<36].reversed()) == Array("si16".utf8) else { return nil }

        request[28] = 2
        request[42] = 5 // 只读取值；没有写入命令
        guard let result = read(connection, request: request) else { return nil }
        return decodeCurrent(Array(result[48..<50]))
        #else
        return nil
        #endif
    }

    /// 本机 B0AC 为小端、有符号 16 位毫安值；保留零值和负值。
    static func decodeCurrent(_ bytes: [UInt8]) -> Int? {
        guard bytes.count == 2 else { return nil }
        return Int(Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8))
    }

    private static func read(_ connection: io_connect_t, request: [UInt8]) -> [UInt8]? {
        var response = [UInt8](repeating: 0, count: 80)
        var size = response.count
        let status = request.withUnsafeBytes { input in
            response.withUnsafeMutableBytes { output in
                IOConnectCallStructMethod(connection, 2, input.baseAddress, input.count,
                                          output.baseAddress, &size)
            }
        }
        guard status == KERN_SUCCESS, size == response.count, response[40] == 0 else { return nil }
        return response
    }
}
