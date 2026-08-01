SHELL := /bin/sh

LUA ?= lua5.4
LUAJIT ?= luajit
TEXLUA ?= texlua
LUAU ?= luau
LUAU_ANALYZE ?= luau-analyze
LUAU_BUILD_DIR ?= build/luau

REPO_LUA_PATH := ./src/?.lua;./src/?/init.lua;./src/?/?.lua;./?.lua;./?/init.lua;./?/?.lua;;
export LUA_PATH := $(REPO_LUA_PATH)

.PHONY: test test-public test-composition test-resources test-lifetimes test-io \
	test-embedding test-roblox-fake test-kernel test-internal test-reference test-case-studies \
	test-native test-stress test-full test-matrix test-lua51 test-lua52 test-lua53 \
	test-lua54 test-lua55 test-luajit test-luajit-interpreter test-texlua \
	build-luau check-luau-build check-luau test-luau test-luau-smoke \
	test-luau-portable examples bench bench-io profile-proof-io profile-exchange-frontier performance \
	check-format check-links check-modules check-scripts check build-profile \
	check-packages build-packages

test:
	$(LUA) tests/run_all.lua

test-public:
	$(LUA) tests/run_group.lua public

test-composition:
	$(LUA) tests/run_group.lua composition

test-resources:
	$(LUA) tests/run_group.lua resources

test-lifetimes:
	$(LUA) tests/run_group.lua lifetimes

test-io:
	$(LUA) tests/run_group.lua io

test-embedding:
	$(LUA) tests/run_group.lua embedding

test-roblox-fake:
	$(LUA) tests/embedding/test_roblox.lua

test-kernel:
	$(LUA) tests/run_group.lua kernel

test-internal:
	$(LUA) tests/run_group.lua internal

test-reference:
	$(LUA) tests/run_group.lua reference

test-case-studies:
	$(LUA) tests/run_group.lua case_studies

test-lua51:
	FIBERS_TEST_PROFILE=matrix lua5.1 tests/run_all.lua

test-lua52:
	FIBERS_TEST_PROFILE=matrix lua5.2 tests/run_all.lua

test-lua53:
	FIBERS_TEST_PROFILE=matrix lua5.3 tests/run_all.lua

test-lua54:
	FIBERS_TEST_PROFILE=matrix lua5.4 tests/run_all.lua

test-lua55:
	FIBERS_TEST_PROFILE=matrix lua5.5 tests/run_all.lua

test-luajit:
	FIBERS_TEST_PROFILE=matrix $(LUAJIT) tests/run_all.lua

test-luajit-interpreter:
	FIBERS_TEST_PROFILE=matrix $(LUAJIT) -joff tests/run_all.lua

test-texlua:
	FIBERS_TEST_PROFILE=matrix $(TEXLUA) tests/run_all.lua

build-luau:
	$(LUA) scripts/build-luau.lua --output "$(LUAU_BUILD_DIR)"

check-luau-build: build-luau

check-luau: build-luau
	$(LUAU_ANALYZE) "$(LUAU_BUILD_DIR)/tests/smoke.luau"
	$(LUAU_ANALYZE) "$(LUAU_BUILD_DIR)/tests/portable.luau"

test-luau-smoke: check-luau
	$(LUAU) "$(LUAU_BUILD_DIR)/tests/smoke.luau"

test-luau-portable: check-luau
	$(LUAU) "$(LUAU_BUILD_DIR)/tests/portable.luau"

test-luau: test-luau-smoke test-luau-portable

test-native:
	$(LUA) tests/run_group.lua native
	@if command -v "$(LUAJIT)" >/dev/null 2>&1; then \
		$(LUAJIT) tests/run_group.lua native; \
	else \
		echo "skip native LuaJIT run: $(LUAJIT) is not available"; \
	fi

test-stress:
	$(LUA) tests/run_group.lua stress

test-full: test-matrix test-native test-stress examples

test-matrix: test-lua51 test-lua52 test-lua53 test-lua54 test-lua55 \
	test-luajit test-luajit-interpreter test-texlua test-luau

examples:
	@set -e; for example in \
		examples/tutorial/*.lua \
		examples/gameplay/*.lua \
		examples/embedding/*.lua \
		examples/lifetimes/*.lua \
		examples/recipes/*_example.lua; do \
		echo "$$example"; $(LUA) "$$example"; \
	done

bench:
	$(LUAJIT) performance/bench.lua

bench-io:
	$(LUA) performance/io_baselines.lua

profile-proof-io:
	$(LUA) performance/proof_engine_io.lua

profile-exchange-frontier:
	$(LUA) performance/exchange_frontier_suite.lua

performance:
	$(LUAJIT) performance/suite.lua

check:
	$(MAKE) check-scripts
	$(MAKE) check-packages
	$(MAKE) check-format
	$(MAKE) check-links
	$(MAKE) check-modules
	$(MAKE) check-luau-build

check-links:
	$(LUA) scripts/check-links.lua .

check-format:
	sh scripts/check-format.sh

check-modules:
	$(LUA) scripts/check-modules.lua

check-scripts:
	@for file in scripts/*.sh; do sh -n "$$file"; done
	$(LUA) scripts/check-lua-syntax.lua

PROFILE ?= core
PROFILE_OUTPUT ?= build/profile-$(PROFILE)

build-profile:
	$(LUA) scripts/build-profile.lua --profile "$(PROFILE)" --output "$(PROFILE_OUTPUT)" --report "$(PROFILE_OUTPUT)/REPORT.txt"

check-packages:
	$(LUA) scripts/check-packages.lua
	@set -e; for profile in core-minimal core roblox io-nixio io-ffi io-cffi io-luaposix full; do \
		$(LUA) scripts/build-profile.lua --profile "$$profile" --report /tmp/fibers-profile-$$profile.txt >/dev/null; \
	done
	$(LUA) scripts/build-profile.lua --entry fibers.stream --report /tmp/fibers-profile-custom-stream.txt >/dev/null
	$(LUA) scripts/build-profile.lua --entry fibers.io.nixio --report /tmp/fibers-profile-custom-nixio.txt >/dev/null

PACKAGES_OUTPUT ?= build/packages
build-packages:
	$(LUA) scripts/build-packages.lua --output "$(PACKAGES_OUTPUT)"
