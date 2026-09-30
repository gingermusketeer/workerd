# Native musl (Alpine) builds

`build.sh` builds workerd against musl inside an Alpine container using podman. The resulting
binary runs on stock Alpine with no glibc compatibility layer: its only dependency is
`libc.musl-x86_64.so.1`.

```sh
build/musl/build.sh image      # build the build image (Alpine edge + bazel + LLVM 22)
build/musl/build.sh workerd    # build workerd; output: bazel-musl-out/workerd
build/musl/build.sh bazel test --config=opt //src/workerd/api/tests:encoding-test@
build/musl/build.sh shell      # interactive shell in the build container
```

Bazel output and repository caches live in `~/.cache/workerd-musl` (override with
`WORKERD_MUSL_CACHE`). Behind a TLS-intercepting proxy, set `EXTRA_CA_BUNDLE` to a PEM file with
the proxy's CA when building the image, for example
`EXTRA_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt build/musl/build.sh image`. The certificates
become part of the image.

## How it works

- **C++**: Alpine's clang 22 and lld, picked up by Bazel's autodetected toolchain, which
  `--config=linux_musl` registers ahead of the hermetic LLVM toolchain (whose sysroot and libc++
  are glibc), and links libc++ statically. libc++ is built in the image from the matching LLVM
  release: Alpine's own libc++ is from a different release and its static archives aren't
  position-independent, so they can't go into the shared libraries Bazel links for `cc_library`
  targets. The `linux` config applies as usual;
  `--config=linux_musl` (`.bazelrc`) adds the musl-specific pieces. The image's
  `/etc/bazel.bazelrc` enables it for every build.
- **Platforms**: `//build/platforms:linux_x86_64_musl` is both target and host platform, so
  exec-configuration tools (mksnapshot, capnp, torque, proc-macros, build scripts, ...) are musl
  too.
- **Rust**: a separate rules_rust toolchain whose rustc and outputs are both
  `x86_64-unknown-linux-musl` (`build/deps/rust.MODULE.bazel`); rustc must itself be musl to load
  proc-macros built for the musl exec platform. rules_rust gives gnu and musl triples the same
  constraints, so the toolchain is constrained on `//build/platforms:musl` and registered ahead of
  the gnu toolchains. It uses `-crt-static`, and `patches/rules_rust/0004-...` keeps Rust's bundled
  static musl `libc.a` off the linker search path; otherwise proc-macros get a second libc and
  crash when rustc loads them.
- **glibc runtime for downloaded tools**: some tools Bazel downloads (hermetic Node.js and Python,
  cargo for crate_universe, formatters) are glibc-only. The image carries Debian's glibc runtime in
  `/opt/glibc/lib`, found only by glibc's loader through `/etc/ld.so.cache`.
- **musl differences** handled in `--config=linux_musl`:
  - musl has no `getcontext`/`makecontext`/`setcontext`, which KJ uses to start fibers
    (HTMLRewriter); they come from libucontext.
  - musl sizes new thread stacks from `PT_GNU_STACK` (128 KiB by default); the link sets 8 MiB.
  - tcmalloc replaces musl's allocator, but without its rseq-based per-CPU caches: musl unmaps an
    exiting detached thread's TLS while tcmalloc's rseq registration in it is still active, which
    crashes the thread. tcmalloc uses per-thread caches instead.

## Limitations

- Only x86_64 is supported.
- C++ exceptions and crash reports have no stack traces: KJ collects them with glibc's
  `backtrace()`. Async traces (pending promises) still work.
- The clang-tidy plugin (`//tools/clang-tidy:workerd-lint`) and its tests are incompatible with
  musl. The plugin is loaded into the clang-tidy binary published by workerd-tools, so it must use
  the same C library, and that binary is built against glibc.
- Sanitizer and coverage builds are unsupported. The image has no compiler-rt, and the sanitizer
  configs replace the musl platform with ones that select the gnu Rust toolchain.
- The image tracks Alpine edge, and nothing checks that its Bazel package matches `.bazelversion`.
  Because the versions can differ, the image sets `--lockfile_mode=off`, so its builds neither
  check nor update `MODULE.bazel.lock`.

## Testing

Tests run inside the container like builds. To run the whole suite, including the enormous tests
that CI also runs:

```sh
build/musl/build.sh bazel test --config=opt --test_size_filters= //...
```

When changing the image's C++ toolchain or libc++, run `build/musl/build.sh bazel clean`. Bazel does
not track system headers and libraries, so it would otherwise reuse objects built against the old
ones.
