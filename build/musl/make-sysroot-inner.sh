#!/bin/sh
# Runs inside the Alpine container started by make-sysroot.sh.
set -eu

TRIPLE=x86_64-unknown-linux-musl
LLVM_MAJOR="${LLVM_VERSION%%.*}"

apk add --no-cache bash clang${LLVM_MAJOR} lld${LLVM_MAJOR} llvm${LLVM_MAJOR} cmake samurai \
  python3 tar xz coreutils findutils
export PATH="/usr/lib/llvm${LLVM_MAJOR}/bin:$PATH"
clang_version="$(clang -dumpversion)"
if [ "$clang_version" != "$LLVM_VERSION" ]; then
  echo "Alpine's clang is $clang_version, not $LLVM_VERSION" >&2
  exit 1
fi

# Sysroot: the musl C library and its development files, kernel headers, and libucontext, which
# provides the getcontext()/makecontext()/setcontext() functions musl lacks.
SYSROOT=/work/sysroot
mkdir -p "$SYSROOT"
apk --root "$SYSROOT" --initdb --keys-dir /etc/apk/keys --no-cache --no-scripts \
  --repository "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_SYSROOT_VERSION}/main" \
  add musl-dev linux-headers libucontext-dev
apk --root "$SYSROOT" info -v 2>/dev/null | sort > /work/sysroot-packages.txt
# Everything but the headers and libraries, including pkgconf, which libucontext-dev depends on.
rm -rf "$SYSROOT/etc" "$SYSROOT/var" "$SYSROOT/lib/apk" "$SYSROOT/dev" "$SYSROOT/proc" \
  "$SYSROOT/sys" "$SYSROOT/run" "$SYSROOT/tmp" "$SYSROOT/usr/bin" "$SYSROOT/usr/share" \
  "$SYSROOT"/usr/lib/libpkgconf* "$SYSROOT/usr/lib/pkgconfig"
find "$SYSROOT" -xtype l -delete
# Builds reach the sysroot through --sysroot, so its symlinks must be relative.
find "$SYSROOT" -type l | while read -r link; do
  target="$(readlink "$link")"
  case "$target" in
    /*) ln -sfn "$(realpath -m --relative-to="$(dirname "$link")" "$SYSROOT$target")" "$link" ;;
  esac
done
cp /work/sysroot-packages.txt "$SYSROOT/packages.txt"

# LLVM runtimes for musl, as static, position-independent archives, like the glibc ones in LLVM's
# release.
wget -q -O /work/llvm.tar.xz \
  "https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/llvm-project-${LLVM_VERSION}.src.tar.xz"
echo "${LLVM_SHA256}  /work/llvm.tar.xz" | sha256sum -c -
mkdir -p /work/src
tar -xJf /work/llvm.tar.xz -C /work/src --strip-components=1

RUNTIMES=/work/runtimes
# Nothing here is linked as a program, so CMake's checks only compile. Checks for functions in a
# library therefore pass whether or not the library has them; those that change the code are set
# explicitly. musl has no __cxa_thread_atexit_impl.
cmake -G Ninja -S /work/src/runtimes -B /work/build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$RUNTIMES" \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_ASM_COMPILER=clang \
  -DCMAKE_C_COMPILER_TARGET="$TRIPLE" -DCMAKE_CXX_COMPILER_TARGET="$TRIPLE" \
  -DCMAKE_ASM_COMPILER_TARGET="$TRIPLE" \
  -DCMAKE_SYSROOT="$SYSROOT" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DLLVM_DEFAULT_TARGET_TRIPLE="$TRIPLE" \
  -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON \
  -DLLVM_ENABLE_RUNTIMES="compiler-rt;libunwind;libcxxabi;libcxx" \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DCOMPILER_RT_INSTALL_PATH="$RUNTIMES/lib/clang/${LLVM_MAJOR}" \
  -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
  -DCOMPILER_RT_BUILD_BUILTINS=ON \
  -DCOMPILER_RT_BUILD_CRT=ON \
  -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
  -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
  -DCOMPILER_RT_BUILD_MEMPROF=OFF \
  -DCOMPILER_RT_BUILD_ORC=OFF \
  -DCOMPILER_RT_BUILD_PROFILE=OFF \
  -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
  -DCOMPILER_RT_BUILD_XRAY=OFF \
  -DLIBUNWIND_ENABLE_SHARED=OFF \
  -DLIBUNWIND_USE_COMPILER_RT=ON \
  -DLIBCXXABI_ENABLE_SHARED=OFF \
  -DLIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL=OFF \
  -DLIBCXXABI_USE_COMPILER_RT=ON \
  -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
  -DLIBCXX_ENABLE_SHARED=OFF \
  -DLIBCXX_HAS_MUSL_LIBC=ON \
  -DLIBCXX_USE_COMPILER_RT=ON \
  -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
  -DLIBCXX_INSTALL_MODULES=OFF
ninja -C /work/build install

# Clang's resource headers, which toolchains_llvm takes from the same directory as the runtimes.
mkdir -p "$RUNTIMES/lib/clang/${LLVM_MAJOR}"
cp -a "/usr/lib/llvm${LLVM_MAJOR}/lib/clang/${LLVM_MAJOR}/include" \
  "$RUNTIMES/lib/clang/${LLVM_MAJOR}/include"
if [ -d "/usr/lib/llvm${LLVM_MAJOR}/lib/clang/${LLVM_MAJOR}/share" ]; then
  cp -a "/usr/lib/llvm${LLVM_MAJOR}/lib/clang/${LLVM_MAJOR}/share" \
    "$RUNTIMES/lib/clang/${LLVM_MAJOR}/share"
fi
rm -rf "$RUNTIMES/share"

pack() {
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$1" -cf - . | xz -T0 -9 > "$2"
}
pack "$SYSROOT" "/out/musl-sysroot-alpine${ALPINE_SYSROOT_VERSION}-x86_64.tar.xz"
pack "$RUNTIMES" "/out/llvm-runtimes-${LLVM_VERSION}-x86_64-linux-musl.tar.xz"
