SHELL := /bin/sh

LUA ?= lua5.4
LUAJIT ?= luajit
TEXLUA ?= texlua
LUAU ?= luau
LUAU_ANALYZE ?= luau-analyze
LUAU_BUILD_DIR ?= build/luau
LUAU_REFERENCE_BUILD_DIR ?= build/luau-reference

REPO_LUA_PATH := ./src/?.lua;./src/?/init.lua;./src/?/?.lua;./reference/?.lua;./reference/?/init.lua;./reference/?/?.lua;./?.lua;./?/init.lua;./?/?.lua;;
export LUA_PATH := $(REPO_LUA_PATH)

.PHONY: test test-ledger test-reference test-public test-composition test-resources \
	test-lifetimes test-io test-embedding test-kernel test-internal test-case-studies \
	test-performance test-native test-stress test-full test-matrix \
	test-lua51 test-lua52 test-lua53 test-lua54 test-lua55 test-luajit \
	test-luajit-interpreter test-texlua build-luau build-luau-reference \
	check-luau-build check-luau check-luau-portable check-luau-reference \
	test-luau test-luau-smoke test-luau-portable test-luau-reference examples \
	bench bench-ledger bench-io profile-proof-io performance check-format \
	check-links check-modules check-scripts check


test:
	$(LUA) tests/run_all.lua

test-ledger:
	FIBERS_MACHINE=ledger $(LUA) tests/run_all.lua

test-reference:
	FIBERS_MACHINE=reference FIBERS_TEST_PROFILE=matrix $(LUA) tests/run_all.lua

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

test-kernel:
	$(LUA) tests/run_group.lua kernel

test-internal:
	$(LUA) tests/run_group.lua internal

test-case-studies:
	$(LUA) tests/run_group.lua case_studies

test-performance:
	$(LUA) tests/run_group.lua performance

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

build-luau-reference:
	$(LUA) scripts/build-luau.lua --profile reference --output "$(LUAU_REFERENCE_BUILD_DIR)"

check-luau-build: build-luau build-luau-reference

check-luau-portable: build-luau
	$(LUAU_ANALYZE) "$(LUAU_BUILD_DIR)/tests/smoke.luau"
	$(LUAU_ANALYZE) "$(LUAU_BUILD_DIR)/tests/portable.luau"

check-luau-reference: build-luau-reference
	$(LUAU_ANALYZE) "$(LUAU_REFERENCE_BUILD_DIR)/tests/reference.luau"

check-luau: check-luau-portable check-luau-reference

test-luau-smoke: check-luau-portable
	$(LUAU) "$(LUAU_BUILD_DIR)/tests/smoke.luau"

test-luau-portable: check-luau-portable
	$(LUAU) "$(LUAU_BUILD_DIR)/tests/portable.luau"

test-luau-reference: check-luau-reference
	$(LUAU) "$(LUAU_REFERENCE_BUILD_DIR)/tests/reference.luau"

test-luau: test-luau-smoke test-luau-portable test-luau-reference

test-native:
	$(LUA) tests/run_group.lua native
	@if command -v "$(LUAJIT)" >/dev/null 2>&1; then \
		$(LUAJIT) tests/run_group.lua native; \
	else \
		echo "skip native LuaJIT run: $(LUAJIT) is not available"; \
	fi

test-stress:
	$(LUA) tests/run_group.lua stress

test-full: test-matrix test-native test-stress test-reference examples

test-matrix: test-lua51 test-lua52 test-lua53 test-lua54 test-lua55 \
	test-luajit test-luajit-interpreter test-texlua test-luau

examples:
	@set -e; for example in \
		examples/tutorial/*.lua \
		examples/embedding/*.lua \
		examples/lifetimes/*.lua \
		examples/recipes/*_example.lua; do \
		echo "$$example"; $(LUA) "$$example"; \
	done

bench:
	$(LUAJIT) performance/bench.lua

bench-ledger:
	FIBERS_MACHINE=ledger $(LUAJIT) performance/bench.lua

bench-io:
	$(LUA) performance/io_baselines.lua

profile-proof-io:
	$(LUA) performance/proof_engine_io.lua

performance:
	$(LUAJIT) performance/suite.lua

check:
	$(MAKE) check-scripts
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
	@for file in scripts/*.sh .devcontainer/*.sh; do sh -n "$$file"; done
	$(LUA) scripts/check-lua-syntax.lua scripts/*.lua tests/run_*.lua tests/luau/*.lua performance/*.lua
	$(MAKE) -f .devcontainer/Makefile validate-pins
