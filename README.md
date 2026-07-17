# CraftLink

iOS 端 Minecraft Java 跨平台联机 App，与 **HMCL / PCL-CE / FCL / ZalithLauncher2** 的「陶瓦联机」协议 100% 互通。

## 这是什么

CraftLink 是一个**独立 App**，与 [Amethyst-iOS](https://github.com/AngelAuraMC/Amethyst-iOS)（官方）或 [Amethyst-iOS-MyRemastered](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered)（改版）一起使用：

1. 在 Amethyst-iOS 里启动 Minecraft Java 版
2. 在 MC 内点「对局域网开放」
3. 打开 CraftLink 创建房间，把邀请码发给朋友
4. 朋友用任意支持陶瓦联机的启动器（HMCL/FCL/ZL2/CraftLink）输入邀请码加入
5. 朋友在 MC「直接连接」里输入 `127.0.0.1:25565`（或 CraftLink 显示的地址）

## 架构（v2.0 — 重写版）

旧版 CraftLink 用 `NEPacketTunnelProvider` + EasyTier 原始 FFI，必须申请 `com.apple.developer.networking.networkextension` 权限，普通开发者证书 / TrollStore 难以获取，且协议参数与 HMCL/FCL/ZL2 不一致。

**新版架构**直接调用 [burningtnt/Terracotta](https://github.com/burningtnt/Terracotta) 的 Rust 实现（与 HMCL/FCL/ZL2 同源），通过 `terracotta_ios_*` C ABI：

```
┌─────────────────────────────────────────────────────────────┐
│                      CraftLink (SwiftUI)                     │
│                                                              │
│  Views ──→ TerracottaManager ──→ TerracottaBridge (Swift)    │
│                                      │                       │
│                                      │ terracotta_ios_* C ABI│
│                                      ▼                       │
│                          libterracotta.a (Rust 静态库)        │
│                          ┌───────────────────────────┐       │
│                          │ controller (set_scanning/ │       │
│                          │   set_guesting/set_waiting)│      │
│                          │ scaffolding (TCP 13448)   │       │
│                          │ easytier (no_tun +        │       │
│                          │   port_forward)           │       │
│                          └───────────────────────────┘       │
│                                      │                       │
│                                      ▼                       │
│                           127.0.0.1:25565 ◄─── MC 客户端      │
└─────────────────────────────────────────────────────────────┘
```

**关键改动**：

| 项目 | 旧版 | 新版 |
|---|---|---|
| 网络权限 | `networkextension` (NE) | **无** — 只用 loopback |
| EasyTier 模式 | TUN fd（需 PacketTunnel） | `no_tun=true` + `port_forward` |
| Scaffolding 协议 | Swift 手写实现 | **Rust 同源**（与 HMCL/FCL/ZL2 一致） |
| 房主虚拟 IP | `10.0.0.1`（错） | `10.144.144.1`（对，与 Terracotta 一致） |
| Scaffolding 端口 | MC 端口（错） | 固定 `13448`（对） |
| Hostname | `scaffolding-mc-server-{port}`（错） | `scaffolding-mc-server-13448`（对） |
| EasyTier flags | 缺失 | `no_tun`、`latency_first`、`p2p_only`、`enable_kcp_proxy`、`multi_thread`、`zstd` 全开 |
| 后台保活 | 无 | SilentAudioPlayer（`UIBackgroundModes: audio`） |

## 构建

### 1. 编译 `libterracotta.a`（一次性）

CraftLink 链接 `RustLib/libterracotta.a`，需要先从 Terracotta 源码编译。

> **注意**：[`burningtnt/Terracotta`](https://github.com/burningtnt/Terracotta) 上游**只支持 Android / 桌面**，没有 iOS target。本仓库的 [`rust/`](rust/) 目录里包含了让 Terracotta 支持 iOS 所需的全部补丁文件，必须先按下面步骤应用到你的 Terracotta fork。

```bash
# 1. Clone burningtnt/Terracotta
git clone https://github.com/burningtnt/Terracotta.git
cd Terracotta

# 2. 按 rust/INSTRUCTIONS.md 打补丁（10 步，精确到行号）
#    - src/lib.rs: 启用 iOS target (cfg(any(android, ios)))
#    - 把 rust/src/lib_ios.rs 复制到 Terracotta/src/lib_ios.rs（iOS C ABI 入口）
#    - src/easytier/mod.rs: iOS 也用 linkage_impl（库链接，不 spawn 子进程）
#    - Cargo.toml: easytier/toml/tokio/cidr 在 iOS 上也启用；crate-type 加 staticlib
#    - Android 专用项（jni/JNI_OnLoad/on_vpnservice_change）用 #[cfg(android)] 包起来

# 3. 安装 Rust nightly + iOS target
rustup toolchain install nightly
rustup component add rust-src --toolchain nightly
rustup target add aarch64-apple-ios --toolchain nightly

# 4. 编译（device slice）
cargo +nightly build --lib --release --target aarch64-apple-ios

# 5. 拷贝到 CraftLink 项目
cp target/aarch64-apple-ios/release/libterracotta.a /path/to/CraftLink/RustLib/
```

完整脚本（含 simulator slices、xcframework 组装、Troubleshooting）见 [`scripts/build_ios.sh`](scripts/build_ios.sh)；补丁步骤见 [`rust/INSTRUCTIONS.md`](rust/INSTRUCTIONS.md)；协议解析见 [`docs/PROTOCOL.md`](docs/PROTOCOL.md)。

### 2. 用 XcodeGen 生成 Xcode 工程并构建

```bash
brew install xcodegen
cd CraftLink
xcodegen generate

xcodebuild build \
  -project CraftLink.xcodeproj \
  -scheme CraftLink \
  -sdk iphoneos \
  -configuration Release \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

或直接用 Xcode 打开 `CraftLink.xcodeproj`，选你的设备，按 ⌘B 构建。

### 3. 安装到设备

- **TrollStore**（推荐）：把构建出的 `.app` 打包成 `.ipa`，用 TrollStore 安装。无需签名，无需 NE 权限。
- **SideStore / AltStore**：用免费开发者证书签名安装。
- **越狱设备**：直接 SSH 拷贝 `.app` 到 `/Applications/`。

## 自动构建（GitHub Actions）

推 `v*` tag（如 `v2.0.0`）触发 CI 自动出未签名 IPA：

1. 先按「编译 libterracotta.a」步骤构建一次 `libterracotta.a`
2. 上传到自己的 GitHub Release，tag 用 `v2.0.0-lib`
3. 修改 `.github/workflows/build.yml` 中的下载 URL
4. 推 `v2.0.0` tag → CI 自动构建 IPA 并发布到 Release

## 与 HMCL/FCL/ZL2 的协议兼容性

CraftLink 调用的是 **同一份** `burningtnt/Terracotta` Rust 代码：

- `controller::set_scanning` → 房主扫描 MC 局域网广播
- `controller::set_guesting` → 访客加入
- `Room::from` → 邀请码解析（base-34 + mod-7 校验，`U/NNNN-NNNN-SSSS-SSSS`）
- `scaffolding::start_host` / `start_guest` → Scaffolding TCP 协议（端口 13448）
- `easytier::linkage_impl` → EasyTier 网络实例（`no_tun=true` + `port_forward`）

协议参数与 [`Terracotta/src/controller/rooms/scaffolding/room.rs`](https://github.com/burningtnt/Terracotta/blob/main/src/controller/rooms/scaffolding/room.rs) 的 `DEFAULT_ARGUMENTS` 完全一致：

```rust
Argument::NoTun,
Argument::Compression("zstd"),
Argument::MultiThread,
Argument::LatencyFirst,
Argument::EnableKcpProxy,
Argument::Listener { address: ..., proto: Proto::UDP },
Argument::Listener { address: ..., proto: Proto::TCP },
Argument::P2POnly,
```

房主额外附加：`HostName("scaffolding-mc-server-13448")`、`IPv4(10.144.144.1)`、`TcpWhitelist(13448)`、`TcpWhitelist(port)`、`UdpWhitelist(port)`。

因此邀请码、虚拟 IP、Scaffolding 端口、hostname、EasyTier flags **全部与 HMCL/FCL/ZL2 一致**，可直连互通。

## 后台保活

iOS 上 App 切到后台会被系统冻结，虚拟网络随即断开。CraftLink 用「静音音频」保活：

- `Info.plist` 声明 `UIBackgroundModes: [audio]`
- 房间运行期间 `SilentAudioPlayer` 循环播放 200ms 的近静音 WAV（50Hz 正弦波，-50dB）
- 退到后台时系统认为「在播音乐」，允许 App 继续跑 EasyTier + port_forward

## 项目结构

```
CraftLink/
├── App/
│   ├── AppDelegate.swift
│   └── CraftLinkApp.swift          # SwiftUI 入口，注入 TerracottaManager
├── Services/
│   ├── TerracottaBridge.swift      # terracotta_ios_* C ABI 的 Swift 封装
│   ├── TerracottaManager.swift     # 房间生命周期、状态轮询、后台保活
│   ├── SilentAudioPlayer.swift     # 后台保活（AVAudioPlayer + 静音 WAV）
│   └── Constants.swift             # UI 显示用常量（IP/端口等）
├── Views/
│   ├── ContentView.swift
│   ├── LobbyView.swift             # 主页
│   ├── CreateRoomView.swift        # 房主
│   ├── JoinRoomView.swift          # 访客
│   └── SettingsView.swift          # 设置/历史/Terracotta 元数据
├── Models/
│   └── RoomHistory.swift           # 历史房间记录
├── Utils/
│   ├── BlurView.swift
│   └── Color+Hex.swift
├── Natives/
│   ├── CraftLink-Bridging-Header.h # 引入 terracotta.h
│   └── terracotta/
│       └── terracotta.h            # libterracotta.a 的 C ABI 头
├── rust/                           # ← Terracotta iOS 补丁（上游无 iOS 支持）
│   ├── src/lib_ios.rs              # iOS C ABI 入口（terracotta_ios_*）
│   └── INSTRUCTIONS.md             # 打补丁步骤（10 步，精确到行号）
├── scripts/
│   └── build_ios.sh                # 编译 libterracotta.a / .xcframework
├── docs/
│   └── PROTOCOL.md                 # 陶瓦联机协议解析文档
├── RustLib/
│   └── libterracotta.a             # ← 用户构建后放入
├── CraftLink.entitlements          # 空（无 NE 权限）
├── Info.plist                      # 含 UIBackgroundModes: audio
└── project.yml                     # XcodeGen 配置
```

## License

参见 [LICENSE](LICENSE)。

## 致谢

- [burningtnt/Terracotta](https://github.com/burningtnt/Terracotta) — 陶瓦联机协议原作者，本项目的 Rust 后端
- [EasyTier](https://github.com/EasyTier/EasyTier) — 虚拟网络层
- [HMCL](https://github.com/HMCL-dev/HMCL) / [FCL](https://github.com/FCL-Team/FoldCraftLauncher) / [ZalithLauncher2](https://github.com/ZalithLauncher/ZalithLauncher2) — 桌面/Android 端陶瓦联机实现，协议参考
- [Amethyst-iOS](https://github.com/AngelAuraMC/Amethyst-iOS) — iOS 上的 Minecraft Java 启动器
