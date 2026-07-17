#!/usr/bin/env bash
# build_ios.sh — Build libterracotta.a for iOS (aarch64) and assemble an
# .xcframework that can be dropped into the Amethyst-iOS Xcode/CMake project.
#
# PREREQUISITES (run on a macOS host, NOT Linux):
#   1. Xcode 15+ with iOS 17.5 SDK
#   2. Rust nightly toolchain:
#        rustup toolchain install nightly
#        rustup component add rust-src --toolchain nightly
#        rustup target add aarch64-apple-ios --toolchain nightly
#        rustup target add aarch64-apple-ios-sim --toolchain nightly
#        rustup target add x86_64-apple-ios --toolchain nightly   # for older sims
#   3. cargo-lipo is NOT needed (Rust 1.64+ has built-in lipo via `cargo build --target`).
#
# USAGE:
#   cd /path/to/Amethyst-Terracotta-iOS
#   ./scripts/build_ios.sh
#
# OUTPUT:
#   build/ios/libterracotta.xcframework   ← drop this into Xcode/CMake
#
# This script assumes you have already:
#   - Cloned burningtnt/Terracotta into ../Terracotta (sibling dir)
#   - Applied the patches in rust/INSTRUCTIONS.md to that Terracotta fork
#   - Copied rust/src/lib_ios.rs into ../Terracotta/src/lib_ios.rs
#
# If your Terracotta fork lives elsewhere, set TERRACOTTA_DIR env var.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${PROJECT_ROOT}/build/ios"

# Default to a sibling Terracotta checkout; allow override via env var.
TERRACOTTA_DIR="${TERRACOTTA_DIR:-${PROJECT_ROOT}/../Terracotta}"

if [[ ! -d "${TERRACOTTA_DIR}" ]]; then
    echo "ERROR: Terracotta fork not found at: ${TERRACOTTA_DIR}"
    echo "Clone it with:"
    echo "  git clone https://github.com/burningtnt/Terracotta.git ${TERRACOTTA_DIR}"
    echo "Then apply the patches described in rust/INSTRUCTIONS.md"
    exit 1
fi

if [[ ! -f "${TERRACOTTA_DIR}/src/lib_ios.rs" ]]; then
    echo "ERROR: ${TERRACOTTA_DIR}/src/lib_ios.rs not found."
    echo "Copy rust/src/lib_ios.rs from this project into your Terracotta fork."
    exit 1
fi

# iOS targets to build. aarch64-apple-ios is for device; the other two are
# for simulator (needed to run Amethyst-iOS in the iOS Simulator).
TARGETS=(
    "aarch64-apple-ios"        # device (arm64)
    "aarch64-apple-ios-sim"    # simulator on Apple Silicon
    "x86_64-apple-ios"         # simulator on Intel
)

mkdir -p "${OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# Step 1: Build libterracotta.a for each iOS target
# ---------------------------------------------------------------------------

cd "${TERRACOTTA_DIR}"

echo "==> Using Rust toolchain:"
rustup show active-toolchain || true

for target in "${TARGETS[@]}"; do
    echo ""
    echo "==> Building libterracotta.a for ${target}..."
    cargo +nightly build \
        --lib \
        --release \
        --target "${target}"

    STATIC_LIB="target/${target}/release/libterracotta.a"
    if [[ ! -f "${STATIC_LIB}" ]]; then
        echo "ERROR: expected ${STATIC_LIB} but it was not produced."
        echo "       Common causes:"
        echo "         - Nightly Rust feature flags not available (update nightly)"
        echo "         - easytier fork doesn't compile on iOS (see TROUBLESHOOTING below)"
        echo "         - Missing rust-src component: rustup component add rust-src --toolchain nightly"
        exit 1
    fi
    echo "    -> ${STATIC_LIB}"
done

# ---------------------------------------------------------------------------
# Step 2: Assemble .xcframework
# ---------------------------------------------------------------------------

echo ""
echo "==> Assembling libterracotta.xcframework..."

# Clean stale output
rm -rf "${OUTPUT_DIR}/libterracotta.xcframework"

# Build the xcodebuild -create-xcframework argument list
XCARGS=()
for target in "${TARGETS[@]}"; do
    STATIC_LIB="${TERRACOTTA_DIR}/target/${target}/release/libterracotta.a"
    if [[ "${target}" == "aarch64-apple-ios" ]]; then
        XCARGS+=("-library" "${STATIC_LIB}" "-headers" "${PROJECT_ROOT}/Natives/terracotta")
    else
        # simulator slices: still pass -library; xcodebuild figures out the
        # platform from the archive's metadata, or use -library + -headers.
        XCARGS+=("-library" "${STATIC_LIB}" "-headers" "${PROJECT_ROOT}/Natives/terracotta")
    fi
done

xcodebuild -create-xcframework \
    "${XCARGS[@]}" \
    -output "${OUTPUT_DIR}/libterracotta.xcframework"

echo ""
echo "==> Success! xcframework at:"
echo "    ${OUTPUT_DIR}/libterracotta.xcframework"
echo ""
echo "Next: integrate into Amethyst-iOS — see patches/ and README.md."

# ---------------------------------------------------------------------------
# TROUBLESHOOTING
# ---------------------------------------------------------------------------
# 
# Problem: easytier crate fails to compile for aarch64-apple-ios with errors
#          like "could not compile easytier-...".
# Cause:   burningtnt/EasyTier fork may have Android-specific code that lacks
#          iOS cfg branches, or uses APIs unavailable on iOS.
# Fix:     Clone the EasyTier fork:
#            git clone -b main https://github.com/burningtnt/EasyTier.git
#          Apply iOS patches similar to the ones EasyTier upstream already
#          has (search for `cfg(target_os = "ios")` in the upstream repo).
#          Common spots needing iOS cfg:
#            - easytier/src/instance/virtual_nic.rs  (already has iOS branch upstream)
#            - easytier/src/connector/mod.rs
#            - easytier/src/common/network.rs
#          Then point Terracotta's Cargo.toml at your patched EasyTier:
#            easytier = { git = "file:///path/to/your/EasyTier-fork", branch = "main" }
#
# Problem: "feature `unsafe_cell_access` is required" or similar nightly error.
# Fix:     rustup update nightly && rustup component add rust-src --toolchain nightly
#
# Problem: Linker error about missing symbols for iOS Simulator.
# Fix:     Make sure you build ALL three targets (aarch64-apple-ios-sim and
#          x86_64-apple-ios for simulator; aarch64-apple-ios for device).
#
# Problem: "unsupported output type" when building cdylib for iOS.
# Fix:     iOS only supports staticlib (not cdylib). Cargo.toml's
#          `crate-type = ["cdylib"]` line should be patched to:
#          `crate-type = ["staticlib", "cdylib"]`
#          or conditionally for iOS:
#          `crate-type = ["staticlib"]` when target_os = "ios".
#          See rust/INSTRUCTIONS.md step 5.
