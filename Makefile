SHELL := /bin/sh

LUA ?= lua5.4
LUAJIT ?= luajit

REPO_LUA_PATH := ./src/?.lua;./src/?/init.lua;./src/?/?.lua;./reference/?.lua;./reference/?/init.lua;./reference/?/?.lua;./?.lua;./?/init.lua;./?/?.lua;;
export LUA_PATH := $(REPO_LUA_PATH)

.PHONY: test test-reference test-matrix test-lua51 test-lua52 test-lua53 \
	test-lua54 test-lua55 test-luajit test-luajit-interpreter examples \
	bench performance check-format check-layout

test:
	$(LUA) tests/run_all.lua

test-reference:
	FIBERS_MACHINE=reference $(LUA) tests/run_all.lua

test-lua51:
	lua5.1 tests/run_all.lua

test-lua52:
	lua5.2 tests/run_all.lua

test-lua53:
	lua5.3 tests/run_all.lua

test-lua54:
	lua5.4 tests/run_all.lua

test-lua55:
	lua5.5 tests/run_all.lua

test-luajit:
	$(LUAJIT) tests/run_all.lua

test-luajit-interpreter:
	$(LUAJIT) -joff tests/run_all.lua

test-matrix: test-lua51 test-lua52 test-lua53 test-lua54 test-lua55 \
	test-luajit test-luajit-interpreter

examples:
	@set -e; for example in examples/[0-9][0-9]_*.lua; do \
		echo "$$example"; $(LUA) "$$example"; \
	done

bench:
	$(LUAJIT) performance/bench.lua

performance:
	$(LUAJIT) performance/suite.lua

check-format:
	./scripts/check-format.sh

check-layout:
	@test -f src/fibers.lua
	@test -d src/fibers
	@test -f reference/fibers/internal/reference_machine.lua
	@test ! -e src/fibers/internal/reference_machine.lua
	@test -f performance/bench.lua
	@test ! -e benchmarks
