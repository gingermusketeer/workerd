# musl builds

`--config=linux_musl` builds workerd for `x86_64-unknown-linux-musl` with the same hermetic
toolchain as other Linux builds. It runs on an ordinary glibc Linux host and needs nothing from it,
and the result is a fully static executable that runs on any x86_64 Linux: Alpine and other musl
distributions without gcompat, glibc distributions, and empty (`FROM scratch`) containers.

```sh
bazel build --config=linux_musl //src/workerd/server:workerd
bazel test --config=linux_musl //...
```

## How it works

- **Platforms**: only the target is musl, `//build/platforms:linux_x86_64_musl`, which adds the
  `//build/platforms:musl` constraint. Platforms without a `libc` constraint are glibc. Exec tools
  (capnp, proc macros, build scripts, ...) are built for the glibc host as usual.
- **C++**: `build/deps/llvm.MODULE.bazel` defines a second toolchains_llvm toolchain for x86_64. It
  runs the x86_64 toolchain's compiler with musl's triple
  (`patches/toolchains_llvm/target-system-name.patch` lets a toolchain set it), a musl sysroot, and
  LLVM's runtimes built for musl: libc++, libc++abi, libunwind and compiler-rt's builtins. Like
  the glibc toolchain, it links them statically. It is constrained on `//build/platforms:musl` and
  registered ahead of the glibc toolchains, which have no libc constraint.
- **Rust**: a toolchain whose rustc runs on the glibc host and builds for the musl target
  (`build/deps/rust.MODULE.bazel`), constrained and registered the same way.
- **Static linking**: `--config=linux_musl` links every executable as a static PIE and builds no
  shared libraries. This is required, not just convenient: V8's generator tools (torque, mksnapshot,
  ...) are built for the target and run during the build, and tests run on the host, neither of
  which has musl's dynamic loader. Proc macros are shared libraries, so they can't be built for
  musl, and a build of `//...` skips them as it does under the sanitizers.
- **musl differences** handled in `--config=linux_musl`:
  - musl has no `getcontext`/`makecontext`/`setcontext`, which KJ uses to start fibers
    (HTMLRewriter); they come from libucontext, which the sysroot includes.
  - musl sizes new thread stacks from `PT_GNU_STACK` (128 KiB by default); the link sets 8 MiB.
  - tcmalloc replaces musl's allocator, but without its rseq-based per-CPU caches: musl unmaps an
    exiting detached thread's TLS while tcmalloc's rseq registration in it is still active, which
    crashes the thread. tcmalloc uses per-thread caches instead.

## The sysroot and runtimes

`make-sysroot.sh` builds the two archives that the toolchain takes as repositories, in an Alpine
container (podman):

- `musl-sysroot-alpine<ver>-x86_64.tar.xz`: Alpine's `musl-dev`, `linux-headers` and
  `libucontext-dev` packages, with `packages.txt` listing their versions.
- `llvm-runtimes-<ver>-x86_64-linux-musl.tar.xz`: LLVM's runtimes, built for musl from the release
  that matches the toolchain's `llvm_version`, laid out like an LLVM release's target directories.
  It includes clang's resource headers, which toolchains_llvm takes from the same directory.

The archives are built reproducibly. To update them, change the versions in `make-sysroot.sh`,
run it, publish the archives, and update the URLs and hashes in `build/deps/llvm.MODULE.bazel`.
Before they are published, pass their directory to Bazel with `--distdir`:

```sh
EXTRA_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt build/musl/make-sysroot.sh bazel-musl-dist
bazel build --config=linux_musl --distdir=$PWD/bazel-musl-dist //src/workerd/server:workerd
```

## Limitations

- Only x86_64 is supported.
- C++ exceptions and crash reports have no stack traces: KJ collects them with glibc's
  `backtrace()`. Async traces (pending promises) still work.
- The clang-tidy plugin (`//tools/clang-tidy:workerd-lint`) and its tests are incompatible with
  musl. The plugin is loaded into the clang-tidy binary published by workerd-tools, so it must use
  the same C library, and that binary is built against glibc.
- Sanitizer and coverage builds with `--config=linux_musl` are untested.
