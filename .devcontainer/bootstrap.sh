#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo '.devcontainer/bootstrap.sh must be run as root' >&2
  exit 1
fi

# Resolve the repository independently of the lifecycle command's working
# directory. Invoking this file through /bin/sh also avoids reliance on the
# executable bit of a bind-mounted workspace.
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -P "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

# debian:trixie-slim does not include make. Install the minimum needed to
# enter the Makefile; the Makefile installs the complete build toolchain.
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates make
rm -rf /var/lib/apt/lists/*

exec make -f "$SCRIPT_DIR/Makefile" bootstrap
