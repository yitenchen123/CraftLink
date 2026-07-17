import Foundation

// MARK: - Terracotta C ABI 桥接
//
// 本文件是 CraftLink 与 `libterracotta.a`（burningtnt/Terracotta 的 iOS 构建，含
// `lib_ios.rs` 补丁）之间的唯一通道。所有 `terracotta_ios_*` C 函数声明都在
// `terracotta.h` 中，由 bridging header 导入。
//
// 与旧版 `RustBridge.swift` 的区别：
//   - 旧版直接调用 EasyTier 的 `run_network_instance` / `set_tun_fd`，需要
//     NEPacketTunnelProvider 提供 TUN fd → 必须申请 NE 权限。
//   - 新版调用 Terracotta 的 `terracotta_ios_set_scanning` / `_set_guesting`，
//     内部以 `no_tun=true` + `port_forward` 模式跑 EasyTier → 不需要 TUN fd，
//     不需要 NE 权限，也不需要 Scaffolding Swift 协议层（Terracotta 全包了）。
//
// 协议兼容性：100% 与 HMCL/FCL/ZalithLauncher2 一致，因为调用的是同一份
// `controller::set_scanning` / `set_guesting` / `Room::from` Rust 代码。

// MARK: C ABI 函数声明
//
// 不使用 `@_silgen_name`，而是通过 bridging header (`CraftLink-Bridging-Header.h`)
// 引入 `terracotta.h`。这样 Xcode 会按 C 调用约定链接这些符号。
// 但为了在 Swift 源文件里直接引用，仍需 `@_silgen_name` 标注一遍符号名。

@_silgen_name("terracotta_ios_start")
func terracotta_ios_start(_ dir: UnsafePointer<CChar>?, _ loggingFd: CInt) -> CInt

@_silgen_name("terracotta_ios_get_state")
func terracotta_ios_get_state() -> UnsafeMutablePointer<CChar>?

@_silgen_name("terracotta_ios_set_waiting")
func terracotta_ios_set_waiting()

@_silgen_name("terracotta_ios_set_scanning")
func terracotta_ios_set_scanning(_ room: UnsafePointer<CChar>?, _ player: UnsafePointer<CChar>?)

@_silgen_name("terracotta_ios_start_host_with_port")
func terracotta_ios_start_host_with_port(_ room: UnsafePointer<CChar>?, _ port: UInt16, _ player: UnsafePointer<CChar>?) -> CInt

@_silgen_name("terracotta_ios_set_guesting")
func terracotta_ios_set_guesting(_ room: UnsafePointer<CChar>?, _ player: UnsafePointer<CChar>?) -> CInt

@_silgen_name("terracotta_ios_verify_room_code")
func terracotta_ios_verify_room_code(_ code: UnsafePointer<CChar>?) -> CInt

@_silgen_name("terracotta_ios_get_metadata")
func terracotta_ios_get_metadata() -> UnsafeMutablePointer<CChar>?

@_silgen_name("terracotta_ios_free_string")
func terracotta_ios_free_string(_ ptr: UnsafeMutablePointer<CChar>?)

// MARK: - 状态模型
//
// JSON schema 对应 `lib_ios.rs` 中 `terracotta_ios_get_state` 的输出，与 Android
// `getState0()` 完全一致。每个 case 都带 `index`（房间会话索引，从 0 递增）。

/// Terracotta 当前状态快照（从 `terracotta_ios_get_state` 返回的 JSON 解析）。
enum TerracottaState: Equatable {
    /// 空闲。App 启动后默认进入此状态。
    case waiting(index: Int)
    /// 房主：正在扫描本地 Minecraft 的「对局域网开放」广播。
    case hostScanning(index: Int)
    /// 房主：已发现 MC 服务器，正在生成邀请码并启动 EasyTier。
    case hostStarting(index: Int, room: String)
    /// 房主：EasyTier 已就绪，房间可被加入。
    case hostOk(index: Int, room: String, profileIndex: Int, profiles: [TerracottaPlayerProfile])
    /// 访客：正在连接房主（协商 EasyTier + Scaffolding）。
    case guestConnecting(index: Int, room: String)
    /// 访客：Scaffolding 协议已通，正在启动 port_forward。
    case guestStarting(index: Int, room: String, difficulty: String)
    /// 访客：port_forward 已建立，可在 MC 直接连接 `127.0.0.1:25565`。
    case guestOk(index: Int, url: String, profileIndex: Int, profiles: [TerracottaPlayerProfile])
    /// 异常。`type` 对应 Terracotta 的 ExceptionType 枚举。
    case exception(index: Int, type: Int)

    /// 房间会话索引（每次 `set_scanning` / `set_guesting` 自增）。
    var index: Int {
        switch self {
        case .waiting(let i): return i
        case .hostScanning(let i): return i
        case .hostStarting(let i, _): return i
        case .hostOk(let i, _, _, _): return i
        case .guestConnecting(let i, _): return i
        case .guestStarting(let i, _, _): return i
        case .guestOk(let i, _, _, _): return i
        case .exception(let i, _): return i
        }
    }

    /// 给 UI 显示的中文阶段描述。
    var localizedStage: String {
        switch self {
        case .waiting: return "空闲"
        case .hostScanning: return "正在扫描本地 Minecraft 服务器..."
        case .hostStarting: return "正在生成邀请码并启动虚拟网络..."
        case .hostOk: return "房间已就绪，可被加入"
        case .guestConnecting: return "正在连接房主..."
        case .guestStarting(_, _, let difficulty): return "正在建立联机隧道（难度: \(difficulty)）..."
        case .guestOk(_, let url, _, _): return "已连接，在 MC 直接连 \(url)"
        case .exception(_, let type): return TerracottaBridge.describeException(type)
        }
    }
}

/// Scaffolding 协议中的玩家档案（对应 `c:player_profiles_list` 响应）。
struct TerracottaPlayerProfile: Codable, Equatable, Identifiable {
    var name: String
    var machineId: String
    var easytierId: String?
    var vendor: String
    var kind: String  // "HOST" / "LOCAL" / "GUEST"

    var id: String { machineId }

    enum CodingKeys: String, CodingKey {
        case name
        case machineId = "machine_id"
        case easytierId = "easytier_id"
        case vendor
        case kind
    }
}

// MARK: - Bridge

/// Terracotta C ABI 的 Swift 封装。所有调用都线程安全（Rust 侧用 Mutex 保护）。
enum TerracottaBridge {

    /// 初始化 Terracotta。App 启动时调用一次。
    /// - Parameters:
    ///   - workingDirectory: 可写目录路径（通常为 App 的 Documents 目录）。
    ///     `machine-id` 会写在这里，用于跨启动保持玩家身份。
    ///   - loggingPath: 日志文件路径，传 nil 则不写文件、仅写 stderr。
    /// - Returns: true 表示成功。
    static func start(workingDirectory: String, loggingPath: String?) -> Bool {
        // 准备日志文件 fd（如果指定了路径）
        var fd: CInt = -1
        if let path = loggingPath {
            // O_WRONLY=1, O_CREAT=0o100, O_TRUNC=0o1000, O_APPEND=0o2000
            // 0o644 = rw-r--r--
            fd = path.withCString { cstr in
                open(cstr, 0o2000 | 0o100 | 0o1000, 0o644)
            }
        }
        defer {
            if fd >= 0 { close(fd) }
        }
        // Rust 侧会把 fd 复制一份（File::from_raw_fd），所以这里 close 是安全的。
        return workingDirectory.withCString { dir in
            terracotta_ios_start(dir, fd) == 0
        }
    }

    /// 回到 Waiting 状态。Idempotent。
    static func setWaiting() {
        terracotta_ios_set_waiting()
    }

    /// 房主：开始扫描本地 MC 的「对局域网开放」广播。一旦发现，Terracotta 会自动
    /// 生成邀请码、启动 EasyTier 并过渡到 `hostOk`。
    /// - Parameters:
    ///   - room: 可选，复用已有邀请码；nil 则生成新的。
    ///   - playerName: 可选，玩家昵称；nil 用 "Terracotta Anonymous Host"。
    static func setScanning(room: String?, playerName: String?) {
        // 注意：withCString 返回的指针只在其闭包内有效，调用 C 函数必须在闭包里。
        // 通过 helper 嵌套，保证两个可选字符串在调用期间都存活。
        callWithOptionalCString(room) { roomCStr in
            callWithOptionalCString(playerName) { playerCStr in
                terracotta_ios_set_scanning(roomCStr, playerCStr)
            }
        }
    }

    /// 房主（手动端口模式）：绕过多播扫描，直接用用户输入的 MC LAN 端口启动 host。
    ///
    /// iOS 上多播接收受本地网络权限和 TrollStore 签名影响，可能收不到 PojavLauncher
    /// 里 MC 发的 LAN 广播。此方法让用户手动输入 MC「对局域网开放」后显示的端口号，
    /// 完全跳过 MinecraftScanner，直接进入 start_host。
    /// - Parameters:
    ///   - room: 可选，复用已有邀请码；nil 则生成新的。
    ///   - port: MC LAN 端口（MC 开 LAN 时显示的端口号，如 25565 或随机端口）。
    ///   - playerName: 可选，玩家昵称；nil 用 "Terracotta Anonymous Host"。
    /// - Returns: true 表示已开始启动；false 表示当前不在 Waiting 状态。
    static func startHostWithPort(room: String?, port: UInt16, playerName: String?) -> Bool {
        callWithOptionalCString(room) { roomCStr in
            callWithOptionalCString(playerName) { playerCStr in
                terracotta_ios_start_host_with_port(roomCStr, port, playerCStr) == 1
            }
        }
    }

    /// 访客：加入房间。
    /// - Returns: true 表示已开始加入；false 表示邀请码无效或当前不在 Waiting 状态。
    static func setGuesting(room: String, playerName: String?) -> Bool {
        callWithOptionalCString(room) { roomCStr in
            callWithOptionalCString(playerName) { playerCStr in
                terracotta_ios_set_guesting(roomCStr, playerCStr) == 1
            }
        }
    }

    /// 仅校验邀请码，不加入。
    /// - Returns: true 表示是合法的 Scaffolding 邀请码。
    static func verifyRoomCode(_ code: String) -> Bool {
        code.withCString { cstr in
            terracotta_ios_verify_room_code(cstr) == 3
        }
    }

    /// 读取当前状态。返回 nil 表示 JSON 解析失败（Rust 侧出错）。
    static func pollState() -> TerracottaState? {
        guard let raw = terracotta_ios_get_state() else { return nil }
        defer { terracotta_ios_free_string(raw) }
        guard let jsonStr = String(cString: raw, encoding: .utf8),
              let data = jsonStr.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TerracottaStatePayload.self, from: data).toState()
    }

    /// 元数据：`(version, compileTimestampMs, easytierVersion)`。
    ///
    /// Rust 侧返回 NUL 分隔的 UTF-8：`"<version>\0<ts_ms>\0<et_version>\0"`。
    /// 我们先把整段拷贝到 `Data`，再按 `\0` 切分（最后一段后的 NUL 会产出一个空段，
    /// 用 `filter` 去掉）。
    static func metadata() -> (version: String, compileTimestampMs: Int64, easytierVersion: String)? {
        guard let raw = terracotta_ios_get_metadata() else { return nil }
        defer { terracotta_ios_free_string(raw) }

        // 计算含末尾 NUL 的总长度（strlen 不行——内部有 NUL）
        // 改用 Rust 侧约定：3 段字符串 + 3 个 NUL（含末尾终止符）
        var totalLen = 0
        var cursor = raw
        var nulCount = 0
        while nulCount < 3 {
            let ch = cursor.pointee
            totalLen += 1
            if ch == 0 { nulCount += 1 }
            cursor = cursor.advanced(by: 1)
        }
        let buffer = UnsafeBufferPointer(start: raw, count: totalLen)
        let data = Data(buffer: buffer)
        let segments = data.split(separator: 0).compactMap { String(data: $0, encoding: .utf8) }
        guard segments.count == 3, let ts = Int64(segments[1]) else { return nil }
        return (segments[0], ts, segments[2])
    }

    /// 把 ExceptionType 翻译成中文。
    static func describeException(_ type: Int) -> String {
        switch type {
        case 0: return "无法连接到房主（PingHostFail）"
        case 1: return "房主拒绝连接（PingHostRst）"
        case 2: return "访客端 EasyTier 崩溃（GuestEasytierCrash）"
        case 3: return "房主端 EasyTier 崩溃（HostEasytierCrash）"
        case 4: return "MC 服务器拒绝连接（PingServerRst）"
        case 5: return "Scaffolding 协议返回非法数据"
        default: return "未知错误（type=\(type)）"
        }
    }

    // MARK: - Helpers

    /// 把可选 String 当作 `const char *` 传给 C 函数。nil 转 NULL。
    /// 闭包返回值会被传出（不像 `withCString` 必须返回 Void）。
    private static func callWithOptionalCString<T>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
        if let s = s {
            return s.withCString { body($0) }
        } else {
            return body(nil)
        }
    }
}

// MARK: - JSON 解码辅助

/// `terracotta_ios_get_state` 返回的 JSON 中间表示。Rust 侧用 `state` 字段判别。
private struct TerracottaStatePayload: Decodable {
    let state: String
    let index: Int
    let room: String?
    let url: String?
    let profileIndex: Int?
    let profiles: [TerracottaPlayerProfile]?
    let difficulty: String?
    let type: Int?

    enum CodingKeys: String, CodingKey {
        case state, index, room, url, difficulty, type
        case profileIndex = "profile_index"
        case profiles
    }

    func toState() -> TerracottaState? {
        switch state {
        case "waiting":
            return .waiting(index: index)
        case "host-scanning":
            return .hostScanning(index: index)
        case "host-starting":
            return .hostStarting(index: index, room: room ?? "")
        case "host-ok":
            return .hostOk(index: index, room: room ?? "",
                           profileIndex: profileIndex ?? 0,
                           profiles: profiles ?? [])
        case "guest-connecting":
            return .guestConnecting(index: index, room: room ?? "")
        case "guest-starting":
            return .guestStarting(index: index, room: room ?? "",
                                  difficulty: difficulty ?? "UNKNOWN")
        case "guest-ok":
            return .guestOk(index: index, url: url ?? "",
                            profileIndex: profileIndex ?? 0,
                            profiles: profiles ?? [])
        case "exception":
            return .exception(index: index, type: type ?? -1)
        default:
            return nil
        }
    }
}
