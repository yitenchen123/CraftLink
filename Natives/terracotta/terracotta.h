/*
 * terracotta.h — C ABI declarations for libterracotta.a (iOS build of
 * burningtnt/Terracotta with the lib_ios.rs patch).
 *
 * This header is consumed by the Swift bridge via the project bridging header
 * (`CraftLink-Bridging-Header.h`). All string pointers are UTF-8 NUL-terminated.
 * Strings returned from the Rust side MUST be freed with
 * terracotta_ios_free_string.
 */
#ifndef TERRACOTTA_H
#define TERRACOTTA_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Initialize Terracotta. Must be called once before any other function.
 *
 *   dir         UTF-8 path to a writable directory (usually POJAV_HOME).
 *               A `machine-id` file is created here to persist the player
 *               identity across launches.
 *   logging_fd  a writable file descriptor for log output, or -1 to
 *               disable file logging.
 *
 * Returns 0 on success.
 */
int terracotta_ios_start(const char *dir, int logging_fd);

/*
 * Get the current AppState as a JSON string. Heap-allocated; MUST be freed
 * with terracotta_ios_free_string. Returns NULL on failure.
 *
 * JSON schema (mirrors Android getState0):
 *   {"state":"waiting","index":0}
 *   {"state":"host-scanning","index":N}
 *   {"state":"host-starting","index":N,"room":"U/XXXX-..."}
 *   {"state":"host-ok","index":N,"room":"U/XXXX-...","profile_index":M,"profiles":[...]}
 *   {"state":"guest-connecting","index":N,"room":"U/XXXX-..."}
 *   {"state":"guest-starting","index":N,"room":"U/XXXX-...","difficulty":"EASIEST"}
 *   {"state":"guest-ok","index":N,"url":"127.0.0.1:25565","profile_index":M,"profiles":[...]}
 *   {"state":"exception","index":N,"type":2}
 *
 * Exception types:
 *   0 = PingHostFail, 1 = PingHostRst, 2 = GuestEasytierCrash,
 *   3 = HostEasytierCrash, 4 = PingServerRst, 5 = ScaffoldingInvalidResponse
 *
 * Difficulty values: "UNKNOWN" | "EASIEST" | "SIMPLE" | "MEDIUM" | "TOUGH"
 */
char *terracotta_ios_get_state(void);

/* Transition to Waiting state. Idempotent. */
void terracotta_ios_set_waiting(void);

/*
 * Host: begin scanning for a Minecraft "Open to LAN" world on the local
 * machine. Once detected, Terracotta generates (or reuses) a room code,
 * starts EasyTier as host (10.144.144.1), and transitions to host-ok.
 *
 *   room    optional room code to reuse; pass NULL to generate one.
 *   player  optional player name; pass NULL for "Terracotta Anonymous Host".
 */
void terracotta_ios_set_scanning(const char *room, const char *player);

/*
 * Guest: join an existing room.
 *
 *   room    required room code (e.g. "U/ABCD-EFGH-IJKL-MNOP").
 *   player  optional player name; pass NULL for "Terracotta Anonymous Guest".
 *
 * Returns 1 if join was initiated, 0 if the code is invalid or Terracotta
 * is not in the Waiting state.
 */
int terracotta_ios_set_guesting(const char *room, const char *player);

/*
 * Verify a room code without joining.
 * Returns 3 for SCAFFOLDING type (the only currently supported), -1 invalid.
 */
int terracotta_ios_verify_room_code(const char *code);

/*
 * Get metadata as NUL-delimited UTF-8:
 *   "<version>\0<compile_timestamp_ms>\0<easytier_version>"
 * Heap-allocated; MUST be freed with terracotta_ios_free_string.
 */
char *terracotta_ios_get_metadata(void);

/* Free a string returned by terracotta_ios_get_state / _get_metadata. */
void terracotta_ios_free_string(char *ptr);

/* Trigger a manual panic (for testing). */
void terracotta_ios_panic(void);

#ifdef __cplusplus
}
#endif

#endif /* TERRACOTTA_H */
