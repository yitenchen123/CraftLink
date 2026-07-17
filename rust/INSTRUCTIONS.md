# 如何修改 burningtnt/Terracotta 仓库以支持 iOS

本目录的 `src/lib_ios.rs` 是新增文件，需要应用到 Terracotta fork 上。以下是精确的修改步骤。

## 0. 前置：Fork 并克隆

```bash
git clone https://github.com/burningtnt/Terracotta.git
cd Terracotta
git checkout master
```

## 1. 添加新文件

把本仓库的 `rust/src/lib_ios.rs` 复制到 Terracotta 仓库根目录的 `src/lib_ios.rs`。

## 2. 修改 `src/lib.rs`

把第 10 行的：
```rust
#![cfg(target_os = "android")]
```
改成：
```rust
#![cfg(any(target_os = "android", target_os = "ios"))]
```

然后在文件末尾（`fn parse_jstring` 之前或之后均可）追加一行模块声明：
```rust
#[cfg(target_os = "ios")]
mod lib_ios;
```

注意：lib.rs 里现有的所有 `extern "system" fn jni_*`、`JNI_OnLoad`、`JNI_GetCreatedJavaVMs`、`logging_android`、`on_vpnservice_change`、`VPN_SERVICE_CFG`、`MACHINE_ID_FILE`、`LOGGING_FD` 都依赖 `jni` crate。这些在 iOS 上不需要。有两种处理方式：

**方式 A（推荐，最小侵入）**：把这些 Android 专用项整体用 `#[cfg(target_os = "android")]` 包起来。具体做法是用 `#[cfg(target_os = "android")]` 标注：
- `use jni::*` 那一组导入
- `static MACHINE_ID_FILE` / `static LOGGING_FD` / `static VPN_SERVICE_CFG`
- `fn JNI_GetCreatedJavaVMs` / `fn JNI_OnLoad` / 所有 `fn jni_*` / `fn logging_android` / `pub(crate) fn on_vpnservice_change` / `fn parse_jstring`

注意：`pub(crate) fn on_vpnservice_change` 在 iOS 上由 `lib_ios.rs` 重新定义为 no-op（见 lib_ios.rs 第 55 行），所以 Android 版的那个定义必须被 `#[cfg(target_os = "android")]` 排除掉，否则会重复定义。

**方式 B（替代）**：保留 lib.rs 不动，单独写一个 `src/lib_ios.rs` 作为完全独立的 crate 入口，并在 `Cargo.toml` 里用 `[lib] path` 配合 `#[cfg(target_os = "ios")]` 切换。这样较复杂，不推荐。

## 3. 修改 `src/easytier/mod.rs`

把第 10-22 行的 `cfg_if!` 块从：
```rust
cfg_if! {
    if #[cfg(not(target_os = "android"))] {
        mod executable_impl;
        use executable_impl as inner;
        pub use inner::{initialize, cleanup};
    } else {
        mod linkage_impl;
        use linkage_impl as inner;
        pub use inner::EasyTierTunRequest;
    }
}
```
改成：
```rust
cfg_if! {
    if #[cfg(any(target_os = "android", target_os = "ios"))] {
        mod linkage_impl;
        use linkage_impl as inner;
        pub use inner::EasyTierTunRequest;
    } else {
        mod executable_impl;
        use executable_impl as inner;
        pub use inner::{initialize, cleanup};
    }
}
```

原因：iOS 上不能 spawn `easytier-core` 子进程（沙盒限制），必须像 Android 一样把 easytier 作为库链接进来，通过 `TomlConfigLoader + NetworkInstance::new` 直接启动。这就是 `linkage_impl.rs` 做的事。

## 4. 修改 `src/main.rs`

`main.rs` 顶部有 `#![cfg(any(target_os = "windows", target_os = "linux", target_os = "macos", target_os = "freebsd"))]`，已经排除了 iOS，**不用改**。iOS target 只编译 `[lib]`（cdylib），不编译 `[[bin]]`。

## 5. 修改 `Cargo.toml`

把第 51-58 行的 Android 专用依赖：
```toml
[target.'cfg(target_os = "android")'.dependencies]
easytier = { git = "https://github.com/burningtnt/EasyTier.git", branch = "main"}
jni = { version = "0.21.1", features = ["invocation"] }
uuid = "1"
toml = "0"
tokio = "1"
cidr = { version = "0", features = ["serde"] }
```

改成同时支持 Android 和 iOS（注意 `jni` 只在 Android 需要）：
```toml
[target.'cfg(any(target_os = "android", target_os = "ios"))'.dependencies]
easytier = { git = "https://github.com/burningtnt/EasyTier.git", branch = "main" }
uuid = "1"
toml = "0"
tokio = "1"
cidr = { version = "0", features = ["serde"] }

[target.'cfg(target_os = "android")'.dependencies]
jni = { version = "0.21.1", features = ["invocation"] }
```

## 6. 关于 `linkage_impl.rs` 的一个小调整

`linkage_impl.rs` 的 `create()` 函数末尾会启动一个 tokio 任务，周期性调用 `crate::on_vpnservice_change(...)`（第 176-213 行）。在 iOS 上这个调用是 no-op（lib_ios.rs 已定义），所以**不需要修改**。EasyTier 仍会正常启动，只是不创建 TUN 设备（因为 `no_tun = true`，见 `room.rs::compute_arguments`）。

## 7. 关于 `local-ip-address` crate

`lib.rs` 第 66-95 行的 `ADDRESSES` lazy_static 用了 `local_ip_address::list_afinet_netifas()`。这个 crate 在 iOS 上可以正常工作（它支持 iOS），不需要修改。

## 8. 关于 `rocket` crate

`main.rs` 用了 `#[macro_use] extern crate rocket;`，但 `lib.rs`（Android/iOS 入口）**没有**用 rocket。Android 版 lib.rs 顶部也没有 `extern crate rocket;`。所以 iOS 编译时不会链接 rocket，没问题。

## 9. 验证

修改完成后，在 macOS 上执行：
```bash
rustup toolchain install nightly
rustup target add aarch64-apple-ios --toolchain nightly
cargo +nightly build --target aarch64-apple-ios --lib --release
```

应该生成 `target/aarch64-apple-ios/release/libterracotta.a`。如果遇到 easytier 编译错误，可能需要给 easytier fork 也添加 iOS 兼容补丁（见 `scripts/build_ios.sh` 的注释）。

## 10. 关键设计决策回顾

| 决策 | 理由 |
|---|---|
| 复用 Terracotta 原版 Rust 代码 | 保证协议 100% 与 HMCL/FCL/ZL2 一致 |
| iOS 用 `linkage_impl`（库链接）而非 `executable_impl`（子进程） | iOS 沙盒禁止 spawn 子进程 |
| iOS 用 `no_tun = true` + port_forward | 避免 NEPacketTunnelProvider 需要 Apple 付费权限 |
| iOS 不调用 VpnService | 无 VPN，`on_vpnservice_change` 是 no-op |
| C ABI 而非 JNI | iOS 无 JNI，Obj-C 通过 C ABI 调用 Rust |
| 复用 `controller::set_scanning` / `set_guesting` | 房间码生成、EasyTier 配置、Scaffolding 协议、FakeServer 全部由原版代码处理 |
