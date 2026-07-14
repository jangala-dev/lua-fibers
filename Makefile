SHELL := /bin/sh

LUA ?= lua5.4
LUAJIT ?= luajit

REPO_LUA_PATH := ./src/?.lua;./src/?/init.lua;./src/?/?.lua;./reference/?.lua;./reference/?/init.lua;./reference/?/?.lua;./?.lua;./?/init.lua;./?/?.lua;;
export LUA_PATH := $(REPO_LUA_PATH)

.PHONY: test test-reference test-public test-composition test-resources \
	test-lifetimes test-embedding test-kernel test-internal test-case-studies \
	test-experiments test-performance test-matrix test-lua51 test-lua52 \
	test-lua53 test-lua54 test-lua55 test-luajit test-luajit-interpreter \
	examples bench performance check-format check-layout

test:
	$(LUA) tests/run_all.lua

test-reference:
	FIBERS_MACHINE=reference $(LUA) tests/run_all.lua

test-public:
	$(LUA) tests/run_group.lua public

test-composition:
	$(LUA) tests/run_group.lua composition

test-resources:
	$(LUA) tests/run_group.lua resources

test-lifetimes:
	$(LUA) tests/run_group.lua lifetimes

test-embedding:
	$(LUA) tests/run_group.lua embedding

test-kernel:
	$(LUA) tests/run_group.lua kernel

test-internal:
	$(LUA) tests/run_group.lua internal

test-case-studies:
	$(LUA) tests/run_group.lua case_studies

test-experiments:
	$(LUA) tests/run_group.lua experiments

test-performance:
	$(LUA) tests/run_group.lua performance

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
	@set -e; for example in \
		examples/tutorial/*.lua \
		examples/embedding/*.lua \
		examples/lifetimes/*.lua \
		examples/recipes/*_example.lua; do \
		echo "$$example"; $(LUA) "$$example"; \
	done

bench:
	$(LUAJIT) performance/bench.lua

performance:
	$(LUAJIT) performance/suite.lua

check-format:
	./scripts/check-format.sh

check-layout:
	@test -f src/fibers/init.lua
	@test ! -e src/fibers.lua
	@test ! -e src/fibers/atoms.lua
	@test ! -d src/fibers/atoms
	@test ! -e src/fibers/kernel.lua
	@test ! -d src/fibers/kernel
	@test -f src/fibers/runtime.lua
	@test -d src/fibers/internal/kernel
	@test -f src/fibers/internal/flow.lua
	@test -f src/fibers/internal/fifo.lua
	@test -d src/fibers/resource
	@test -d src/fibers/external
	@test -d src/fibers/lifetime
	@test -f examples/recipes/rate_limiter.lua
	@test -f examples/case_studies/petri/petri.lua
	@test -f experiments/phase.lua
	@test -f reference/fibers/internal/reference_machine.lua
	@test ! -e src/fibers/internal/reference_machine.lua
	@test -f performance/bench.lua
	@test ! -e benchmarks
