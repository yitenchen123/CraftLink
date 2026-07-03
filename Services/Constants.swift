import Foundation

enum Constants {

    // MARK: - Bundle / App Group
    static let appGroupId = "group.com.craftlink"
    static let packetTunnelBundleId = "com.craftlink.app.packet-tunnel"

    // MARK: - 虚拟网络（10.0.0.0/24）
    /// 房主虚拟 IP（固定）。
    static let serverIP = "10.0.0.1"
    /// 默认访客虚拟 IP（首个访客；后续访客由 VirtualIPAllocator 动态分配）。
    static let clientIP = "10.0.0.2"
    static let subnetMask = "255.255.255.0"

    // MARK: - 历史记录
    static let maxHistoryCount = 20

    // MARK: - EasyTier 公网中继
    /// EasyTier 官方公共节点，用于无公网 IP 时的初始发现与中转。
    /// P2P 直连失败时由这些节点中继流量。EasyTier 内部会自动尝试 UDP 打洞。
    static let defaultEasyTierPeers = [
        "tcp://public.easytier.cn:11010",
        "udp://public.easytier.cn:11010"
    ]

    // MARK: - Scaffolding-MC 协议
    /// CraftLink 在 PlayerProfile.vendor 字段中上报的实现标识。
    static let vendor = "CraftLink"

    /// 玩家心跳间隔（秒）。
    static let playerPingInterval: TimeInterval = 5

    /// 玩家超时阈值（秒），超过未收到心跳视为离线。
    static let playerTimeout: TimeInterval = 15

    // MARK: - App Group UserDefaults Keys
    /// 主 App 与 PacketTunnel 扩展之间通过 App Group UserDefaults 共享的键。
    public enum AppGroupKey {
        /// 当前邀请码原始字符串（如 `U/NNNN-NNNN-SSSS-SSSS`）。
        public static let currentInviteCode = "currentInviteCode"
        /// 当前 MC 端口字符串（房主用，用户输入）。
        public static let currentPort = "currentPort"
        /// 是否房主（Bool）。
        public static let isServer = "isServer"
        /// EasyTier `network_name`（如 `scaffolding-mc-NNNN-NNNN`）。
        public static let networkName = "networkName"
        /// EasyTier `network_secret`（如 `SSSS-SSSS`）。
        public static let networkSecret = "networkSecret"
        /// EasyTier `hostname`（房主为 `scaffolding-mc-server-{port}`，访客为空）。
        public static let hostname = "hostname"
        /// MC 服务器端口（UInt16，房主设置；访客通过 ScaffoldingClient 协议获取）。
        public static let mcPort = "mcPort"
        /// PacketTunnel 写回主 App 的错误信息。
        public static let tunnelError = "tunnelError"
        /// tunnelError 的时间戳。
        public static let tunnelErrorTime = "tunnelErrorTime"
    }

    // MARK: - Legacy（保留以兼容旧代码引用）
    static let serverPort: UInt16 = 11010
}
