#!/bin/bash
set -euo pipefail

# Build NIF for a given Linux target inside Docker.
# Two-phase build:
#   Phase 1: Build custom V8 archive from rusty_v8 repo with shared-library-compatible TLS.
#            Always uses x86_64 container (Chromium toolchain is x86_64-only).
#            Cross-compiles for arm64 targets.
#   Phase 2: Build the NIF using the custom V8 archive on the target platform.
#
# Usage: ./scripts/docker-build.sh <target>

TARGET="${1:?Usage: $0 <target>}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
V8_TAG="v146.4.0"

case "$TARGET" in
  x86_64-unknown-linux-gnu)   PLATFORM="linux/amd64"; RUST_TARGET="x86_64-unknown-linux-gnu" ;;
  aarch64-unknown-linux-gnu)  PLATFORM="linux/arm64"; RUST_TARGET="aarch64-unknown-linux-gnu" ;;
  *) echo "Unsupported target: $TARGET"; exit 1 ;;
esac

ARCHIVE_DIR="/tmp/v8-archives"
ARCHIVE_FILE="$ARCHIVE_DIR/librusty_v8_${TARGET}.a"
mkdir -p "$ARCHIVE_DIR"

echo "=== Phase 1: Build V8 archive for $TARGET ==="
if [ -f "$ARCHIVE_FILE" ]; then
  echo "Archive already exists at $ARCHIVE_FILE, skipping Phase 1"
else
  # Always build V8 in x86_64 container - Chromium toolchain is x86_64-only.
  # For arm64 targets, Chromium clang cross-compiles natively.
  docker run --rm \
    --platform "linux/amd64" \
    -v "$ARCHIVE_DIR":/output \
    -e V8_TAG="$V8_TAG" \
    -e RUST_TARGET="$RUST_TARGET" \
    ubuntu:24.04 bash -exc '
      export DEBIAN_FRONTEND=noninteractive

      # Install build deps
      apt-get update
      apt-get install -y --no-install-recommends \
        curl ca-certificates build-essential python3 ninja-build git \
        pkg-config libglib2.0-dev wget software-properties-common gnupg lsb-release

      # Install LLVM 20 for bindgen (V8 libc++ headers require Clang 20+)
      wget -qO /tmp/llvm.sh https://apt.llvm.org/llvm.sh
      chmod +x /tmp/llvm.sh
      /tmp/llvm.sh 20
      export LIBCLANG_PATH=/usr/lib/llvm-20/lib

      # Install Rust with the target
      curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.92.0
      export PATH="$HOME/.cargo/bin:$PATH"
      rustup target add "$RUST_TARGET"

      # Install cross-compilation linker for arm64 if needed
      if [ "$RUST_TARGET" = "aarch64-unknown-linux-gnu" ]; then
        apt-get install -y gcc-aarch64-linux-gnu
      fi

      # Clone rusty_v8
      echo "=== Cloning rusty_v8 at $V8_TAG ==="
      git clone --depth 1 --branch "$V8_TAG" --recurse-submodules \
        https://github.com/denoland/rusty_v8.git /v8build
      cd /v8build

      # Set up cross-compilation cargo config for arm64
      if [ "$RUST_TARGET" = "aarch64-unknown-linux-gnu" ]; then
        mkdir -p .cargo
        printf "[target.aarch64-unknown-linux-gnu]\nlinker = \"aarch64-linux-gnu-gcc\"\n" > .cargo/config.toml
      fi

      # Build V8 from source with shared-library-compatible TLS model.
      # v8_monolithic_for_shared_library=true defines V8_TLS_USED_IN_LIBRARY
      # which changes TLS model from local-exec to local-dynamic.
      export V8_FROM_SOURCE=1
      export EXTRA_GN_ARGS="v8_monolithic=true v8_monolithic_for_shared_library=true"

      echo "=== Building V8 for $RUST_TARGET (this takes 30-60 min) ==="
      echo "EXTRA_GN_ARGS: $EXTRA_GN_ARGS"
      # Build may fail at bindgen (Chromium libc++ vs system libclang),
      # but librusty_v8.a is produced before that step.
      cargo build --release --target "$RUST_TARGET" 2>&1 || true

      # Copy the archive out
      ARCHIVE=$(find target/"$RUST_TARGET"/release/gn_out -name "librusty_v8.a" 2>/dev/null | head -1)
      if [ -z "$ARCHIVE" ]; then
        # Also check non-target path
        ARCHIVE=$(find target/release/gn_out -name "librusty_v8.a" 2>/dev/null | head -1)
      fi
      if [ -z "$ARCHIVE" ]; then
        echo "ERROR: librusty_v8.a not found!"
        find target/ -name "librusty_v8*" 2>/dev/null
        exit 1
      fi

      cp "$ARCHIVE" /output/librusty_v8_'"$TARGET"'.a
      echo "=== V8 archive saved ==="
      ls -lh /output/librusty_v8_'"$TARGET"'.a
    '
fi

echo "=== Phase 2: Build NIF for $TARGET using custom V8 archive ==="

CARGO_DIR="/tmp/docker-cargo-nif-${TARGET}"
RUSTUP_DIR="/tmp/docker-rustup-nif-${TARGET}"
OUTPUT_DIR="/tmp/tyrex-nif-output"
mkdir -p "$CARGO_DIR" "$RUSTUP_DIR" "$OUTPUT_DIR"

docker run --rm \
  --platform "$PLATFORM" \
  -v "$PROJECT_DIR":/build:ro \
  -v "$ARCHIVE_DIR":/v8-archives:ro \
  -v "$CARGO_DIR":/cargo \
  -v "$RUSTUP_DIR":/rustup \
  -v "$OUTPUT_DIR":/output \
  -w /work \
  -e CARGO_HOME=/cargo \
  -e RUSTUP_HOME=/rustup \
  -e "RUSTY_V8_ARCHIVE=/v8-archives/librusty_v8_${TARGET}.a" \
  -e RUSTLER_NIF_VERSION=2.16 \
  ubuntu:24.04 bash -exc '
    cp -a /build/native/tyrex/* /work/
    cp -a /build/native/tyrex/.cargo /work/ 2>/dev/null || true

    apt-get update
    apt-get install -y --no-install-recommends \
      curl ca-certificates build-essential pkg-config libglib2.0-dev \
      wget software-properties-common gnupg

    # Install LLVM 20 for bindgen (V8 libc++ headers require Clang 20+)
    wget -qO /tmp/llvm.sh https://apt.llvm.org/llvm.sh
    chmod +x /tmp/llvm.sh
    /tmp/llvm.sh 20
    export LIBCLANG_PATH=/usr/lib/llvm-20/lib

    curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.92.0
    export PATH="$CARGO_HOME/bin:$PATH"

    echo "=== Using custom V8 archive: $RUSTY_V8_ARCHIVE ==="
    ls -lh "$RUSTY_V8_ARCHIVE"

    echo "=== Building NIF ==="
    cargo build --release --target '"$TARGET"' 2>&1

    OUTFILE="target/'"$TARGET"'/release/libtyrex.so"
    if [ -f "$OUTFILE" ]; then
      echo "=== SUCCESS ==="
      ls -lh "$OUTFILE"
      file "$OUTFILE" 2>/dev/null || true

      # Verify no TPOFF32 in the output
      apt-get install -y -qq binutils > /dev/null 2>&1 || true
      TPOFF=$(readelf -r "$OUTFILE" 2>/dev/null | grep -c TPOFF32 || true)
      echo "TPOFF32 relocations in output: $TPOFF"

      cp "$OUTFILE" /output/libtyrex_'"$TARGET"'.so
      echo "=== Output copied to /output ==="
    else
      echo "=== FAILED ==="
      exit 1
    fi
  '
