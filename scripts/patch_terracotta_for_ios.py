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
    """src/lib.rs: 把顶部 cfg(android) 改为 any(android, ios)，并把所有 JNI
    相关代码（use jni::*、try_jvm! 宏、JNI_OnLoad、jni_* 函数、logging_android、
    on_vpnservice_change、parse_jstring、VPN_SERVICE_CFG）用 #[cfg(target_os = "android")]
    包起来，使它们只在 Android 上编译。

    共享项（logging! 宏、ADDRESSES、MACHINE_ID_FILE、LOGGING_FD、模块声明）保留
    在 Android + iOS 上都编译。controller 模块通过 crate::MACHINE_ID_FILE 引用
    机器 ID 文件路径，因此 MACHINE_ID_FILE 必须在 iOS 上也存在。

    logging! 宏展开为 crate::logging_android(...)，被 mc/scaffolding/controller 等
    共享模块调用。因此 iOS 上必须也存在 logging_android（由本补丁添加一个 iOS 版本，
    写文件 + eprintln）。

    on_vpnservice_change 在 Android 上用 VPN_SERVICE_CFG，在 iOS 上由 lib_ios.rs
    定义为 no-op，通过 pub(crate) use lib_ios::on_vpnservice_change 重导出到 crate 根。
    """
    log("Patching Terracotta src/lib.rs ...")
    CFG_A = '#[cfg(target_os = "android")]'

    def gate(text: str, needle: str) -> str:
        """在 needle 前插入 CFG_A（如果还没有）。needle 必须在 text 中唯一。"""
        prefixed = CFG_A + '\n' + needle
        if prefixed in text:
            return text  # 已添加
        if needle not in text:
            return text  # 找不到，跳过
        return text.replace(needle, prefixed, 1)

    def transform(old: str) -> str:
        # 幂等检测：已有 jni 导入的 cfg 门控 + lib_ios 模块
        if 'mod lib_ios;' in old and (CFG_A + '\nuse jni::') in old:
            return None  # 已打补丁
        new = old

        # 1. 顶部 crate 级 cfg
        new = new.replace(
            '#![cfg(target_os = "android")]',
            '#![cfg(any(target_os = "android", target_os = "ios"))]',
            1,
        )

        # 2. 给 try_jvm! 宏加 cfg(android) — 它只在 jni_* 函数中使用
        new = gate(new, 'macro_rules! try_jvm {')

        # 3. 给 jni 导入加 cfg(android) — jni crate 只在 Android 上是依赖
        new = gate(new, 'use jni::signature::{Primitive, ReturnType};')
        new = gate(new, 'use jni::sys::JNI_VERSION_1_6;')
        new = gate(new, 'use jni::{objects::{JClass, JString}, sys::{jboolean, jint, jlong, jshort, jsize, jvalue, JNI_FALSE, JNI_TRUE}, JNIEnv, JavaVM, NativeMethod};')

        # 4. 给 VPN_SERVICE_CFG 加 cfg(android) — 只在 Android JNI 线程中使用
        new = gate(new, 'static VPN_SERVICE_CFG: Mutex<Option<crate::easytier::EasyTierTunRequest>> = Mutex::new(None);')

        # 5. 给 JNI_GetCreatedJavaVMs / JNI_OnLoad 加 cfg(android)
        #    这两个有 #[unsafe(no_mangle)] 在前面，需要加在 #[unsafe(no_mangle)] 之前
        new = gate(new, '#[unsafe(no_mangle)]\n#[allow(non_snake_case)]\nextern "system" fn JNI_GetCreatedJavaVMs')
        new = gate(new, '#[unsafe(no_mangle)]\n#[allow(non_snake_case)]\nextern "system" fn JNI_OnLoad')

        # 6. 给所有 jni_* 函数加 cfg(android)
        for fn_name in [
            'jni_start', 'jni_get_state', 'jni_set_waiting', 'jni_set_scanning',
            'jni_set_guesting', 'jni_verify_room_code', 'jni_get_metadata',
            'jni_prepare_export_logs', 'jni_finish_export_logs', 'jni_panic',
        ]:
            new = gate(new, 'extern "system" fn ' + fn_name)

        # 7. 给 logging_android 加 cfg(android) — Android 版用 __android_log_write
        new = gate(new, 'fn logging_android(line: String) {')

        # 8. 给 on_vpnservice_change 加 cfg(android) — iOS 版由 lib_ios.rs 提供
        new = gate(new, 'pub(crate) fn on_vpnservice_change(request: crate::easytier::EasyTierTunRequest) {')

        # 9. 给 parse_jstring 加 cfg(android) — 只在 jni_* 函数中使用
        new = gate(new, 'fn parse_jstring')

        # 10. 追加 iOS 支持：iOS 版 logging_android + lib_ios 模块 + on_vpnservice_change 重导出
        if 'mod lib_ios;' not in new:
            ios_block = (
                '\n'
                '// --- iOS support (auto-patched by patch_terracotta_for_ios.py) ---\n'
                '#[cfg(target_os = "ios")]\n'
                'fn logging_android(line: String) {\n'
                '    if let Ok(mut fd) = LOGGING_FD.lock() && let Some(fd) = fd.as_mut() {\n'
                '        let _ = fd.write_all(line.as_bytes());\n'
                '        let _ = fd.write_all(b"\\n");\n'
                '    }\n'
                '    eprintln!("[Terracotta] {}", line);\n'
                '}\n'
                '\n'
                '#[cfg(target_os = "ios")]\n'
                'mod lib_ios;\n'
                '\n'
                '#[cfg(target_os = "ios")]\n'
                'pub(crate) use lib_ios::on_vpnservice_change;\n'
            )
            new = new.rstrip() + '\n' + ios_block

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
    crate-type 改为 staticlib（iOS 不需要 cdylib，且 cdylib 链接时会因
    ___chkstk_darwin 未定义而失败）。"""
    log("Patching Terracotta Cargo.toml ...")
    def transform(old: str) -> str:
        # 幂等检测：已有 iOS target 块且 crate-type 只有 staticlib
        already_patched = (
            'cfg(any(target_os = "android", target_os = "ios"))' in old
            and 'crate-type = ["staticlib"]' in old
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
        # 2. crate-type: iOS 只用 staticlib。
        #    cdylib 在 iOS 上链接时会因 ___chkstk_darwin 未定义而失败
        #    （libclang_rt.ios.a 未被链接）。staticlib 不运行链接器，只归档 .o，
        #    最终链接由 Xcode 在编译 IPA 时完成（会正确链接 runtime）。
        if 'crate-type = ["cdylib", "staticlib"]' in new:
            new = new.replace('crate-type = ["cdylib", "staticlib"]', 'crate-type = ["staticlib"]', 1)
        elif 'crate-type = ["cdylib"]' in new:
            new = new.replace('crate-type = ["cdylib"]', 'crate-type = ["staticlib"]', 1)
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
