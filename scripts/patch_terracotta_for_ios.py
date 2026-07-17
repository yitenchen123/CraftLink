#!/usr/bin/env python3
# patch_terracotta_for_ios.py — 自动给 burningtnt/Terracotta + burningtnt/EasyTier
# fork 打补丁，使其支持 aarch64-apple-ios 编译（no_tun 模式）。
#
# 本脚本幂等：可以多次运行，已打过补丁的会跳过。
#
# 用法：
#   python3 patch_terracotta_for_ios.py <terracotta_dir> [easytier_dir]
#
# 如果不传 easytier_dir，脚本会尝试 Terracotta 的 Cargo.toml 里声明的
# git 依赖位置（通常在 ~/.cargo/git/checkouts/ 下），但更可靠的做法是
# 显式传入已 clone 的 EasyTier fork 目录。
#
# 补丁内容（与 rust/INSTRUCTIONS.md 对应）：
#   Terracotta 侧：
#     1. src/lib.rs: cfg(android) → cfg(any(android, ios))；Android 专用项包 #[cfg(android)]
#     2. src/easytier/mod.rs: iOS 也用 linkage_impl
#     3. Cargo.toml: easytier/toml/tokio/cidr 在 iOS 上也启用；crate-type 加 staticlib
#     4. src/lib_ios.rs: 复制本仓库 rust/src/lib_ios.rs
#   EasyTier 侧（no_tun 模式编译阻断修复）：
#     5. easytier/src/common/network.rs: InterfaceFilter 加 iOS impl（同 android，返回 true）

import os
import re
import shutil
import sys
from pathlib import Path

def log(msg: str) -> None:
    print(f"[patch] {msg}")

def patch_file(path: Path, transform) -> bool:
    """对文件应用 transform(old_content) -> new_content。返回是否修改。"""
    old = path.read_text(encoding="utf-8")
    new = transform(old)
    if new is None:
        return False
    if new == old:
        log(f"  skip (already patched): {path}")
        return False
    path.write_text(new, encoding="utf-8")
    log(f"  patched: {path}")
    return True

# ---------------------------------------------------------------------------
# Terracotta 补丁
# ---------------------------------------------------------------------------

def patch_terracotta_lib_rs(path: Path) -> None:
    """src/lib.rs: 把顶部 cfg(android) 改为 any(android, ios)，并把 Android
    专用项（jni 相关）用 #[cfg(target_os = "android")] 包起来。
    由于 lib.rs 里 Android 专用项很多，这里采用最小侵入策略：
    仅修改顶部 cfg，并把 on_vpnservice_change 的 Android 版本用 cfg 限制
    （iOS 版由 lib_ios.rs 重新定义为 no-op）。"""
    log("Patching Terracotta src/lib.rs ...")
    def transform(old: str) -> str:
        new = old
        # 1. 顶部 crate 级 cfg
        new = new.replace(
            '#![cfg(target_os = "android")]',
            '#![cfg(any(target_os = "android", target_os = "ios"))]',
            1,
        )
        # 2. on_vpnservice_change: Android 版必须排除 iOS，否则与 lib_ios.rs 重复定义
        #    给 pub(crate) fn on_vpnservice_change 加上 #[cfg(target_os = "android")]
        if 'pub(crate) fn on_vpnservice_change' in new and '#[cfg(target_os = "android")]\npub(crate) fn on_vpnservice_change' not in new:
            new = new.replace(
                'pub(crate) fn on_vpnservice_change',
                '#[cfg(target_os = "android")]\npub(crate) fn on_vpnservice_change',
                1,
            )
        # 3. 追加 lib_ios 模块声明（如果还没有）
        if 'mod lib_ios;' not in new:
            new = new.rstrip() + '\n\n#[cfg(target_os = "ios")]\nmod lib_ios;\n'
        return new
    patch_file(path, transform)

def patch_terracotta_easytier_mod_rs(path: Path) -> None:
    """src/easytier/mod.rs: iOS 也用 linkage_impl（库链接，不 spawn 子进程）。"""
    log("Patching Terracotta src/easytier/mod.rs ...")
    def transform(old: str) -> str:
        if 'target_os = "ios"' in old:
            return None  # 已打补丁
        # 直接字符串替换（不用 regex，避免被 {initialize, cleanup} 里的 } 破坏）
        old_block = (
            'if #[cfg(not(target_os = "android"))] {\n'
            '        mod executable_impl;\n'
            '        use executable_impl as inner;\n'
            '\n'
            '        pub use inner::{initialize, cleanup};\n'
            '    } else {\n'
            '        mod linkage_impl;\n'
            '        use linkage_impl as inner;\n'
            '\n'
            '        pub use inner::EasyTierTunRequest;\n'
            '    }'
        )
        new_block = (
            'if #[cfg(any(target_os = "android", target_os = "ios"))] {\n'
            '        mod linkage_impl;\n'
            '        use linkage_impl as inner;\n'
            '\n'
            '        pub use inner::EasyTierTunRequest;\n'
            '    } else {\n'
            '        mod executable_impl;\n'
            '        use executable_impl as inner;\n'
            '\n'
            '        pub use inner::{initialize, cleanup};\n'
            '    }'
        )
        if old_block in old:
            return old.replace(old_block, new_block, 1)
        return old
    patch_file(path, transform)

def patch_terracotta_cargo_toml(path: Path) -> None:
    """Cargo.toml: 让 easytier/toml/tokio/cidr 在 iOS 上也启用；
    crate-type 加 staticlib（iOS 只支持 staticlib）。"""
    log("Patching Terracotta Cargo.toml ...")
    def transform(old: str) -> str:
        # 幂等检测：已有 iOS target 块且 staticlib，则跳过
        already_patched = (
            'cfg(any(target_os = "android", target_os = "ios"))' in old
            and 'staticlib' in old
        )
        if already_patched:
            return None
        new = old
        # 1. 把 [target.'cfg(target_os = "android")'.dependencies] 块拆成
        #    Android+iOS 共用 + jni 仅 Android
        old_block = (
            '[target.\'cfg(target_os = "android")\'.dependencies]\n'
            'easytier = { git = "https://github.com/burningtnt/EasyTier.git", branch = "main"}\n'
            'jni = { version = "0.21.1", features = ["invocation"] }\n'
            '# These libraries are the necessities to interact with EasyTier. DO NOT upgrade their version.\n'
            'uuid = "1"\n'
            'toml = "0"\n'
            'tokio = "1"\n'
            'cidr = { version = "0", features = ["serde"] }'
        )
        new_block = (
            '[target.\'cfg(any(target_os = "android", target_os = "ios"))\'.dependencies]\n'
            'easytier = { git = "https://github.com/burningtnt/EasyTier.git", branch = "main"}\n'
            '# These libraries are the necessities to interact with EasyTier. DO NOT upgrade their version.\n'
            'uuid = "1"\n'
            'toml = "0"\n'
            'tokio = "1"\n'
            'cidr = { version = "0", features = ["serde"] }\n'
            '\n'
            '[target.\'cfg(target_os = "android")\'.dependencies]\n'
            'jni = { version = "0.21.1", features = ["invocation"] }'
        )
        if old_block in new:
            new = new.replace(old_block, new_block, 1)
        # 2. crate-type: iOS 只支持 staticlib（cdylib 在 iOS 上不行）
        if 'crate-type = ["cdylib"]' in new:
            new = new.replace(
                'crate-type = ["cdylib"]',
                'crate-type = ["cdylib", "staticlib"]',
                1,
            )
        return new
    patch_file(path, transform)

def patch_terracotta_build_rs(path: Path) -> None:
    """build.rs: iOS 也跳过下载 EasyTier 可执行文件（用 linkage_impl 库链接，
    不需要 easytier-core 二进制）。Android 已在第 184 行 return，iOS 需同样处理。"""
    log("Patching Terracotta build.rs ...")
    def transform(old: str) -> str:
        if '("ios"' in old:
            return None  # 已打补丁
        # 第 184 行：Android 的 return 分支，扩展为包含 iOS
        old_line = '("android", "arm") | ("android", "aarch64") | ("android", "x86") | ("android", "x86_64") => return,'
        new_line = '("android", "arm") | ("android", "aarch64") | ("android", "x86") | ("android", "x86_64") | ("ios", "aarch64") | ("ios", "x86_64") | ("ios", "x86") => return,'
        if old_line in old:
            return old.replace(old_line, new_line, 1)
        return old
    patch_file(path, transform)

def copy_lib_ios_rs(terracotta_dir: Path, script_dir: Path) -> None:
    """把 rust/src/lib_ios.rs 复制到 Terracotta/src/lib_ios.rs。"""
    # script_dir 是 scripts/，其上一级是仓库根，再进 rust/src/
    src = script_dir.parent / "rust" / "src" / "lib_ios.rs"
    dst = terracotta_dir / "src" / "lib_ios.rs"
    log(f"Copying {src} -> {dst}")
    shutil.copy2(src, dst)

# ---------------------------------------------------------------------------
# EasyTier 补丁
# ---------------------------------------------------------------------------

def patch_easytier_network_rs(path: Path) -> None:
    """easytier/src/common/network.rs: InterfaceFilter 加 iOS impl（同 android）。

    no_tun 模式下 collect_interfaces 仍会被调用，但 iOS 上没有 InterfaceFilter
    impl 会编译失败。iOS 行为同 android（直接返回 true，不过滤）。
    """
    log("Patching EasyTier easytier/src/common/network.rs ...")
    def transform(old: str) -> str:
        # 把 android/ohos 的 cfg 扩展为包含 ios
        old_cfg = '#[cfg(any(target_os = "android", target_env = "ohos"))]\nimpl InterfaceFilter {'
        new_cfg = '#[cfg(any(target_os = "android", target_os = "ios", target_env = "ohos"))]\nimpl InterfaceFilter {'
        if old_cfg in old:
            return old.replace(old_cfg, new_cfg, 1)
        if 'target_os = "ios"' in old:
            return None  # 已打补丁
        return old
    patch_file(path, transform)

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def find_easytier_in_cargo(terracotta_dir: Path) -> Path | None:
    """尝试从 Terracotta 的 Cargo.lock 找 EasyTier 的 checkout 路径。
    不可靠，仅作回退。"""
    lock = terracotta_dir / "Cargo.lock"
    if not lock.exists():
        return None
    # EasyTier 通常在 ~/.cargo/git/checkouts/EasyTier-*/ 下
    cargo_git = Path.home() / ".cargo" / "git" / "checkouts"
    if not cargo_git.exists():
        return None
    for d in sorted(cargo_git.iterdir()):
        if d.name.startswith("EasyTier-"):
            # 取最新的子目录
            subs = sorted(d.iterdir())
            if subs:
                return subs[-1]
    return None

def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    terracotta_dir = Path(sys.argv[1]).resolve()
    if not terracotta_dir.exists():
        log(f"ERROR: Terracotta dir not found: {terracotta_dir}")
        return 1

    easytier_dir = None
    if len(sys.argv) >= 3:
        easytier_dir = Path(sys.argv[2]).resolve()
        if not easytier_dir.exists():
            log(f"ERROR: EasyTier dir not found: {easytier_dir}")
            return 1

    script_dir = Path(__file__).resolve().parent

    # --- Terracotta 补丁 ---
    patch_terracotta_lib_rs(terracotta_dir / "src" / "lib.rs")
    patch_terracotta_easytier_mod_rs(terracotta_dir / "src" / "easytier" / "mod.rs")
    patch_terracotta_cargo_toml(terracotta_dir / "Cargo.toml")
    patch_terracotta_build_rs(terracotta_dir / "build.rs")
    copy_lib_ios_rs(terracotta_dir, script_dir)

    # --- EasyTier 补丁 ---
    if easytier_dir is None:
        easytier_dir = find_easytier_in_cargo(terracotta_dir)
        if easytier_dir is None:
            log("WARNING: EasyTier dir not provided and not found in cargo cache.")
            log("         network.rs patch skipped. Build may fail on iOS target.")
            log("         Re-run with: python3 patch_terracotta_for_ios.py <terracotta> <easytier>")
        else:
            log(f"Found EasyTier checkout: {easytier_dir}")
    if easytier_dir is not None:
        net_rs = easytier_dir / "easytier" / "src" / "common" / "network.rs"
        if net_rs.exists():
            patch_easytier_network_rs(net_rs)
        else:
            log(f"WARNING: {net_rs} not found (EasyTier repo layout may differ)")

    log("Done. Next: cargo +nightly build --lib --release --target aarch64-apple-ios")
    return 0

if __name__ == "__main__":
    sys.exit(main())
