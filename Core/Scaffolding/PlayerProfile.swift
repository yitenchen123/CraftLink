import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 玩家在 Scaffolding-MC 网络中的身份标识类型。
///
/// 对应 Scaffolding-MC `ProfileKind`：
/// - `HOST`：联机中心（房主），运行 MC 服务器并通过 `c:server_port` 暴露端口
/// - `LOCAL`：本机（用于自识别，不会出现在 `c:player_profiles_list` 响应中）
/// - `GUEST`：访客（加入者）
public enum ProfileKind: String, Codable {
    case host = "HOST"
    case local = "LOCAL"
    case guest = "GUEST"
}

/// Scaffolding-MC 协议的玩家档案。
///
/// 对应 `c:player_ping` / `c:player_profiles_list` 中每个玩家的 JSON：
/// ```json
/// {"name": "Steve", "machine_id": "abc123", "easytier_id": "...", "vendor": "CraftLink", "kind": "GUEST"}
/// ```
/// - `easytier_id` 仅当双方协商支持 `c:player_easytier_id` 时才会出现。
public struct PlayerProfile: Codable, Equatable, Identifiable, Hashable {

    /// 玩家显示名（MC 内昵称或设备名）。
    public var name: String

    /// 基于硬件信息生成的稳定字符串，作为节点唯一标识。
    /// 同一设备多次加入应保持一致，用于在玩家列表中去重。
    public var machineId: String

    /// EasyTier 节点 ID（可选；仅协商 `c:player_easytier_id` 后填充）。
    public var easytierId: String?

    /// 客户端实现标识，如 `"CraftLink"` / `"HMCL"` / `"FCL"`。
    public var vendor: String

    /// 玩家角色。
    public var kind: ProfileKind

    /// 用于 SwiftUI ForEach 的稳定 id（基于 machineId）。
    public var id: String { machineId }

    private enum CodingKeys: String, CodingKey {
        case name
        case machineId = "machine_id"
        case easytierId = "easytier_id"
        case vendor
        case kind
    }

    public init(name: String,
                machineId: String,
                easytierId: String? = nil,
                vendor: String = "CraftLink",
                kind: ProfileKind) {
        self.name = name
        self.machineId = machineId
        self.easytierId = easytierId
        self.vendor = vendor
        self.kind = kind
    }
}

/// 玩家档案的常用工具。
public enum PlayerProfileUtil {

    /// 生成稳定的 machine_id（基于设备 identifierForVendor + 进程信息，跨启动保持稳定）。
    /// 在 PacketTunnel 扩展进程中也可调用（不依赖 UIKit 私有 API）。
    public static func stableMachineId() -> String {
        // identifierForVendor 在同一 vendor 的 App 间共享且稳定；
        // 扩展进程取到的值与主 App 一致（同 vendor）。
        #if canImport(UIKit)
        if let idfv = UIDevice.current.identifierForVendor?.uuidString {
            return idfv
        }
        #endif
        // 回退：用 host name + process info 拼一个稳定字符串
        let host = ProcessInfo.processInfo.hostName
        let pid = ProcessInfo.processInfo.processIdentifier
        return "fallback-\(host)-\(pid)"
    }
}
