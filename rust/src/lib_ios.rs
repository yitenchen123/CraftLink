// lib_ios.rs — iOS C ABI entry point for Terracotta (陶瓦联机)
//
// This file is added to the `burningtnt/Terracotta` fork to expose the SAME
// controller / scaffolding / easytier logic that HMCL / FCL / ZalithLauncher2
// use on desktop and Android, but behind a C ABI instead of JNI.
//
// Protocol compatibility: 100% identical to HMCL/FCL/ZalithLauncher2, because
// the actual room-code, scaffolding, easytier-config and port-forward code is
// the very same `controller::set_scanning` / `set_guesting` / `Room::from` /
// `scaffolding::start_host` / `scaffolding::start_guest` functions that the
// Android `libterracotta.so` ships. We only swap the JNI bindings for C ABI
// and drop the VpnService callback (iOS runs EasyTier with `no_tun = true`,
// port-forward only — see PROTOCOL.md).
//
// How to integrate into a Terracotta fork:
//   1. Replace `#![cfg(target_os = "android")]` in src/lib.rs with
//      `#![cfg(any(target_os = "android", target_os = "ios"))]`.
//   2. Move the existing JNI code into `#[cfg(target_os = "android")]` blocks.
//   3. Add `#[cfg(target_os = "ios")] mod lib_ios;` (or `path = "lib_ios.rs"`).
//   4. Patch src/easytier/mod.rs so iOS also uses `linkage_impl` (see
//      rust/INSTRUCTIONS.md).
//   5. Patch Cargo.toml so the `easytier`/`toml`/`tokio`/`cidr` deps that are
//      currently `cfg(target_os = "android")` are also enabled on iOS.
//
// All functions use the `terracotta_ios_*` C ABI prefix and are declared in
// `Natives/terracotta/terracotta.h` for the Objective-C side to call.

#![cfg(target_os = "ios")]

use std::ffi::{CStr, CString};
use std::os::fd::FromRawFd;
use std::os::raw::{c_char, c_int};
use std::path::PathBuf;
use std::thread;

use crate::controller::{self, Room, RoomKind};
use crate::easytier::EasyTierTunRequest;
// 使用 crate 根的 MACHINE_ID_FILE / LOGGING_FD（与 controller 模块共享同一个 static），
// 而不是在此重新定义。否则 terracotta_ios_start 设置的是 lib_ios 的副本，
// controller::rooms::scaffolding 读的是 crate::MACHINE_ID_FILE，两者不一致。
use crate::{LOGGING_FD, MACHINE_ID_FILE};

// ---------------------------------------------------------------------------
// Global state (mirrors the Android side of src/lib.rs)
// ---------------------------------------------------------------------------

/// iOS does NOT use a system VPN / NEPacketTunnelProvider.
/// EasyTier is launched with `no_tun = true` and only uses `port_forward` to
/// bridge `127.0.0.1:<local>` <-> `10.144.144.1:<remote>` over the virtual
/// network. Therefore the VpnService callback from `linkage_impl.rs` is a
/// no-op on iOS. (linkage_impl.rs still polls the local virtual IP and calls
/// this function; we simply drop the request.)
pub(crate) fn on_vpnservice_change(_req: EasyTierTunRequest) {
    // intentionally empty — iOS port-forward mode needs no TUN fd.
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

fn terracotta_log(line: &str) {
    use std::io::Write;
    if let Ok(mut guard) = LOGGING_FD.lock() {
        if let Some(file) = guard.as_mut() {
            let _ = file.write_all(line.as_bytes());
            let _ = file.write_all(b"\n");
        }
    }
    // Also forward to stderr so it shows up in Console.app / Xcode debugger.
    eprintln!("[Terracotta-iOS] {}", line);
}

// ---------------------------------------------------------------------------
// C ABI functions
// ---------------------------------------------------------------------------

/// Initialize Terracotta.
///
/// `dir`         - UTF-8 path to a writable directory (POJAV_HOME). A
///                  `machine-id` file will be created here to persist the
///                  player's identity across launches (same semantics as
///                  Android's `start0(dir, loggingFd)`).
/// `logging_fd`  - a writable file descriptor for log output, or -1 to
///                  disable file logging (logs will still go to stderr).
///
/// Returns 0 on success, negative on failure.
#[unsafe(no_mangle)]
pub extern "C" fn terracotta_ios_start(
    dir: *const c_char,
    logging_fd: c_int,
) -> c_int {
    std::panic::set_backtrace_style(std::panic::BacktraceStyle::Full);

    if logging_fd >= 0 {
        // SAFETY: caller guarantees `logging_fd` is a valid, owned, writable fd.
        let file = unsafe { std::fs::File::from_raw_fd(logging_fd) };
        let _ = LOGGING_FD.lock().unwrap().replace(file);
    }

    terracotta_log(&format!(
        "Welcome using Terracotta v{}, Easytier: {}. Target: ios.",
        env!("TERRACOTTA_VERSION"),
        env!("TERRACOTTA_ET_VERSION"),
    ));

    if !dir.is_null() {
        if let Ok(s) = unsafe { CStr::from_ptr(dir) }.to_str() {
            let path = PathBuf::from(s).join("machine-id");
            let _ = MACHINE_ID_FILE.set(path);
        }
    }

    // Start the Scaffolding TCP server on port 13448 (same as desktop/Android).
    // This must be initialized lazily before any host/guest session starts,
    // because `start_host` references `*SCAFFOLDING_PORT`.
    thread::spawn(|| {
        lazy_static::initialize(&controller::SCAFFOLDING_PORT);
    });

    0
}

/// Get the current AppState as a JSON string.
///
/// The returned string is heap-allocated and MUST be freed by the caller via
/// `terracotta_ios_free_string`. Returns null on failure.
///
/// JSON schema matches the Android `getState0()` output exactly, e.g.:
///   {"state":"waiting","index":0}
///   {"state":"host-ok","index":N,"room":"U/XXXX-...","profile_index":M,"profiles":[...]}
///   {"state":"guest-ok","index":N,"url":"127.0.0.1:25565","profile_index":M,"profiles":[...]}
///   {"state":"exception","index":N,"type":2}
#[unsafe(no_mangle)]
pub extern "C" fn terracotta_ios_get_state() -> *mut c_char {
    let state = controller::get_state();
    match serde_json::to_string(&state) {
        Ok(s) => CString::new(s)
            .map(|c| c.into_raw())
            .unwrap_or(std::ptr::null_mut()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Transition to Waiting state. Idempotent.
#[unsafe(no_mangle)]
pub extern "C" fn terracotta_ios_set_waiting() {
    controller::set_waiting();
}

/// Host: begin scanning for a Minecraft "Open to LAN" world on the local
/// machine. Once a LAN broadcast is detected, Terracotta will generate (or
/// reuse) a room code, start EasyTier as host (10.144.144.1), and transition
/// to `host-ok`.
///
/// `room`    - optional UTF-8 room code to reuse; pass null to generate one.
/// `player`  - optional player name; pass null for "Terracotta Anonymous Host".
#[unsafe(no_mangle)]
pub extern "C" fn terracotta_ios_set_scanning(
    room: *const c_char,
    player: *const c_char,
) {
    let room = cstr_to_option_string(room);
    let player = cstr_to_option_string(player);
    // public_nodes = []: Terracotta's `fetch_public_nodes` will still merge
    // the 4 hardcoded public peers (see src/easytier/publics.rs), matching
    // HMCL/FCL/ZalithLauncher2 behavior.
    controller::set_scanning(room, player, vec![]);
}

/// Guest: join an existing room. Returns 1 if the join was initiated
/// successfully, 0 if the room code is invalid or Terracotta is not in the
/// Waiting state.
///
/// `room`    - required UTF-8 room code (e.g. "U/ABCD-EFGH-IJKL-MNOP").
/// `player`  - optional player name; pass null for "Terracotta Anonymous Guest".
#[unsafe(no_mangle)]
pub extern "C" fn terracotta_ios_set_guesting(
    room: *const c_char,
    player: *const c_char,
) -> c_int {
    let room_str = match cstr_to_option_string(room) {
        Some(s) => s,
        None => return 0,
    };
    let player = cstr_to_option_string(player);

    match Room::from(&room_str) {
        Some(room) => {
            if controller::set_guesting(room, player, vec![]) {
                1
            } else {
                0
            }
        }
        None => 0,
    }
}

/// Verify a room code without joining.
///
/// Returns:
///   3  — SCAFFOLDING room (the only type currently implemented; same return
///         value as Android `verifyRoomCode0`).
///  -1  — invalid / unrecognised code.
#[unsafe(no_mangle)]
pub extern "C" fn terracotta_ios_verify_room_code(
    code: *const c_char,
) -> c_int {
    let code = match cstr_to_option_string(code) {
        Some(s) => s,
        None => return -1,
    };
    match Room::from(&code) {
        Some(Room { kind, .. }) => match kind {
            RoomKind::Scaffolding { .. } => 3,
        },
        None => -1,
    }
}

/// Get metadata as a NUL-delimited UTF-8 string:
///   "<version>\0<compile_timestamp_ms>\0<easytier_version>"
///
/// Same format as Android `getMetadata0`. Must be freed via
/// `terracotta_ios_free_string`.
#[unsafe(no_mangle)]
pub extern "C" fn terracotta_ios_get_metadata() -> *mut c_char {
    let metadata = format!(
        "{}\0{}\0{}",
        env!("TERRACOTTA_VERSION"),
        timestamp::compile_time!() as i64,
        env!("TERRACOTTA_ET_VERSION"),
    );
    // CString::new will fail if there's an interior NUL — but we deliberately
    // put interior NULs here, so we must build it from a byte vector instead.
    let bytes = metadata.into_bytes();
    // SAFETY: we append a terminator NUL and the content is valid UTF-8.
    let cstr = unsafe { CString::from_vec_unchecked(bytes) };
    cstr.into_raw()
}

/// Free a string previously returned by `terracotta_ios_get_state`,
/// `terracotta_ios_get_metadata`, etc. Passing null is a no-op.
#[unsafe(no_mangle)]
pub extern "C" fn terracotta_ios_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        // SAFETY: `ptr` was produced by `CString::into_raw` above.
        unsafe { drop(CString::from_raw(ptr)) };
    }
}

/// Trigger a manual panic (for testing the panic handler / log capture).
#[unsafe(no_mangle)]
pub extern "C" fn terracotta_ios_panic() {
    panic!("User triggered panic manually.");
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn cstr_to_option_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: caller guarantees `ptr` points to a valid NUL-terminated UTF-8
    // C string that remains valid for the duration of this call.
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .ok()
        .map(|s| s.to_string())
}
