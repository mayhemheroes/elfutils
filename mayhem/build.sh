#!/usr/bin/env bash
#
# mayhem/build.sh — build elfutils (autotools) TWICE:
#   (1) a NORMAL-flags build tree (no sanitizers) for the project's own functional testsuite, which
#       mayhem/test.sh later RUNS via `make check` (the heavy lib+tools build is done HERE; `make check`
#       only builds the small per-test C programs at run time and runs the ~226 tests/run-*.sh scripts);
#   (2) the SANITIZED in-place build instrumented with $SANITIZER_FLAGS, then link the three libFuzzer
#       harnesses (fuzz-dwfl-core, fuzz-libelf, fuzz-libdwfl) plus a standalone reproducer each.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/mayhemheroes/base) exports the build contract: CC, CXX, LIB_FUZZING_ENGINE,
# SANITIZER_FLAGS (ASan+UBSan, halting), STANDALONE_FUZZ_MAIN, SRC=/mayhem.
#
# elfutils specifics:
#  * The WHOLE library is compiled with $SANITIZER_FLAGS so the fuzzed code is instrumented.
#  * ASan/UBSan are incompatible with the linker hardening elfutils enables by default
#    (-Wl,--no-undefined in the Makefile.am's and -Wl,-z,defs from ZDEFS_LDFLAGS in configure.ac);
#    we strip those from the in-image build tree at build time (NOT a committed upstream edit).
#  * elfutils builds with -Werror under --enable-maintainer-mode; the sanitized build trips new
#    warnings, so we append -Wno-error to CFLAGS (it wins as the last -W flag).
#  * --disable-debuginfod --disable-libdebuginfod and --without-{bzlib,lzma,zstd} keep the dep
#    surface small; libelf still links zlib (-lz), which is in the base image. (test data is .bz2 and
#    is decompressed at test time by the `bunzip2` SYSTEM binary — the disabled libbz2 is unrelated.)
#  * UBSan stays HALTING. elfutils' build RUNS its own instrumented codegen tools (libcpu/i386_gendis,
#    generated bison) which trip ONE benign UBSan check — a null-pointer-offset / pointer arithmetic
#    overflow — that aborts the build under halt. We relax ONLY that one check with
#    -fno-sanitize=pointer-overflow (verified sufficient: the whole tree builds with no other UB abort),
#    keeping ASan + the rest of UBSan halting so the FUZZ TARGETS still halt on real UB.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENV (overridable). SANITIZER_FLAGS uses `=` (not `:=`) so an explicit empty
# value (--build-arg SANITIZER_FLAGS=) is honored → no-sanitizer build (natural crash).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# The configure options shared by BOTH builds (small dep surface; no debuginfod).
CONFIGURE_OPTS=( --enable-maintainer-mode
                 --disable-debuginfod --disable-libdebuginfod
                 --without-bzlib --without-lzma --without-zstd )

# =================================================================================================
# (1) NORMAL-flags test build — an independent, clean (NON-sanitized) tree built BEFORE we mutate the
#     source in-place for the sanitized build. mayhem/test.sh runs `make check` here, so it stays an
#     honest oracle for PATCH grading (clean flags, no sanitizer trace). We copy the PRISTINE tree out
#     first (the sanitized build edits Makefile.am/configure.ac in place); the location is recorded so
#     test.sh can find it. `make check` builds the small per-test programs at run time — that's cheap
#     and expected; the expensive lib+tools build is done here.
# =================================================================================================
TEST_BUILD_DIR="${TEST_BUILD_DIR:-${HOME:-/tmp}/mayhem-test-build}"
echo "build.sh: (1) NORMAL-flags test build in $TEST_BUILD_DIR"
rm -rf "$TEST_BUILD_DIR"
cp -a "$SRC" "$TEST_BUILD_DIR"
(
  cd "$TEST_BUILD_DIR"
  export CFLAGS="-Wno-error -g -O2"
  export CXXFLAGS="-Wno-error -g -O2"
  unset LDFLAGS
  autoreconf -i -f
  ./configure "${CONFIGURE_OPTS[@]}" CC="$CC" CXX="$CXX"
  # Build libs + src/eu-* tools (NOT the tests/ dir — test.sh's `make check` builds those on demand).
  make -j"$MAYHEM_JOBS"
)
echo "$TEST_BUILD_DIR" > /mayhem/.mayhem-test-build-dir

# =================================================================================================
# (2) SANITIZED in-place build + fuzz harnesses.
# =================================================================================================
echo "build.sh: (2) SANITIZED build in $SRC"

# --- Relax linker hardening that ASan/UBSan can't satisfy (in-image build tree only) -------------
# ASan isn't compatible with -Wl,--no-undefined: https://github.com/google/sanitizers/issues/380
find . -name Makefile.am -print0 | xargs -0 sed -i 's/,--no-undefined//g'
# ASan isn't compatible with -Wl,-z,defs either.
sed -i 's/^\(ZDEFS_LDFLAGS=\).*/\1/' configure.ac

# Keep UBSan HALTING (-fno-sanitize-recover=all from the base ENV) so the fuzz targets still abort on
# real UB. The only build-time obstacle is elfutils' own instrumented codegen tools tripping ONE benign
# check — pointer-overflow (null-pointer offset / pointer arithmetic overflow) — so relax JUST that one.
# (Verified: with only -fno-sanitize=pointer-overflow added, the entire lib+tools build completes with
# zero UBSan aborts; ASan and every other UBSan check remain on and halting.)
# Guard the empty off-switch: with no sanitizers we leave the flags empty so a
# `--build-arg SANITIZER_FLAGS=` build stays sanitizer-free and crashes naturally.
PROJECT_SAN_FLAGS="$SANITIZER_FLAGS"
case "$SANITIZER_FLAGS" in *undefined*) PROJECT_SAN_FLAGS="$PROJECT_SAN_FLAGS -fno-sanitize=pointer-overflow" ;; esac

# CFLAGS carries the sanitizers; -Wno-error neutralizes elfutils' -Werror; LDFLAGS carries the
# sanitizers so the runtime links into the .a's consumers. fuzzer-no-link gives the project libFuzzer
# coverage instrumentation without pulling in the engine's main (the harness links the engine later).
export CFLAGS="-Wno-error $PROJECT_SAN_FLAGS -fsanitize=fuzzer-no-link"
export CXXFLAGS="-Wno-error $PROJECT_SAN_FLAGS -fsanitize=fuzzer-no-link"
export LDFLAGS="$PROJECT_SAN_FLAGS"

autoreconf -i -f
./configure "${CONFIGURE_OPTS[@]}" CC="$CC" CXX="$CXX"

# elfutils' build runs its own instrumented codegen tools, which leak at exit; disable ASan leak
# detection for the build (UBSan halts on everything except the relaxed pointer-overflow check).
ASAN_OPTIONS=detect_leaks=0 make -j"$MAYHEM_JOBS" V=1

# --- Harnesses -----------------------------------------------------------------------------------
# Include path + defines mirror the elfutils build so the harnesses see config.h and the public API.
INCS="-D_GNU_SOURCE -DHAVE_CONFIG_H -I. -I./lib -I./libelf -I./libebl -I./libdw -I./libdwelf -I./libdwfl -I./libasm"

# Compile the standalone run-once driver as a C object ONCE (harnesses are C; the driver's
# LLVMFuzzerTestOneInput ref keeps C linkage).
$CC $PROJECT_SAN_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

# Static archives the harnesses link against (built above, sanitized).
DWFL_LIBS="./libdw/libdw.a ./libelf/libelf.a -lz"
ELF_LIBS="./libasm/libasm.a ./libebl/libebl.a ./backends/libebl_backends.a ./libcpu/libcpu.a ./libdw/libdw.a ./libelf/libelf.a ./lib/libeu.a -lz"

build_harness() {
  local name="$1" ; shift
  local libs="$*"
  # Object (sanitized, with libFuzzer coverage instrumentation).
  $CC $PROJECT_SAN_FLAGS -fsanitize=fuzzer-no-link $INCS -c "$SRC/mayhem/$name.c" -o "/tmp/$name.o"
  # libFuzzer target (the Mayhem target): object + engine + sanitized libs.
  $CC $PROJECT_SAN_FLAGS $LIB_FUZZING_ENGINE "/tmp/$name.o" $libs -o "/mayhem/$name"
  # Standalone reproducer: same object + run-once driver instead of the engine.
  $CC $PROJECT_SAN_FLAGS "/tmp/$name.o" /tmp/standalone_main.o $libs -o "/mayhem/$name-standalone"
}

build_harness fuzz-dwfl-core $DWFL_LIBS
build_harness fuzz-libelf    $ELF_LIBS
build_harness fuzz-libdwfl   $ELF_LIBS

# Seed corpus for the dwfl-core target (kept alongside the binaries).
cp "$SRC/mayhem/fuzz-dwfl-core_seed_corpus.zip" /mayhem/ 2>/dev/null || true

echo "build.sh: built fuzz-dwfl-core, fuzz-libelf, fuzz-libdwfl (+ -standalone reproducers); test tree in $TEST_BUILD_DIR"
