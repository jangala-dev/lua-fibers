SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

JOBS ?= $(shell nproc)
PREFIX_ROOT ?= /opt/fibers
BUILD_ROOT ?= /tmp/fibers-build
STAMP_ROOT := $(PREFIX_ROOT)/.stamps

LUA51_VERSION := 5.1.5
LUA52_VERSION := 5.2.4
LUA53_VERSION := 5.3.6
LUA54_VERSION := 5.4.8
LUA55_VERSION := 5.5.0

LUA51_SHA256 := 2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333
LUA52_SHA256 := b9e2e4aad6789b3b63a056d442f7b39f0ecfca3ae0f1fc0ae4e9614401b69f4b
LUA53_SHA256 := fc5fd69bb8736323f026672b1b7235da613d7177e72558893a0bdcd320466d60
LUA54_SHA256 := 4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae
LUA55_SHA256 := 57ccc32bbbd005cab75bcc52444052535af691789dba2b9016d5c50640d68b3d

# v2.1 is LuaJIT's maintained production branch. CI and release images may
# override this with an exact tested commit.
LUAJIT_REF ?= v2.1
LUAU_REF ?= 0.728
LUAROCKS_VERSION ?= 3.13.0
CFFI_VERSION ?= 0.2.4-1
LUAPOSIX_VERSION ?= 36.3-1
NIXIO_VERSION ?= 0.4-1
BIT32_VERSION ?= 5.3.5.1-1
STYLUA_VERSION ?= 2.5.2

.PHONY: bootstrap validate-pins system lua lua51 lua52 lua53 lua54 lua55 \
	luajit luau stylua luarocks wrappers rocks rocks-bit32 rocks-cffi \
	rocks-luaposix rocks-nixio verify clean-build

bootstrap: validate-pins system lua luajit luau stylua luarocks wrappers rocks verify clean-build

validate-pins:
	check_sha256() {
		local name="$$1" value="$$2"
		if [[ ! "$$value" =~ ^[0-9a-f]{64}$$ ]]; then
			echo "invalid SHA-256 pin for $$name: $$value" >&2
			exit 1
		fi
	}
	check_sha256 lua-$(LUA51_VERSION) "$(LUA51_SHA256)"
	check_sha256 lua-$(LUA52_VERSION) "$(LUA52_SHA256)"
	check_sha256 lua-$(LUA53_VERSION) "$(LUA53_SHA256)"
	check_sha256 lua-$(LUA54_VERSION) "$(LUA54_SHA256)"
	check_sha256 lua-$(LUA55_VERSION) "$(LUA55_SHA256)"

system:
	if [ "$$(id -u)" -ne 0 ]; then
		echo '.devcontainer/Makefile must be run as root (the devcontainer uses sudo).' >&2
		exit 1
	fi
	apt-get update
	export DEBIAN_FRONTEND=noninteractive
	apt-get install -y --no-install-recommends \
		build-essential \
		bzip2 \
		ca-certificates \
		cmake \
		curl \
		file \
		git \
		gzip \
		libffi-dev \
		libncurses-dev \
		libreadline-dev \
		libssl-dev \
		make \
		meson \
		ninja-build \
		patch \
		pkg-config \
		python3 \
		tar \
		unzip \
		xz-utils \
		zip
	rm -rf /var/lib/apt/lists/*
	mkdir -p "$(BUILD_ROOT)" "$(STAMP_ROOT)" /usr/local/bin

lua: lua51 lua52 lua53 lua54 lua55

lua51: $(STAMP_ROOT)/lua-$(LUA51_VERSION)
lua52: $(STAMP_ROOT)/lua-$(LUA52_VERSION)
lua53: $(STAMP_ROOT)/lua-$(LUA53_VERSION)
lua54: $(STAMP_ROOT)/lua-$(LUA54_VERSION)
lua55: $(STAMP_ROOT)/lua-$(LUA55_VERSION)

$(STAMP_ROOT)/lua-$(LUA51_VERSION): | system
	$(MAKE) -f .devcontainer/Makefile build-lua LUA_VERSION=$(LUA51_VERSION) LUA_SLOT=5.1 LUA_SHA256=$(LUA51_SHA256)
	touch "$@"

$(STAMP_ROOT)/lua-$(LUA52_VERSION): | system
	$(MAKE) -f .devcontainer/Makefile build-lua LUA_VERSION=$(LUA52_VERSION) LUA_SLOT=5.2 LUA_SHA256=$(LUA52_SHA256)
	touch "$@"

$(STAMP_ROOT)/lua-$(LUA53_VERSION): | system
	$(MAKE) -f .devcontainer/Makefile build-lua LUA_VERSION=$(LUA53_VERSION) LUA_SLOT=5.3 LUA_SHA256=$(LUA53_SHA256)
	touch "$@"

$(STAMP_ROOT)/lua-$(LUA54_VERSION): | system
	$(MAKE) -f .devcontainer/Makefile build-lua LUA_VERSION=$(LUA54_VERSION) LUA_SLOT=5.4 LUA_SHA256=$(LUA54_SHA256)
	touch "$@"

$(STAMP_ROOT)/lua-$(LUA55_VERSION): | system
	$(MAKE) -f .devcontainer/Makefile build-lua LUA_VERSION=$(LUA55_VERSION) LUA_SLOT=5.5 LUA_SHA256=$(LUA55_SHA256)
	touch "$@"

.PHONY: build-lua
build-lua:
	test -n "$(LUA_VERSION)" || { echo 'LUA_VERSION is required' >&2; exit 1; }
	test -n "$(LUA_SLOT)" || { echo 'LUA_SLOT is required' >&2; exit 1; }
	test -n "$(LUA_SHA256)" || { echo 'LUA_SHA256 is required' >&2; exit 1; }
	archive="$(BUILD_ROOT)/lua-$(LUA_VERSION).tar.gz"
	source="$(BUILD_ROOT)/lua-$(LUA_VERSION)"
	prefix="$(PREFIX_ROOT)/lua/$(LUA_SLOT)"
	rm -rf "$$source" "$$prefix"
	curl -fsSL "https://www.lua.org/ftp/lua-$(LUA_VERSION).tar.gz" -o "$$archive"
	printf '%s  %s\n' "$(LUA_SHA256)" "$$archive" | sha256sum -c -
	tar -xzf "$$archive" -C "$(BUILD_ROOT)"
	sed -i -E 's|^#define LUA_ROOT[[:space:]]+.*$$|#define LUA_ROOT "'"$$prefix"'/"|' "$$source/src/luaconf.h"
	grep -F "#define LUA_ROOT \"$$prefix/\"" "$$source/src/luaconf.h"
	$(MAKE) -C "$$source" -j"$(JOBS)" linux MYCFLAGS='-fPIC'
	$(MAKE) -C "$$source" install INSTALL_TOP="$$prefix"
	ln -sfn "$$prefix/bin/lua" "/usr/local/bin/lua$(LUA_SLOT)"
	ln -sfn "$$prefix/bin/luac" "/usr/local/bin/luac$(LUA_SLOT)"

luajit: $(STAMP_ROOT)/luajit

$(STAMP_ROOT)/luajit: | system
	source="$(BUILD_ROOT)/luajit"
	prefix="$(PREFIX_ROOT)/luajit"
	rm -rf "$$source" "$$prefix"
	git clone https://luajit.org/git/luajit.git "$$source"
	git -C "$$source" checkout "$(LUAJIT_REF)"
	$(MAKE) -C "$$source" -j"$(JOBS)" PREFIX="$$prefix"
	$(MAKE) -C "$$source" install PREFIX="$$prefix"
	test -x "$$prefix/bin/luajit"
	ln -sfn "$$prefix/bin/luajit" "$$prefix/bin/lua"
	ln -sfn "$$prefix/bin/luajit" /usr/local/bin/luajit
	git -C "$$source" rev-parse HEAD > "$$prefix/COMMIT"
	touch "$@"

luau: $(STAMP_ROOT)/luau-$(LUAU_REF)

$(STAMP_ROOT)/luau-$(LUAU_REF): | system
	source="$(BUILD_ROOT)/luau"
	build="$$source/build"
	prefix="$(PREFIX_ROOT)/luau"
	rm -rf "$$source" "$$prefix"
	git clone --branch "$(LUAU_REF)" --depth 1 https://github.com/luau-lang/luau.git "$$source"
	cmake -S "$$source" -B "$$build" -DCMAKE_BUILD_TYPE=Release
	cmake --build "$$build" --target Luau.Repl.CLI Luau.Analyze.CLI -j"$(JOBS)"
	install -D -m 0755 "$$build/luau" "$$prefix/bin/luau"
	install -D -m 0755 "$$build/luau-analyze" "$$prefix/bin/luau-analyze"
	ln -sfn "$$prefix/bin/luau" /usr/local/bin/luau
	ln -sfn "$$prefix/bin/luau-analyze" /usr/local/bin/luau-analyze
	touch "$@"

stylua: $(STAMP_ROOT)/stylua-$(STYLUA_VERSION)

$(STAMP_ROOT)/stylua-$(STYLUA_VERSION): | system
	archive="$(BUILD_ROOT)/stylua.zip"
	extract="$(BUILD_ROOT)/stylua-extract"
	case "$$(uname -m)" in
		x86_64|amd64) assets='stylua-linux-x86_64.zip stylua-linux-x86_64-musl.zip' ;;
		aarch64|arm64) assets='stylua-linux-aarch64.zip stylua-linux-aarch64-musl.zip' ;;
		*) echo "unsupported StyLua architecture: $$(uname -m)" >&2; exit 1 ;;
	esac
	rm -rf "$$extract" "$$archive"
	mkdir -p "$$extract"
	found=
	for asset in $$assets; do
		url="https://github.com/JohnnyMorganz/StyLua/releases/download/v$(STYLUA_VERSION)/$$asset"
		if curl -fsSL "$$url" -o "$$archive"; then
			found="$$asset"
			break
		fi
	done
	test -n "$$found" || { echo 'unable to download a StyLua binary for this architecture' >&2; exit 1; }
	unzip -q "$$archive" -d "$$extract"
	stylua_bin="$$(find "$$extract" -type f -name stylua -print -quit)"
	test -n "$$stylua_bin"
	install -D -m 0755 "$$stylua_bin" /usr/local/bin/stylua
	touch "$@"

luarocks: $(STAMP_ROOT)/luarocks-$(LUAROCKS_VERSION)

$(STAMP_ROOT)/luarocks-$(LUAROCKS_VERSION): lua54 | system
	archive="$(BUILD_ROOT)/luarocks-$(LUAROCKS_VERSION).tar.gz"
	source="$(BUILD_ROOT)/luarocks-$(LUAROCKS_VERSION)"
	prefix="$(PREFIX_ROOT)/luarocks"
	rm -rf "$$source" "$$prefix"
	curl -fsSL "https://luarocks.github.io/luarocks/releases/luarocks-$(LUAROCKS_VERSION).tar.gz" -o "$$archive"
	tar -xzf "$$archive" -C "$(BUILD_ROOT)"
	cd "$$source"
	./configure --prefix="$$prefix" --with-lua="$(PREFIX_ROOT)/lua/5.4"
	$(MAKE) -j"$(JOBS)"
	$(MAKE) install
	test -x "$$prefix/bin/luarocks"
	touch "$@"

wrappers: luarocks
	make_wrapper() {
		local name="$$1" version="$$2" lua_dir="$$3" tree="$$4"
		printf '#!/bin/sh\nexec "%s" --lua-version="%s" --lua-dir="%s" --tree="%s" "$$@"\n' \
			"$(PREFIX_ROOT)/luarocks/bin/luarocks" "$$version" "$$lua_dir" "$$tree" \
			> "/usr/local/bin/luarocks-$$name"
		chmod 0755 "/usr/local/bin/luarocks-$$name"
	}
	for slot in 5.1 5.2 5.3 5.4 5.5; do
		make_wrapper "$$slot" "$$slot" "$(PREFIX_ROOT)/lua/$$slot" "$(PREFIX_ROOT)/lua/$$slot"
	done
	make_wrapper luajit 5.1 "$(PREFIX_ROOT)/luajit" "$(PREFIX_ROOT)/luajit"
	ln -sfn "$(PREFIX_ROOT)/luarocks/bin/luarocks" /usr/local/bin/luarocks

rocks: rocks-bit32 rocks-cffi rocks-luaposix

# Fibers native host adapters need the bit32 API on Lua 5.1 and Lua 5.4.
# Lua 5.2 provides it, Lua 5.3 reports it as VM-provided, and the current rock
# does not yet declare Lua 5.5 support.
rocks-bit32: wrappers lua51 lua54
	luarocks-5.1 install bit32 "$(BIT32_VERSION)"
	luarocks-5.4 install bit32 "$(BIT32_VERSION)"

rocks-cffi: wrappers lua
	for slot in 5.1 5.2 5.3 5.4 5.5; do
		"luarocks-$$slot" install cffi-lua "$(CFFI_VERSION)"
	done

rocks-luaposix: wrappers lua51 lua52 lua53 lua54 luajit
	for runtime in 5.1 5.2 5.3 5.4 luajit; do
		"luarocks-$$runtime" install luaposix "$(LUAPOSIX_VERSION)"
	done

# nixio is useful for compatibility testing but is old and therefore opt-in.
rocks-nixio: wrappers lua51 luajit
	luarocks-5.1 install nixio "$(NIXIO_VERSION)"
	luarocks-luajit install nixio "$(NIXIO_VERSION)"

verify: lua luajit luau stylua luarocks wrappers rocks
	lua5.1 -e "assert(_VERSION == 'Lua 5.1'); assert(require('bit32')); assert(require('cffi')); assert(require('posix.sys.socket'))"
	lua5.2 -e "assert(_VERSION == 'Lua 5.2'); assert(require('cffi')); assert(require('posix.sys.socket'))"
	lua5.3 -e "assert(_VERSION == 'Lua 5.3'); assert(require('cffi')); assert(require('posix.sys.socket'))"
	lua5.4 -e "assert(_VERSION == 'Lua 5.4'); assert(require('bit32')); assert(require('cffi')); assert(require('posix.sys.socket'))"
	lua5.5 -e "assert(_VERSION == 'Lua 5.5'); assert(require('cffi'))"
	luajit -e "assert(jit and jit.version); assert(require('ffi')); assert(require('posix.sys.socket'))"
	luau -h >/dev/null
	luau-analyze --help >/dev/null
	stylua --version
	for command in luarocks-5.1 luarocks-5.2 luarocks-5.3 luarocks-5.4 luarocks-5.5 luarocks-luajit; do
		"$$command" --version
	done

clean-build:
	rm -rf "$(BUILD_ROOT)"
