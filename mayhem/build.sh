#!/usr/bin/env bash
#
# scs/mayhem/build.sh — build the Mayhem target with ASan+UBSan so we find memory AND
# undefined-behavior defects in scs's own code (not just the harness):
#   - run_from_file_direct  (file-input target)
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults:
#   SANITIZER_FLAGS  base default = ASan+UBSan, halting (override via Dockerfile --build-arg SANITIZERS)
#   DEBUG_FLAGS      C/C++ debug info pinned to DWARF < 4 (Mayhem triage can't read DWARF >= 4, and
#                    clang-19's plain -g emits DWARF-5). The base may export it empty, so default
#                    with := (fires on unset OR empty) to GUARANTEE -gdwarf-3 on every fuzz binary.
#   MAYHEM_JOBS      build parallelism; falls back to nproc when unset
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS
cd "$SRC"

# 1) Build scs's OWN test runner FIRST, with NORMAL flags, and stash it to /mayhem so mayhem/test.sh
#    only RUNS it. scs builds everything in out/, so stash before the sanitized rebuild clobbers it,
#    then `make clean` to drop the normal-flags objects before the instrumented build below.
#    `make clean` FIRST too, so a re-run (PATCH tier, §6.2 item 9) doesn't link the normal-flags test
#    runner against leftover sanitized objects from a prior run (undefined __asan_* → idempotency fail).
make clean
make -j"$MAYHEM_JOBS" USE_LAPACK=0 test
cp out/run_tests_direct /mayhem/run_tests_direct
make clean

# 2) Build scs (lib) + the file-input target WITH the sanitizers. Always link -lm explicitly: scs uses
# sqrt() etc., and we override LDFLAGS (dropping scs's own libs), so without -lm the link only works
# by accident when ASan pulls in libm — it breaks for a sanitizer-off build (SANITIZER_FLAGS=).
# Thread $DEBUG_FLAGS (DWARF < 4) alongside $SANITIZER_FLAGS into OPT so scs's OWN objects (the lib +
# the file-input target run_from_file_direct) carry DWARF-3 debug info for triage.
make -j"$MAYHEM_JOBS" USE_LAPACK=0 OPT="$SANITIZER_FLAGS $DEBUG_FLAGS -O1" LDFLAGS="$SANITIZER_FLAGS -lm" \
     out/libscsdir.a out/run_from_file_direct

# LSan-under-ptrace fix: re-link run_from_file_direct with the __lsan_is_turned_off() hook injected
# (build-time only — ASan/UBSan stay fully active). LSan ptrace-attaches at exit to walk the heap;
# Mayhem already traces the process → LSan's ptrace call fails → SIGABRT at exit → 0 edges recorded.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o /tmp/lsan_off.o
$CC \
    -g -Wall -Wwrite-strings -pedantic -funroll-loops -Wstrict-prototypes -fPIC \
    -I. -Iinclude -Ilinsys \
    $SANITIZER_FLAGS $DEBUG_FLAGS -O1 \
    -o out/run_from_file_direct \
    test/run_from_file.c /tmp/lsan_off.o out/libscsdir.a \
    $SANITIZER_FLAGS -lm -lrt -lpthread
