# 陶瓦联机 (Terracotta) 协议解析文档

本文档详细解析 HMCL / FCL / ZalithLauncher2 / 本 iOS 实现所共同遵循的
"陶瓦联机"协议，使你能理解每一字节的含义，以及为什么这套实现可以
100% 与其他三端互通。

> 所有协议细节来自 `burningtnt/Terracotta` 仓库（commit 主分支）的源码
> 直接翻译。iOS 实现复用同一份 Rust 代码（`lib_ios.rs` 仅替换 JNI 为
> C ABI），因此协议层 byte-for-byte 一致。

---

## 目录

1. [整体架构](#1-整体架构)
2. [房间码（邀请码）算法](#2-房间码邀请码算法)
3. [EasyTier 虚拟网络配置](#3-easytier-虚拟网络配置)
4. [Scaffolding TCP 应用层协议](#4-scaffolding-tcp-应用层协议)
5. [Minecraft 局域网发现（UDP 多播）](#5-minecraft-局域网发现udp-多播)
6. [房主完整流程](#6-房主完整流程)
7. [房客完整流程](#7-房客完整流程)
8. [公共入口节点](#8-公共入口节点)
9. [与 HMCL/FCL/ZL2 的互通保证](#9-与-hmclfclzl2-的互通保证)

---

## 1. 整体架构

```
┌─────────────────────────────────────────────────────────────┐
│  Minecraft Java (在 Amethyst-iOS 内置 JVM 中运行)           │
│  - 房主: ESC → "对局域网开放" → 在 25565/随机端口监听 TCP    │
│  - 房客: 多人游戏界面 → 直接连接 127.0.0.1:<port>            │
└─────────────────┬─────────────────────────┬─────────────────┘
                  │ (房主侧: TCP listen)     │ (房客侧: TCP connect 127.0.0.1)
                  ▼                         ▼
┌─────────────────────────────────────────────────────────────┐
│  Terracotta (Rust, libterracotta.a)                         │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ MinecraftScanner  房主侧: 监听 224.0.2.60:4445 UDP  │   │
│  │                   检测 MC 的 LAN 广播, 提取端口      │   │
│  ├─────────────────────────────────────────────────────┤   │
│  │ FakeServer        房客侧: 向 224.0.2.60:4445 广播   │   │
│  │                   "[MOTD]...[/MOTD][AD]port[/AD]"   │   │
│  │                   让 MC 客户端在多人游戏界面看到      │   │
│  ├─────────────────────────────────────────────────────┤   │
│  │ Scaffolding       TCP 13448, 自定义应用层协议        │   │
│  │ Server/Client     房主: server; 房客: client         │   │
│  │                   用于: 验证身份、交换 MC 端口、     │   │
│  │                        同步玩家列表                  │   │
│  ├─────────────────────────────────────────────────────┤   │
│  │ EasyTier          虚拟网络层 (no_tun + port_forward) │   │
│  │                   房主 IP: 10.144.144.1              │   │
│  │                   房客 IP: DHCP 分配 10.144.144.x    │   │
│  │                   端口转发: 127.0.0.1:local →        │   │
│  │                            10.144.144.1:remote       │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼ (EasyTier 隧道, TCP/UDP/KCP/P2P)
┌─────────────────────────────────────────────────────────────┐
│  EasyTier 公共入口节点 (4 个硬编码 + 动态拉取)              │
│  - tcp://public.easytier.top:11010                          │
│  - tcp://public2.easytier.cn:54321                          │
│  - https://etnode.zkitefly.eu.org/node1 → tcp://...         │
│  - https://etnode.zkitefly.eu.org/node2 → tcp://...         │
└─────────────────────────────────────────────────────────────┘
```

**关键设计**：Minecraft 客户端始终连接 `127.0.0.1`，不直接接触虚拟
网络。Terracotta 通过 EasyTier 的端口转发把 `127.0.0.1:<local>` 映射
到房主的 `10.144.144.1:<remote>`。这样 MC 客户端无需任何修改。

---

## 2. 房间码（邀请码）算法

源码：`src/controller/rooms/scaffolding/room.rs` 第 41-138 行。

### 2.1 生成

```rust
let mut bytes = [0u8; 16];
OsRng.try_fill_bytes(&mut bytes).unwrap();
let value = u128::from_be_bytes(bytes) % 34u128.pow(16);
let value = value - value % 7;  // 确保能被 7 整除（校验位）
```

1. 生成 128 位随机数
2. 对 `34^16` 取模（16 个 base-34 字符的容量）
3. 调整为 7 的倍数（mod-7 校验，防止手抄错码）

### 2.2 字符集

```
0123456789ABCDEFGHJKLMNPQRSTUVWXYZ
```

**34 个字符**，刻意**排除 I 和 O**（避免与 1 和 0 混淆）。解析时
`I → 1`、`O → 0` 容错（见 `lookup_char()`）。

### 2.3 编码为字符串

把 16 位 base-34 数 `value` 从低位到高位逐字符输出，每 4 个字符插
一个 `-`：

```
位置:  0  1  2  3  4  5  6  7  8  9  10 11 12 13 14 15
字符:  V0 V1 V2 V3 -  V4 V5 V6 V7 -  V8 V9 V10 V11 - V12 V13 V14 V15
```

最终格式：`U/V0V1V2V3-V4V5V6V7-V8V9V10V11-V12V13V14V15`

总长度 22 字符（`U/` + 16 字符 + 3 个 `-`）。

### 2.4 派生 network_name 和 network_secret

- **前 8 字符**（V0-V7）→ `network_name = "scaffolding-mc-V0V1V2V3-V4V5V6V7"`
- **后 8 字符**（V8-V15）→ `network_secret = "V8V9V10V11-V12V13V14V15"`

例：邀请码 `U/ABCD-EFGH-IJKL-MNOP`
- `network_name = "scaffolding-mc-ABCD-EFGH"`
- `network_secret = "IJKL-MNOP"`

**这就是邀请码能"自包含"地携带网络凭证的原理**——分享邀请码等于分享
network_name + network_secret，房客解析后即可加入同一个 EasyTier 网络。

### 2.5 解析与校验

`parse(code)` 流程：
1. 大写化
2. 滑动窗口找 `U/` 开头、长度 22 的子串
3. 逐字符用 `lookup_char()` 转 base-34 值，累加为 u128
4. 校验 `value % 7 == 0`，否则视为无效
5. 重新用 `from_value()` 生成标准形式（防止大小写/容错差异）

### 2.6 iOS 实现位置

iOS 端**不重新实现**这个算法——直接调用 Rust 的 `Room::from(code)`
（通过 `terracotta_ios_verify_room_code`）和 `Room::create()`（在
`controller::set_scanning` 内部调用）。保证 byte-for-byte 一致。

---

## 3. EasyTier 虚拟网络配置

源码：`src/controller/rooms/scaffolding/room.rs` 第 595-625 行
`compute_arguments()` + `start_host()` / `start_guest()`。

### 3.1 通用参数（房主和房客共用）

| 参数 | 值 | 说明 |
|---|---|---|
| `network_name` | `scaffolding-mc-{邀请码前8位}` | 从邀请码派生 |
| `network_secret` | `{邀请码后8位}` | 从邀请码派生 |
| `no_tun` | `true` | **不创建 TUN 设备**（关键！iOS 不需要 VPN 权限） |
| `latency_first` | `true` | 延迟优先路由 |
| `p2p_only` | `true` | 仅 P2P（不走中继节点转发数据） |
| `enable_kcp_proxy` | `true` | 启用 KCP 代理（改善丢包环境） |
| `multi_thread` | `true` | 多线程 |
| `data_compress_algo` | `2` (= zstd) | 数据压缩 |
| `listeners[0]` | `udp://0.0.0.0:0` | UDP 监听（随机端口） |
| `listeners[1]` | `tcp://0.0.0.0:0` | TCP 监听（随机端口） |
| `peer[]` | 4 个公共节点 + 动态节点 | 见第 8 节 |
| 加密 | EasyTier 默认（AES-256-GCM） | 未显式设置，用默认 |

对应的 TOML 配置（由 `linkage_impl.rs::create()` 生成）：

```toml
[network_identity]
network_name = "scaffolding-mc-ABCD-EFGH"
network_secret = "IJKL-MNOP"

[flags]
no_tun = true
latency_first = true
p2p_only = true
enable_kcp_proxy = true
multi_thread = true
data_compress_algo = 2

listeners = ["udp://0.0.0.0:0", "tcp://0.0.0.0:0"]

[[peer]]
uri = "tcp://public.easytier.top:11010"

[[peer]]
uri = "tcp://public2.easytier.cn:54321"

[[peer]]
uri = "https://etnode.zkitefly.eu.org/node1"

[[peer]]
uri = "https://etnode.zkitefly.eu.org/node2"
```

### 3.2 房主额外参数

```toml
ipv4 = "10.144.144.1"            # 固定虚拟 IP
hostname = "scaffolding-mc-server-13448"  # 房主标识，房客按此前缀查找
tcp_whitelist = ["13448", "<mc_port>"]    # 允许房客连接的端口
udp_whitelist = ["<mc_port>"]
```

**hostname 的魔法**：`scaffolding-mc-server-{scaffolding_port}`。
`scaffolding_port` 默认 13448（Scaffolding TCP 协议端口）。房客通过
EasyTier 的 `list_route` RPC 拿到所有 peer 的 hostname，按前缀
`scaffolding-mc-server-` 过滤，就能找到房主，并从 hostname 解析出
Scaffolding 端口。

### 3.3 房客额外参数

```toml
dhcp = true                       # DHCP 自动分配虚拟 IP
tcp_whitelist = ["0"]             # 不暴露任何端口
udp_whitelist = ["0"]
# port_forward 在运行时动态添加（见第 7 节）
```

### 3.4 为什么用 no_tun

- **桌面（HMCL）**：用 `--no-tun` + 命令行端口转发（`-f`）
- **Android（FCL/ZL2）**：用 `no_tun=true` + RPC 端口转发（虽然 Android
  有 VpnService，但 no_tun 模式更省事且兼容性更好）
- **iOS（本实现）**：用 `no_tun=true` + RPC 端口转发，**无需
  NEPacketTunnelProvider**，绕过 Apple 付费权限要求

四端实现完全一致，仅传输层细节不同。

---

## 4. Scaffolding TCP 应用层协议

源码：`src/scaffolding/server.rs` + `src/scaffolding/client.rs` +
`src/controller/rooms/scaffolding/protocols.rs`。

Scaffolding 是 Terracotta 自定义的轻量 RPC 协议，运行在 TCP 13448 上
（房主侧；房客通过 EasyTier port_forward 连接 `127.0.0.1:<本地随机端口>`
间接到达房主）。

### 4.1 报文格式

**请求（Client → Server）**：

```
+--------+------------------+--------+----------+
| 1 byte |   kind_size B    | 4 B BE |  body B  |
| kind_  |  "namespace:path"| body_  |  body    |
| size   |   (UTF-8)        | size   |          |
+--------+------------------+--------+----------+
```

- `kind_size`：1 字节，表示 `namespace:path` 字符串的字节长度
- `kind`：`namespace:path`，如 `c:ping`、`c:server_port`
- `body_size`：4 字节大端 u32，表示 body 字节长度
- `body`：负载（可为空，body_size=0）

**响应（Server → Client）**：

```
+--------+--------+----------+
| 1 B    | 4 B BE |  body B  |
| status | body_  |  body    |
|        | size   |          |
+--------+--------+----------+
```

- `status`：1 字节，0 = OK，其他 = 失败码
- `body_size`：4 字节大端 u32
- `body`：负载

### 4.2 命令列表

| namespace:path | body（请求） | body（响应） | 说明 |
|---|---|---|---|
| `c:ping` | 16 字节指纹 | 同样的 16 字节指纹 | 握手验证 |
| `c:protocols` | 空 | `n1:p1\0n2:p2\0...` | 列出所有支持的协议 |
| `c:server_port` | 空 | 2 字节 BE u16（MC 端口） | 查询房主 MC 端口 |
| `c:player_ping` | JSON `{machine_id, name, vendor}` | 空 | 房客心跳，刷新自己 |
| `c:player_profiles_list` | 空 | JSON array | 查询所有玩家列表 |

### 4.3 指纹（FINGERPRINT）

16 字节魔数，用于 `c:ping` 握手验证：

```
0x41, 0x57, 0x48, 0x44, 0x86, 0x37, 0x40, 0x59,
0x57, 0x44, 0x92, 0x43, 0x96, 0x99, 0x85, 0x01
```

房客连接 Scaffolding server 后发送 `c:ping` + 指纹，房主回传相同
指纹。房客校验回传数据 == 自己发送的数据，确认是合法的 Terracotta
房主（而非随机 TCP 服务）。

### 4.4 玩家档案 JSON

`c:player_ping` 请求 body：
```json
{
  "machine_id": "a1b2c3d4e5f6...",
  "name": "PlayerName",
  "vendor": "Terracotta 0.4.2, EasyTier v2.5.0-terracotta.2"
}
```

`c:player_profiles_list` 响应 body：
```json
[
  {
    "name": "HostPlayer",
    "machine_id": "a1b2c3d4...",
    "vendor": "Terracotta 0.4.2, ...",
    "kind": "HOST"
  },
  {
    "name": "Guest1",
    "machine_id": "e5f6a1b2...",
    "vendor": "Terracotta 0.4.2, ...",
    "kind": "GUEST"
  }
]
```

`kind` 取值：`HOST`（房主）、`LOCAL`（自己，房主响应中不会出现）、
`GUEST`（其他房客）。

### 4.5 machine_id

16 字节随机数，hex 编码（32 字符）。持久化到 `machine-id` 文件，
跨会话保持不变。用于区分不同玩家（即使改名也能识别）。

---

## 5. Minecraft 局域网发现（UDP 多播）

源码：`src/mc/fakeserver.rs` + `src/mc/scanning.rs`。

Minecraft Java Edition 的"对局域网开放"功能通过 UDP 多播发现服务器：

### 5.1 多播地址

- IPv4: `224.0.2.60:4445`
- IPv6: `[FF75:230::60]:4445`

### 5.2 广播消息格式

```
[MOTD]{motd文本}[/MOTD][AD]{端口号}[/AD]
```

例：
```
[MOTD]§6§l双击进入陶瓦联机大厅（请保持陶瓦运行）[/MOTD][AD]25565[/AD]
```

### 5.3 房主侧：MinecraftScanner

`MinecraftScanner` 监听 224.0.2.60:4445，收到 MC 的 LAN 广播后：
1. 解析 `[MOTD]...[/MOTD]` 提取 motd
2. 过滤掉自己 FakeServer 发的（motd == "§6§l双击进入..."）
3. 解析 `[AD]...[/AD]` 提取 MC 端口
4. 把端口写入共享状态，触发 `set_scanning` 启动 EasyTier

### 5.4 房客侧：FakeServer

`FakeServer` 每 1.5 秒向 224.0.2.60:4445 广播：
```
[MOTD]§6§l双击进入陶瓦联机大厅（请保持陶瓦运行）[/MOTD][AD]{local_port}[/AD]
```

这样房客的 Minecraft 客户端在"多人游戏"界面会自动看到这个"局域网
世界"，点击即可连接 `127.0.0.1:{local_port}`，而 `local_port` 已
被 EasyTier port_forward 到房主的 MC 服务器。

### 5.5 iOS 特殊注意

iOS 14+ 要求 App 显式声明 `NSBonjourServices` 包含 `_minecraft._tcp`
才能接收 UDP 多播（见 `patches/Info.plist.md`）。同时首次使用会弹
"本地网络权限"对话框。

---

## 6. 房主完整流程

源码：`src/controller/api.rs::set_scanning()` +
`src/controller/rooms/scaffolding/room.rs::start_host()`。

```
1. 用户在 Amethyst 联机页面点"创建房间"
   ↓
2. Obj-C 调用 terracotta_ios_set_scanning(nil, playerName)
   ↓
3. Rust controller::set_scanning():
   a. 状态 → HostScanning
   b. 启动 MinecraftScanner (UDP 224.0.2.60:4445)
   c. 异步获取公共节点列表
   ↓
4. 用户在 Minecraft 中按 ESC → "对局域网开放"
   MC 开始在某个端口（如 54321）监听 TCP，并向 224.0.2.60:4445 广播
   ↓
5. MinecraftScanner 收到广播，提取端口 54321
   ↓
6. controller 切换到 HostStarting 状态，调用 scaffolding::start_host():
   a. 生成房间码（或复用传入的）
   b. compute_arguments() 构造 EasyTier 参数:
      - network_name, network_secret 从房间码派生
      - ipv4 = 10.144.144.1
      - hostname = "scaffolding-mc-server-13448"
      - no_tun, latency_first, p2p_only, enable_kcp_proxy, ...
      - 4 个公共 peer
   c. easytier::create(args) 启动 EasyTier 实例
   d. 状态 → HostOk
   ↓
7. Scaffolding TCP Server 已在 13448 监听（在 step 3 之前就启动了）
   ↓
8. 后台线程每 5 秒:
   a. 检查 MC 连接是否还在 (TCP 连 127.0.0.1:54321 发 0xFE)
   b. 清理超过 10 秒未心跳的房客
   c. 检查 EasyTier 是否还活着
   ↓
9. Obj-C 轮询 terracotta_ios_get_state() 得到:
   {"state":"host-ok","room":"U/ABCD-...","profiles":[...]}
   显示邀请码给用户分享
```

---

## 7. 房客完整流程

源码：`src/controller/api.rs::set_guesting()` +
`src/controller/rooms/scaffolding/room.rs::start_guest()`。

```
1. 用户在 Amethyst 联机页面点"加入房间"，输入邀请码
   ↓
2. Obj-C 调用 terracotta_ios_verify_room_code(code) 校验格式
   ↓
3. Obj-C 调用 terracotta_ios_set_guesting(code, playerName)
   ↓
4. Rust controller::set_guesting():
   a. Room::from(code) 解析邀请码 → network_name, network_secret
   b. 状态 → GuestConnecting
   c. 异步获取公共节点
   d. 调用 scaffolding::start_guest()
   ↓
5. start_guest():
   a. compute_arguments() 构造 EasyTier 参数:
      - network_name, network_secret（同房主）
      - dhcp = true（自动获取虚拟 IP）
      - no_tun, latency_first, p2p_only, enable_kcp_proxy, ...
      - 4 个公共 peer
   b. easytier::create(args) 启动 EasyTier
   c. 状态 → GuestStarting
   ↓
6. 循环（最多 5 次，每次 3 秒）:
   a. 调用 EasyTier list_route RPC 获取所有 peer
   b. 找 hostname 以 "scaffolding-mc-server-" 开头的 peer
   c. 从 hostname 解析出 scaffolding_port (13448)
   d. 记住房主虚拟 IP (10.144.144.1)
   ↓
7. 找到房主后:
   a. 请求本地随机端口 local_scaffolding_port
   b. 调用 EasyTier patch_config RPC 添加 port_forward:
      127.0.0.1:local_scaffolding_port → 10.144.144.1:13448 (TCP)
   c. 状态保持 GuestStarting
   ↓
8. 循环（最多 60 次，每次 4 秒）: 连接 Scaffolding Server
   a. TCP connect 127.0.0.1:local_scaffolding_port
   b. 发送 c:ping + 16 字节指纹
   c. 校验响应 == 指纹
   d. 成功则进入下一步
   ↓
9. 发送 c:server_port 获取房主 MC 端口 (如 54321)
   ↓
10. 添加 MC port_forward:
    优先: 127.0.0.1:54321 → 10.144.144.1:54321 (TCP+UDP, IPv4+IPv6)
    回退: 127.0.0.1:<随机> → 10.144.144.1:54321
    ↓
11. 检查 MC 连接 (TCP 连 127.0.0.1:54321 发 0xFE 期待 0xFF 响应)
    ↓
12. 启动 FakeServer:
    每 1.5 秒向 224.0.2.60:4445 广播:
    [MOTD]§6§l双击进入陶瓦联机大厅（请保持陶瓦运行）[/MOTD][AD]54321[/AD]
    ↓
13. 状态 → GuestOk
    Obj-C 轮询得到:
    {"state":"guest-ok","url":"127.0.0.1:54365","profiles":[...]}
    （url 是实际本地端口，端口 25565 时省略）
    ↓
14. 用户在 Minecraft 多人游戏界面看到"陶瓦联机大厅"
    双击连接 → MC 连 127.0.0.1:54365 → port_forward → 10.144.144.1:54321
    ↓
15. 后台线程每 5 秒:
    a. 发送 c:player_ping (JSON {machine_id, name, vendor})
    b. 发送 c:player_profiles_list 获取所有玩家
    c. 更新本地玩家列表
    d. 检查 EasyTier 是否还活着
```

---

## 8. 公共入口节点

源码：`src/easytier/publics.rs` + `src/controller/api.rs`。

### 8.1 硬编码节点（4 个）

```
tcp://public.easytier.top:11010
tcp://public2.easytier.cn:54321
https://etnode.zkitefly.eu.org/node1
https://etnode.zkitefly.eu.org/node2
```

`https://` 节点会先 HTTP GET 获取真实 `tcp://` 地址（动态 IP，便于
故障转移）。

### 8.2 动态节点

HMCL/FCL/ZL2 还会请求 `https://terracotta.glavo.site/nodes` 获取
额外节点列表（JSON 数组），合并到上面 4 个之后。

iOS 端的 `TerracottaBridge.fetchPublicNodesWithCompletion:` 也请求
同一端点，但当前实现中**不传给 Rust**（因为 `terracotta_ios_set_scanning`
/ `set_guesting` 的 `public_nodes` 参数传的是空数组，Rust 会自动用 4
个硬编码节点）。如果将来需要支持自定义节点，可以扩展 C ABI 接受
`char **` 数组。

### 8.3 中国大陆地区过滤

HMCL 会根据用户所在地区过滤节点（避免墙内访问国外节点失败）。
Terracotta Rust 端本身不做过滤，由 Java/Kotlin 层处理。iOS 端目前
不做过滤，所有 4 个节点都会尝试。

---

## 9. 与 HMCL/FCL/ZL2 的互通保证

### 9.1 协议层 100% 一致

| 层 | HMCL/FCL/ZL2 | 本 iOS 实现 | 一致性 |
|---|---|---|---|
| 房间码算法 | burningtnt/Terracotta Rust | 同一份 Rust 代码 | 100% |
| EasyTier 配置 | compute_arguments() | 同一函数 | 100% |
| Scaffolding 协议 | protocols.rs + client.rs + server.rs | 同一文件 | 100% |
| FakeServer | mc/fakeserver.rs | 同一文件 | 100% |
| MinecraftScanner | mc/scanning.rs | 同一文件 | 100% |
| 公共节点 | easytier/publics.rs | 同一文件 | 100% |
| machine_id | controller/scaffolding/mod.rs | 同一文件 | 100% |

**核心保证**：iOS 端的 `libterracotta.a` 是 `burningtnt/Terracotta`
源码加 `lib_ios.rs`（C ABI 入口）编译的，**不重写任何协议代码**。
因此与 Android 端的 `libterracotta.so` 是同一份代码的两个编译目标。

### 9.2 唯一差异：VpnService 回调

Android 版的 `linkage_impl.rs` 会调用 `crate::on_vpnservice_change()`
触发 Java 层创建 VpnService + TUN fd。iOS 版的 `lib_ios.rs` 把这个
回调实现为 no-op（空函数），因为 iOS 用 `no_tun=true` 模式，不需要
TUN 设备。

但这个差异**不影响协议互通**，因为：
- `no_tun=true` 时 EasyTier 不创建 TUN，`on_vpnservice_change` 即使
  被调用也只是空操作
- Android 版的 `no_tun=true` 同样不依赖 VpnService（VpnService 仅在
  非 no_tun 模式下才需要）
- 实际上 Android 版 FCL/ZL2 也在 `no_tun=true` 模式下运行，
  `on_vpnservice_change` 被调用但 `EasyTierTunRequest.dest` 不会被
  写入有效 fd，Java 层的 VpnService 不实际建立

### 9.3 验证方法

在 macOS + Xcode 环境下构建 iOS App 后：

1. **房主测试**（iOS 端创建房间）：
   - iOS 创建房间 → 得到邀请码 `U/XXXX-...`
   - HMCL/FCL/ZL2 加入该邀请码 → 应能连接

2. **房客测试**（HMCL/FCL/ZL2 创建房间）：
   - HMCL 创建房间 → 得到邀请码
   - iOS 端加入该邀请码 → 应能连接

3. **混合测试**：
   - iOS 房主 + HMCL 房客 + FCL 房客 + ZL2 房客 → 应能 4 端联机

如果连接失败，排查步骤：
- 检查 iOS 是否有本地网络权限（设置 → 隐私 → 本地网络）
- 查看 `terracotta.log`（在 POJAV_HOME 下）
- 确认邀请码格式正确（`U/` 开头，22 字符）
- 确认双方都能访问至少一个公共节点（`tcp://public.easytier.top:11010`）

### 9.4 版本兼容性

Terracotta 版本：`0.4.2`（HMCL 当前下载版本）
EasyTier 版本：`v2.5.0-terracotta.2`（burningtnt fork）

iOS 构建必须用**同一版本**的 Terracotta + EasyTier fork，否则可能
协议不兼容。具体版本号在 Terracotta 的 `Cargo.toml` 和
`[package.metadata.easytier]` 中定义。

---

## 附录：源码文件索引

| 功能 | 源文件（burningtnt/Terracotta） |
|---|---|
| 房间码生成/解析 | `src/controller/rooms/scaffolding/room.rs` |
| Scaffolding 协议定义 | `src/controller/rooms/scaffolding/protocols.rs` |
| Scaffolding 客户端 | `src/scaffolding/client.rs` |
| Scaffolding 服务端 | `src/scaffolding/server.rs` |
| 玩家档案 | `src/scaffolding/profile.rs` |
| EasyTier 参数枚举 | `src/easytier/argument.rs` |
| EasyTier 库链接实现 | `src/easytier/linkage_impl.rs` |
| EasyTier 公共节点 | `src/easytier/publics.rs` |
| FakeServer (LAN 广播) | `src/mc/fakeserver.rs` |
| MinecraftScanner | `src/mc/scanning.rs` |
| 状态机 | `src/controller/states.rs` |
| HTTP API / 状态查询 | `src/controller/api.rs` |
| 端口分配 | `src/ports.rs` |
| Android JNI 入口 | `src/lib.rs` |
| **iOS C ABI 入口** | `src/lib_ios.rs`（本项目新增） |
