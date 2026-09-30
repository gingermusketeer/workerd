#!/usr/bin/env bash
# Build workerd natively against musl inside an Alpine container using podman.
#
# Usage:
#   build/musl/build.sh image                # build the container image
#   build/musl/build.sh bazel <args...>      # run bazel inside the container
#   build/musl/build.sh shell [-c cmd]       # shell (or command) inside the container
#   build/musl/build.sh workerd              # build //src/workerd/server:workerd and copy it out
#
# Environment:
#   WORKERD_MUSL_IMAGE   image tag (default: localhost/workerd-musl-build)
#   WORKERD_MUSL_CACHE   host directory for bazel output/repository caches
#                        (default: ~/.cache/workerd-musl)
#   EXTRA_CA_BUNDLE      PEM bundle to add to the image trust store, e.g. a TLS-intercepting
#                        proxy's CA (default: none). The certificates stay in the image.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)"
IMAGE="${WORKERD_MUSL_IMAGE:-localhost/workerd-musl-build}"
CACHE="${WORKERD_MUSL_CACHE:-$HOME/.cache/workerd-musl}"
PODMAN="${PODMAN:-podman}"

build_image() {
  local ctx
  ctx="$(mktemp -d)"
  trap 'rm -rf "$ctx"' RETURN
  cp "$HERE/Containerfile" "$ctx/"
  if [[ -n "${EXTRA_CA_BUNDLE:-}" ]]; then
    cp "$EXTRA_CA_BUNDLE" "$ctx/extra-ca.crt"
  else
    : > "$ctx/extra-ca.crt"
  fi
  "$PODMAN" build -t "$IMAGE" "$ctx"
}

run() {
  mkdir -p "$CACHE"
  local tty=()
  [[ -t 0 && -t 1 ]] && tty=(-it)
  "$PODMAN" run --rm "${tty[@]}" \
    -v "$SRC:/workerd" \
    -v "$CACHE:/root/.cache" \
    -w /workerd \
    "$IMAGE" "$@"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  image) build_image ;;
  shell) run bash "$@" ;;
  bazel) run bazel "$@" ;;
  workerd)
    run bash -c 'bazel build --config=opt "$@" //src/workerd/server:workerd \
      && mkdir -p /workerd/bazel-musl-out \
      && cp -fL bazel-bin/src/workerd/server/workerd /workerd/bazel-musl-out/workerd' _ "$@"
    echo "Built: $SRC/bazel-musl-out/workerd"
    ;;
  *)
    sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
    exit 1
    ;;
esac
