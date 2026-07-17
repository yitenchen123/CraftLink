import Foundation

// MARK: - Constants
//
// 新版 CraftLink 通过 `TerracottaBridge` 直接调用 burningtnt/Terracotta 的 Rust 实现，
// 不再自己拼装 EasyTier TOML 配置。Terracotta 内部硬编码了所有正确的协议参数（虚拟
// IP、Scaffolding 端口、hostname、EasyTier flags 等），所以这里只保留 UI 显示用的
// 常量，不再保留用于配置 EasyTier 的字段。
//
// 以下数值与 Terracotta `src/controller/rooms/scaffolding/room.rs::compute_arguments`
// 完全一致，仅用于 UI 提示，不影响协议行为。

enum Constants {

    // MARK: - 虚拟网络（与 Terracotta 一致）
    /// 房主虚拟 IP（固定，由 Terracotta 在 EasyTier `IPv4` 参数中硬编码）。
    static let serverIP = "10.144.144.1"
    /// 默认访客虚拟 IP（首个访客；后续访客由 EasyTier DHCP 动态分配）。
    static let clientIP = "10.144.144.2"
    /// 子网掩码（Terracotta 用 /24，即 255.255.255.0）。
    static let subnetMask = "255.255.255.0"
    /// Scaffolding 协议端口（Terracotta 固定为 13448，**不是** MC 端口）。
    static let scaffoldingPort: UInt16 = 13448
    /// 房主在 EasyTier 网络内的 hostname（Terracotta 硬编码为 scaffolding-mc-server-13448）。
    static let hostHostname = "scaffolding-mc-server-13448"

    // MARK: - 历史记录
    static let maxHistoryCount = 20

    // MARK: - 玩家身份
    /// CraftLink 在 PlayerProfile.vendor 字段中上报的实现标识。
    /// （注：Terracotta Rust 侧会自动设置 vendor，这里仅用于本地历史记录展示。）
    static let vendor = "CraftLink"

    // MARK: - Legacy（保留以兼容 RoomHistory 旧字段）
    /// 旧版字段，曾表示 EasyTier 公网 peer 端口。新版不再使用，但 `RoomHistory.port` 仍可能引用。
    static let serverPort: UInt16 = 11010
}
