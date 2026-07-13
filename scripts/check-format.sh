#!/usr/bin/env sh
set -eu

if ! command -v stylua >/dev/null 2>&1; then
  echo 'stylua is required to check Lua formatting' >&2
  exit 1
fi

stylua --check src reference examples performance tests

status=0
find src reference examples performance tests -type f -name '*.lua' -exec \
  awk 'length($0) > 100 { printf "%s:%d: line exceeds 100 columns\n", FILENAME, FNR; status = 1 } END { exit status }' \
  {} + || status=$?


exit "$status"
