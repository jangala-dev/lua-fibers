SHELL := /bin/sh

LUA ?= lua5.4
LUAJIT ?= luajit

REPO_LUA_PATH := ./src/?.lua;./src/?/init.lua;./src/?/?.lua;./reference/?.lua;./reference/?/init.lua;./reference/?/?.lua;./?.lua;./?/init.lua;./?/?.lua;;
export LUA_PATH := $(REPO_LUA_PATH)

.PHONY: test test-ledger test-reference test-public test-composition test-resources \
	test-lifetimes test-io test-embedding test-kernel test-internal test-case-studies \
	test-experiments test-performance test-native test-stress test-full test-matrix \
	test-lua51 test-lua52 test-lua53 test-lua54 test-lua55 test-luajit \
	test-luajit-interpreter examples bench bench-ledger bench-io profile-proof-io performance check-format check-links \
	check-layout check

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

test-experiments:
	$(LUA) tests/run_group.lua experiments

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

bench-ledger:
	FIBERS_MACHINE=ledger $(LUAJIT) performance/bench.lua

bench-io:
	$(LUA) performance/io_baselines.lua

profile-proof-io:
	$(LUA) performance/proof_engine_io.lua

performance:
	$(LUAJIT) performance/suite.lua

check:
	$(MAKE) check-format
	$(MAKE) check-links
	$(MAKE) check-layout

check-links:
	$(LUA) scripts/check-links.lua .

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
	@test -f src/fibers/internal/kernel/supply.lua
	@test ! -f src/fibers/internal/kernel/engine.lua
	@test -f src/fibers/internal/kernel/machine.lua
	@test -f src/fibers/internal/kernel/ledger.lua
	@test -f src/fibers/internal/kernel/algebra.lua
	@test -f src/fibers/internal/kernel/domain.lua
	@test -f src/fibers/internal/kernel/certificate.lua
	@test -f src/fibers/internal/kernel/path.lua
	@test -f src/fibers/internal/kernel/trail.lua
	@test -f src/fibers/internal/kernel/ir.lua
	@test ! -d src/fibers/internal/ledger_kernel
	@test ! -f src/fibers/internal/kernel/store.lua
	@test ! -f src/fibers/internal/kernel/frontier.lua
	@test ! -f src/fibers/internal/kernel/activation.lua
	@test -f src/fibers/flow.lua
	@test -f src/fibers/internal/flow_machine.lua
	@test -f src/fibers/internal/scalar_wait.lua
	@test -f src/fibers/flow/space_lease.lua
	@test -f src/fibers/host/reactor.lua
	@test -f src/fibers/host/error.lua
	@test -f src/fibers/host/native_error.lua
	@test -f src/fibers/host/nixio_error.lua
	@test -f src/fibers/host/luaposix_error.lua
	@test -f src/fibers/host/poll_plan.lua
	@test -f src/fibers/host/nixio_poll.lua
	@test -f src/fibers/internal/completion.lua
	@test -f src/fibers/internal/adoption.lua
	@test -f src/fibers/internal/io_audit.lua
	@test -f src/fibers/file.lua
	@test -d src/fibers/file
	@test -f src/fibers/file/regular.lua
	@test -f src/fibers/file/algorithms.lua
	@test -f src/fibers/file/provider.lua
	@test -f src/fibers/file/worker_provider.lua
	@test -f src/fibers/file/worker_command.lua
	@test -f src/fibers/file/memory_provider.lua
	@test -f src/fibers/file/worker_main.lua
	@test -f src/fibers/file/uring_provider.lua
	@test -f src/fibers/file/aio_probe.lua
	@test -f src/fibers/socket.lua
	@test -f src/fibers/process.lua
	@test -f src/fibers/process/command.lua
	@test -f src/fibers/internal/process/lifecycle.lua
	@test -f src/fibers/host/_process_ffi_common.lua
	@test -f src/fibers/host/process_luaposix.lua
	@test -f src/fibers/host/process_nixio.lua
	@test -f src/fibers/host/socket_luaposix.lua
	@test -f src/fibers/host/socket_nixio.lua
	@test -f src/fibers/host/resolver_luaposix.lua
	@test -f src/fibers/host/resolver_nixio.lua
	@test -f src/fibers/socket/address.lua
	@test -f src/fibers/socket/listener.lua
	@test -f src/fibers/socket/dial.lua
	@test -f src/fibers/socket/resolver.lua
	@test -f src/fibers/socket/datagram.lua
	@test -f docs/advanced/io-invariants.md
	@test -f tests/internal/test_io_audit.lua
	@test -f tests/io/test_socket_provider_matrix.lua
	@test -f tests/io/test_socket_failure_matrix.lua
	@test -f tests/io/test_file.lua
	@test -f tests/support/file_worker_delayed.lua
	@test -f tests/io/test_process.lua
	@test -f tests/native/test_process_native.lua
	@test -f tests/support/socket_provider_contract.lua
	@test -f tests/support/resolver_provider_contract.lua
	@test -f tests/support/process_provider_contract.lua
	@test -f src/fibers/internal/socket/datagram_lifecycle.lua
	@test -f src/fibers/internal/socket/datagram_send_state.lua
	@test -f src/fibers/internal/socket/datagram_service.lua
	@test -f src/fibers/host/provider.lua
	@test -f src/fibers/host/wait.lua
	@test -f src/fibers/host/datagram_luaposix.lua
	@test -f src/fibers/host/datagram_nixio.lua
	@test -f src/fibers/host/_socket_ffi_common.lua
	@test -f src/fibers/host/_resolver_ffi_common.lua
	@test -f src/fibers/internal/io.lua
	@test -f src/fibers/internal/socket/lifecycle.lua
	@test -f src/fibers/internal/socket/connection.lua
	@test -f src/fibers/internal/socket/listener_lifecycle.lua
	@test -f src/fibers/internal/socket/dial_lifecycle.lua
	@test ! -e src/fibers/internal/socket_lifecycle.lua
	@test ! -e src/fibers/internal/flow.lua
	@test ! -e src/fibers/stream/pump.lua
	@test -f src/fibers/internal/fifo.lua
	@test -d src/fibers/resource
	@test -d src/fibers/external
	@test -d src/fibers/lifetime
	@test -f examples/recipes/rate_limiter.lua
	@test -f examples/case_studies/petri/petri.lua
	@test -f experiments/phase.lua
	@test -f examples/tutorial/07_flow_tensor.lua
	@test -f examples/tutorial/08_pipe.lua
	@test -f examples/tutorial/09_socket.lua
	@test -f examples/tutorial/10_direct_methods.lua
	@test -f examples/tutorial/11_resolver.lua
	@test -f examples/tutorial/12_datagram.lua
	@test -f examples/tutorial/13_process.lua
	@test -f tests/io/test_socket_conformance.lua
	@test -f tests/io/test_resolver.lua
	@test -f tests/io/test_datagram.lua
	@test -f tests/io/test_datagram_conformance.lua
	@test -f tests/embedding/test_datagram_optional_providers.lua
	@test -f tests/embedding/test_socket_resolver_optional_providers.lua
	@test -f tests/internal/test_adoption_completion.lua
	@test -f tests/internal/test_datagram_service.lua
	@test -f tests/stress/test_stream_reactor_stress.lua
	@test -f tests/stress/test_socket_churn.lua
	@test -f tests/stress/test_datagram_churn.lua
	@test -f tests/native/test_datagram_native.lua
	@test -f tests/profiles.lua
	@test -f docs/guide/io.md
	@test -f docs/guide/direct-and-options.md
	@test -f scripts/check-links.lua
	@test ! -e experiments/scalar_flow.lua
	@test -f reference/fibers/internal/reference_machine.lua
	@test ! -e src/fibers/internal/reference_machine.lua
	@test -f performance/bench.lua
	@test -f performance/io_baselines.lua
	@test -f performance/proof_engine_io.lua
	@test -f docs/notes/performance/PROOF-ENGINE-PROGRAMME.md
	@test ! -e benchmarks
	@! grep -RInE '^[[:space:]]*supply[[:space:]]*=' src examples experiments reference --include='*.lua'
	@! grep -RInE '^[[:space:]]*supply_(up|down|any)[[:space:]]*=' src examples experiments reference --include='*.lua'

