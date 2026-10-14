#!/usr/bin/env bash
# Native codec/layout tests under AddressSanitizer + UBSan. Needs a C++23
# compiler only (no Hyprland headers). Output stays in tests/native/build/.
set -euo pipefail
cd "$(dirname "$0")"
CXX="${CXX:-c++}"
mkdir -p build
"$CXX" -std=c++2b -O1 -g -Wall -Wextra -Werror -fno-omit-frame-pointer \
  -fsanitize=address,undefined -fno-sanitize-recover=all \
  test_protocol.cpp -o build/test_protocol
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 UBSAN_OPTIONS=print_stacktrace=1 build/test_protocol
