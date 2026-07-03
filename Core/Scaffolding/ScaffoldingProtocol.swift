import Foundation

/// Scaffolding-MC 协议标准请求类型（namespace=`c`=community，必须全部实现）。
///
/// 对应 Scaffolding-MC 规范：
/// - `c:ping`：echo，请求体 < 32 字节，响应体 = 请求体
/// - `c:protocols`：协商双方支持的协议列表，响应体 = `\0` 分割的 ASCII 串数组
/// - `c:server_port`：响应体 = 大端序 2 字节 u16 = MC 服务器端口
/// - `c:player_ping`：每 5 秒心跳；请求体 = 玩家 JSON
/// - `c:player_profiles_list`：响应体 = JSON 数组 `[{name, machine_id, easytier_id?, vendor, kind}]`
/// - `c:player_easytier_id`：扩展协议，协商后 `c:player_ping` 才带 `easytier_id` 字段
public enum ScaffoldingProtocolType {
    public static let ping = "c:ping"
    public static let protocols = "c:protocols"
    public static let serverPort = "c:server_port"
    public static let playerPing = "c:player_ping"
    public static let playerProfilesList = "c:player_profiles_list"
    public static let playerEasytierId = "c:player_easytier_id"

    /// CraftLink 支持的协议列表，用于 `c:protocols` 协商。
    public static let supportedProtocols: [String] = [
        ping,
        protocols,
        serverPort,
        playerPing,
        playerProfilesList
        // 暂不声明 player_easytier_id：当前 RustBridge 没有获取 EasyTier 节点 id 的 FFI
    ]
}

/// Scaffolding-MC 响应状态码。
///
/// - `ok = 0`：成功
/// - `[32, 64)`：协议错误（具体含义由协议定义）
/// - `255`：未知错误，响应体为 UTF-8 错误文本
public enum ScaffoldingStatusCode: UInt8 {
    case ok = 0
    case protocolError = 32       // 通用协议错误
    case serverNotStarted = 33    // c:server_port 专用：MC 服务器未启动
    case invalidRequest = 34      // 请求格式错误
    case unknown = 255
}

/// Scaffolding-MC 请求帧。
///
/// 帧格式（大端序）：
/// ```
/// 偏移  类型      含义
/// 0     uint8     请求类型长度 L
/// 1     byte[L]   请求类型 ASCII 字符串（如 "c:ping"）
/// 1+L   uint32    请求体长度 M
/// 5+L   byte[M]   请求体
/// ```
public struct ScaffoldingRequest: Equatable {
    public let type: String
    public let body: Data

    public init(type: String, body: Data = Data()) {
        self.type = type
        self.body = body
    }

    /// 编码为字节流。
    public func encode() -> Data {
        var data = Data()
        let typeBytes = Array(type.utf8)
        data.append(UInt8(typeBytes.count))
        data.append(contentsOf: typeBytes)
        var bodyLen = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &bodyLen) { data.append(contentsOf: $0) }
        data.append(body)
        return data
    }
}

/// Scaffolding-MC 响应帧。
///
/// 帧格式（大端序）：
/// ```
/// 偏移  类型      含义
/// 0     uint8     状态（0=成功；[32,64)=协议错误；255=未知错误）
/// 1     uint32    响应体长度 M
/// 5     byte[M]   响应体
/// ```
public struct ScaffoldingResponse: Equatable {
    public let status: UInt8
    public let body: Data

    public init(status: UInt8, body: Data = Data()) {
        self.status = status
        self.body = body
    }

    public init(status: ScaffoldingStatusCode, body: Data = Data()) {
        self.status = status.rawValue
        self.body = body
    }

    /// 成功响应的便捷构造。
    public static func ok(_ body: Data = Data()) -> ScaffoldingResponse {
        return ScaffoldingResponse(status: ScaffoldingStatusCode.ok.rawValue, body: body)
    }

    /// 错误响应的便捷构造，body 为错误文本。
    public static func error(_ message: String, code: ScaffoldingStatusCode = .unknown) -> ScaffoldingResponse {
        return ScaffoldingResponse(status: code.rawValue, body: Data(message.utf8))
    }

    /// 编码为字节流。
    public func encode() -> Data {
        var data = Data()
        data.append(status)
        var bodyLen = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &bodyLen) { data.append(contentsOf: $0) }
        data.append(body)
        return data
    }
}

/// 增量帧解析器：把 TCP 字节流切成完整的请求或响应帧。
///
/// 用法：持续调用 `feed(_:)` 追加字节，每次调用后读 `completedRequests` / `completedResponses`，
/// 处理完清空对应数组。
public final class ScaffoldingFrameDecoder {

    public var completedRequests: [ScaffoldingRequest] = []
    public var completedResponses: [ScaffoldingResponse] = []

    /// 解析模式。设为 internal 以便同模块内的 Server（请求帧）/ Client（响应帧）构造时指定。
    enum Mode {
        case request
        case response
    }

    private let mode: Mode
    private var buffer = Data()

    /// 默认构造请求帧解析器（房主端）。
    public init() {
        self.mode = .request
    }

    /// 指定解析模式（同模块内 Server/Client 使用）。
    init(mode: Mode) {
        self.mode = mode
    }

    public func feed(_ data: Data) {
        buffer.append(data)
        parse()
    }

    public func reset() {
        buffer.removeAll()
        completedRequests.removeAll()
        completedResponses.removeAll()
    }

    private func parse() {
        while !buffer.isEmpty {
            switch mode {
            case .request:
                guard let req = tryParseRequest() else { return }
                completedRequests.append(req)
            case .response:
                guard let resp = tryParseResponse() else { return }
                completedResponses.append(resp)
            }
        }
    }

    private func tryParseRequest() -> ScaffoldingRequest? {
        guard !buffer.isEmpty else { return nil }
        let typeLen = Int(buffer[0])
        let headerLen = 1 + typeLen + 4
        guard buffer.count >= headerLen else { return nil }

        let typeStart = 1
        let typeEnd = typeStart + typeLen
        let typeBytes = buffer[typeStart..<typeEnd]
        let type = String(data: typeBytes, encoding: .ascii) ?? ""

        let bodyLenStart = typeEnd
        let bodyLenEnd = bodyLenStart + 4
        let bodyLen = buffer.subdata(in: bodyLenStart..<bodyLenEnd).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
        let bodyStart = bodyLenEnd
        let bodyEnd = bodyStart + Int(bodyLen)
        guard buffer.count >= bodyEnd else { return nil }

        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        buffer.removeFirst(bodyEnd)
        return ScaffoldingRequest(type: type, body: body)
    }

    private func tryParseResponse() -> ScaffoldingResponse? {
        let headerLen = 1 + 4
        guard buffer.count >= headerLen else { return nil }

        let status = buffer[0]
        let bodyLen = buffer.subdata(in: 1..<5).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
        let bodyStart = 5
        let bodyEnd = bodyStart + Int(bodyLen)
        guard buffer.count >= bodyEnd else { return nil }

        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        buffer.removeFirst(bodyEnd)
        return ScaffoldingResponse(status: status, body: body)
    }
}

/// 协议工具：把 `c:protocols` 的 `\0` 分割串数组编解码。
public enum ScaffoldingProtocolListCodec {

    /// 把协议名列表编码为 `\0` 分割的 ASCII 字节流（用于 `c:protocols` 请求/响应体）。
    public static func encode(_ protocols: [String]) -> Data {
        guard !protocols.isEmpty else { return Data() }
        let joined = protocols.joined(separator: "\0")
        return Data(joined.utf8)
    }

    /// 把 `\0` 分割的字节流解码为协议名数组。
    public static func decode(_ data: Data) -> [String] {
        guard !data.isEmpty,
              let str = String(data: data, encoding: .ascii) else {
            return []
        }
        return str.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    /// 取双方协议列表的交集（协商出共同支持的协议）。
    public static func intersect(_ a: [String], _ b: [String]) -> [String] {
        let setB = Set(b)
        return a.filter { setB.contains($0) }
    }
}
