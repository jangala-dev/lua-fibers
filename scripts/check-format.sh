#!/usr/bin/env sh
set -eu

if ! command -v stylua >/dev/null 2>&1; then
  echo 'stylua is required to check Lua formatting' >&2
  exit 1
fi

stylua --check src examples performance scripts tests docs/notes/*.lua
