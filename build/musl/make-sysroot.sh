#!/usr/bin/env bash
# Builds the two archives that musl builds (`--config=linux_musl`) take as Bazel repositories:
#
#   musl-sysroot-alpine<ver>-x86_64.tar.xz    Alpine's musl, kernel headers and libucontext.
#   llvm-runtimes-<ver>-x86_64-linux-musl.tar.xz
#                                             LLVM's libc++, libc++abi, libunwind and compiler-rt
#                                             builtins, built for musl against that sysroot, laid
#                                             out like an LLVM release's target directories.
#
# Both are built in an Alpine container (podman), so this needs no musl on the host. Builds
# themselves don't run this: they download the published archives (see build/deps/llvm.MODULE.bazel).
#
# Usage: build/musl/make-sysroot.sh [output-dir]   (default: bazel-musl-dist)
#
# Environment:
#   EXTRA_CA_BUNDLE   PEM bundle mounted as the container's trust store, e.g. a TLS-intercepting
#                     proxy's CA (default: none).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$(realpath -m "${1:-bazel-musl-dist}")"
PODMAN="${PODMAN:-podman}"

# musl builds link statically, so this only sets the musl version they contain.
ALPINE_SYSROOT_VERSION=3.23
# Must match the hermetic toolchain's llvm_version (build/deps/llvm.MODULE.bazel). The build image's
# clang must be the same release, since its resource headers ship in the runtimes archive.
LLVM_VERSION=22.1.8
LLVM_SHA256=922f1817a0df7b1489272d18134ee0087a8b068828f87ac63b9861b1a9965888

mkdir -p "$OUT"
ca=()
if [[ -n "${EXTRA_CA_BUNDLE:-}" ]]; then
  ca=(-v "$(realpath "$EXTRA_CA_BUNDLE"):/etc/ssl/certs/ca-certificates.crt:ro")
fi

"$PODMAN" run --rm "${ca[@]}" \
  -v "$OUT:/out" \
  -v "$HERE/make-sysroot-inner.sh:/make-sysroot-inner.sh:ro" \
  -e ALPINE_SYSROOT_VERSION="$ALPINE_SYSROOT_VERSION" \
  -e LLVM_VERSION="$LLVM_VERSION" \
  -e LLVM_SHA256="$LLVM_SHA256" \
  docker.io/library/alpine:edge sh /make-sysroot-inner.sh

(cd "$OUT" && sha256sum ./*.tar.xz)
