import Foundation

/// 虚拟 IP（10.0.0.0/24 网段）分配器。
///
/// 解决原 `Constants.serverIP = 10.0.0.1` / `clientIP = 10.0.0.2` 写死导致
/// "一个房主 + 一个加入者"且多个加入者 IP 冲突的问题。
///
/// 分配规则（参照 Scaffolding-MC 习惯）：
/// - `10.0.0.1`：固定保留给房主（HOST）
/// - `10.0.0.2 ~ 10.0.0.254`：动态分配给访客（GUEST）
/// - `10.0.0.255`：广播，不分配
///
/// 线程安全：所有公开方法均通过内部锁串行化。
public final class VirtualIPAllocator {

    public static let subnet = "255.255.255.0"
    public static let hostIP = "10.0.0.1"
    public static let firstGuestIP = "10.0.0.2"
    public static let lastGuestIP = "10.0.0.254"

    private let lock = NSLock()
    /// 已分配的 IP → machineId 映射。
    private var assignments: [String: String] = [:]
    /// 反向：machineId → IP，避免同一玩家重复分配。
    private var machineIdToIP: [String: String] = [:]

    public init() {
        // 房主 IP 默认占用
        assignments[Self.hostIP] = "HOST"
        machineIdToIP["HOST"] = Self.hostIP
    }

    /// 为指定 machineId 分配一个访客 IP。
    /// - 若该 machineId 已分配过，直接返回已有 IP（幂等）。
    /// - 否则在 10.0.0.2 ~ 10.0.0.254 中找第一个未占用的 IP。
    /// - Returns: 分配到的 IP 字符串；若网段已满返回 nil。
    public func allocate(for machineId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = machineIdToIP[machineId] { return existing }
        for lastOctet in 2...254 {
            let ip = "10.0.0.\(lastOctet)"
            if assignments[ip] == nil {
                assignments[ip] = machineId
                machineIdToIP[machineId] = ip
                return ip
            }
        }
        return nil
    }

    /// 查询某个 machineId 当前已分配的 IP（不分配新的）。
    public func ip(for machineId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return machineIdToIP[machineId]
    }

    /// 释放某个 machineId 占用的 IP（玩家离开时调用）。
    public func release(machineId: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let ip = machineIdToIP.removeValue(forKey: machineId) else { return }
        assignments.removeValue(forKey: ip)
    }

    /// 当前所有分配记录（含房主）。
    public func snapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return assignments
    }

    /// 重置为初始状态（仅保留房主 IP）。
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        assignments.removeAll()
        machineIdToIP.removeAll()
        assignments[Self.hostIP] = "HOST"
        machineIdToIP["HOST"] = Self.hostIP
    }
}
