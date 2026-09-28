-- fibers/op compact but comprehensive test (no poll)
print('testing: fibers.op')

-- look one level up
package.path = '../src/?.lua;' .. package.path

local op      = require 'fibers.op'
local runtime = require 'fibers.runtime'

local perform = require 'fibers.performer'.perform
local choice  = op.choice
local always  = op.always
local never   = op.never

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function async_task(val)
	local tries = 0

	local function try_fn()
		tries = tries + 1
		return false
	end

	local function block_fn(suspension, wrap_fn)
		local t = suspension:complete_task(wrap_fn, val)
		suspension.sched:schedule(t)
	end

	local ev = op.new_primitive(nil, try_fn, block_fn)
	return ev, function () return tries end
end

local function assert_error(label, fn)
	local ok = pcall(fn)
	assert(ok == false, label .. ': expected error')
end

------------------------------------------------------------
-- Run all tests inside a single top-level fibre
------------------------------------------------------------

runtime.spawn_raw(function ()

	--------------------------------------------------------
	-- 1) Base op: perform, or_else, wrap
	--------------------------------------------------------
	do
		local base = always(1)
		assert(perform(base) == 1, 'base: perform failed')

		local ev1 = always(2):or_else(function () return 9 end)
		assert(perform(ev1) == 2, 'base: or_else should use op result')

		local ev2 = never():or_else(function () return 99 end)
		assert(perform(ev2) == 99,
			"base: or_else should use fallback when op can't commit")

		do
			local fallback_called = false
			local ev_async, tries = async_task(123)

			local ev = ev_async:or_else(function ()
				fallback_called = true
				return -1
			end)

			assert(perform(ev) == -1,
				'or_else(async): expected fallback to win')
			assert(tries() == 1,
				'async_task: try_fn should be called exactly once')
			assert(fallback_called == true,
				'or_else(async): fallback should run when op is not ready')
		end

		local ev3 = always(5)
			:wrap(function (x) return x + 1 end)
			:wrap(function (y) return y * 2 end)

		assert(perform(ev3) == 12, 'nested wrap: wrong result')
	end

	--------------------------------------------------------
	-- 2) Blocking path: async_task
	--------------------------------------------------------
	do
		local ev, tries = async_task(42)
		assert(perform(ev) == 42, 'async_task: wrong result')
		assert(tries() == 1, 'async_task: try_fn not called exactly once')
	end

	--------------------------------------------------------
	-- 3) Choice: varargs, tables, empty choices, flattening
	--------------------------------------------------------
	do
		local choice_ev = choice(always(1), always(2), always(3))

		for _ = 1, 5 do
			local v = perform(choice_ev)
			assert(v == 1 or v == 2 or v == 3,
				'choice(ready varargs): result not in {1,2,3}')
		end

		local table_ev = choice({ always('a'), always('b') })
		do
			local v = perform(table_ev)
			assert(v == 'a' or v == 'b',
				'choice(table): result not in {a,b}')
		end

		local mixed_ev = choice(
			never(),
			{ always('x'), never() },
			{ { always('y') } }
		)

		do
			local v = perform(mixed_ev)
			assert(v == 'x' or v == 'y',
				'choice(mixed vararg/table): wrong result')
		end

		local nested_ev = choice(
			choice(always('inner-a'), always('inner-b')),
			always('outer')
		)

		do
			local v = perform(nested_ev)
			assert(
				v == 'inner-a' or v == 'inner-b' or v == 'outer',
				'choice(nested flatten): wrong result'
			)
		end

		local empty1 = choice():or_else(function () return 'empty-varargs' end)
		assert(perform(empty1) == 'empty-varargs',
			'choice(): should behave as never-ready')

		local empty2 = choice({}):or_else(function () return 'empty-table' end)
		assert(perform(empty2) == 'empty-table',
			'choice({}): should behave as never-ready')

		local empty_nested = choice(choice(), always('win'))
		assert(perform(empty_nested) == 'win',
			'choice(empty choice, ready op): empty nested choice should disappear')

		local wrapped = choice(always(1), always(2)):wrap(function (x)
			return x * 10
		end)

		do
			local v = perform(wrapped)
			assert(v == 10 or v == 20, 'wrap(choice): wrong result')
		end
	end

	--------------------------------------------------------
	-- 4) Choice validation regressions
	--------------------------------------------------------
	do
		assert_error('choice(non-op)', function ()
			choice(123)
		end)

		assert_error('choice(nil)', function ()
			choice(nil)
		end)

		assert_error('choice(named table)', function ()
			choice({ foo = always(1) })
		end)

		assert_error('choice(sparse table)', function ()
			choice({
				[1] = always(1),
				[3] = always(3),
			})
		end)

		assert_error('choice(table with non-op)', function ()
			choice({ always(1), 'bad' })
		end)
	end

	--------------------------------------------------------
	-- 5) Guard: basic + in choice + with with_nack
	--------------------------------------------------------
	do
		local calls = 0

		local ev = op.guard(function ()
			calls = calls + 1
			return always(42)
		end)

		assert(perform(ev) == 42, 'guard basic: wrong result')
		assert(calls == 1, 'guard basic: builder not called once')

		local calls2 = 0
		local guarded = op.guard(function ()
			calls2 = calls2 + 1
			return always(10)
		end)

		local choice_ev = choice(guarded, always(20))
		local runs = 5

		for _ = 1, runs do
			local r = perform(choice_ev)
			assert(r == 10 or r == 20,
				'guard in choice: result not in {10,20}')
		end

		assert(calls2 == runs, 'guard in choice: builder call mismatch')

		local guard_calls, cancelled = 0, false

		local guarded_nack = op.guard(function ()
			guard_calls = guard_calls + 1

			return op.with_nack(function (nack_ev)
				runtime.spawn_raw(function ()
					perform(nack_ev)
					cancelled = true
				end)

				return never()
			end)
		end)

		local ev2 = choice(guarded_nack, always('OK'))
		assert(perform(ev2) == 'OK', 'guard+with_nack: wrong winner')

		runtime.yield()
		assert(cancelled == true, 'guard+with_nack: nack not fired')
		assert(guard_calls == 1, 'guard+with_nack: builder not once')
	end

	--------------------------------------------------------
	-- 6) or_else on composite ops
	--------------------------------------------------------
	do
		local comp_ready = choice(always(1), always(2))
		local r1 = perform(comp_ready:or_else(function () return 99 end))

		assert(r1 == 1 or r1 == 2,
			'or_else(composite ready): wrong result')

		local comp_never = choice(never(), never())
		local r2 = perform(comp_never:or_else(function () return 42 end))

		assert(r2 == 42,
			'or_else(composite none): fallback not used')

		local empty = choice():or_else(function () return 'fallback' end)
		assert(perform(empty) == 'fallback',
			'or_else(empty choice): fallback not used')

		local table_empty = choice({}):or_else(function () return 'fallback2' end)
		assert(perform(table_empty) == 'fallback2',
			'or_else(empty table choice): fallback not used')
	end

	--------------------------------------------------------
	-- 7) Higher-level choice helpers over empty sets
	--------------------------------------------------------
	do
		local named_empty = op.named_choice({}):or_else(function ()
			return 'named-empty'
		end)

		assert(perform(named_empty) == 'named-empty',
			'named_choice({}): should behave as never-ready')

		local race_empty = op.race({}, function ()
			return 'unreachable'
		end):or_else(function ()
			return 'race-empty'
		end)

		assert(perform(race_empty) == 'race-empty',
			'race({}): should behave as never-ready')

		local first_empty = op.first_ready({}):or_else(function ()
			return 'first-empty'
		end)

		assert(perform(first_empty) == 'first-empty',
			'first_ready({}): should behave as never-ready')
	end

	--------------------------------------------------------
	-- 8) with_nack: winner vs loser, basic nesting
	--------------------------------------------------------
	do
		do
			local cancelled = false

			local with_nack_ev = op.with_nack(function (nack_ev)
				runtime.spawn_raw(function ()
					perform(nack_ev)
					cancelled = true
				end)

				return always('WIN')
			end)

			assert(perform(choice(with_nack_ev, never())) == 'WIN',
				'with_nack win: wrong winner')

			runtime.yield()
			assert(cancelled == false,
				'with_nack win: nack fired unexpectedly')
		end

		do
			local cancelled = false

			local with_nack_ev = op.with_nack(function (nack_ev)
				runtime.spawn_raw(function ()
					perform(nack_ev)
					cancelled = true
				end)

				return never()
			end)

			assert(perform(choice(with_nack_ev, always('OTHER'))) == 'OTHER',
				'with_nack loss: wrong winner')

			runtime.yield()
			assert(cancelled == true,
				'with_nack loss: nack did not fire')
		end

		do
			local outer_cancelled, inner_cancelled = false, false

			local outer = op.with_nack(function (outer_nack_ev)
				runtime.spawn_raw(function ()
					perform(outer_nack_ev)
					outer_cancelled = true
				end)

				return op.with_nack(function (inner_nack_ev)
					runtime.spawn_raw(function ()
						perform(inner_nack_ev)
						inner_cancelled = true
					end)

					return always('INNER_WIN')
				end)
			end)

			assert(perform(choice(outer, never())) == 'INNER_WIN',
				'nested with_nack: wrong result')

			runtime.yield()

			assert(outer_cancelled == false,
				'nested with_nack: outer nack fired unexpectedly')
			assert(inner_cancelled == false,
				'nested with_nack: inner nack fired unexpectedly')
		end
	end

	--------------------------------------------------------
	-- 9) on_abort and empty-choice regression
	--------------------------------------------------------
	do
		local aborted = false

		local losing = choice():on_abort(function ()
			aborted = true
		end)

		assert(perform(choice(losing, always('winner'))) == 'winner',
			'on_abort(empty choice): wrong winner')

		assert(aborted == true,
			'on_abort(empty choice): abort handler should run when losing')
	end

	--------------------------------------------------------
	-- 10) bracket: RAII-style resource management over ops
	--------------------------------------------------------
	do
		do
			local acq_count = 0
			local rel_count = 0
			local use_count = 0
			local last_res, last_aborted

			local ev = op.bracket(
				function ()
					acq_count = acq_count + 1
					return 'RESOURCE'
				end,

				function (res, aborted)
					rel_count    = rel_count + 1
					last_res     = res
					last_aborted = aborted
				end,

				function (res)
					use_count = use_count + 1
					assert(res == 'RESOURCE',
						'bracket basic: wrong resource')
					return always(99)
				end
			)

			assert(perform(ev) == 99, 'bracket basic: wrong result')
			assert(acq_count == 1, 'bracket basic: acquire not once')
			assert(use_count == 1, 'bracket basic: use not once')
			assert(rel_count == 1, 'bracket basic: release not once')
			assert(last_res == 'RESOURCE',
				'bracket basic: wrong res in release')
			assert(last_aborted == false,
				'bracket basic: aborted flag should be false on success')
		end

		do
			local acq_count, use_count, rel_count = 0, 0, 0
			local last_aborted

			local bracket_ev = op.bracket(
				function ()
					acq_count = acq_count + 1
					return 'R'
				end,

				function (_, aborted)
					rel_count    = rel_count + 1
					last_aborted = aborted
				end,

				function (r)
					use_count = use_count + 1
					assert(r == 'R')
					return never()
				end
			)

			assert(perform(choice(bracket_ev, always('WIN'))) == 'WIN',
				'bracket choice: wrong winner')

			assert(acq_count == 1, 'bracket choice: acquire not once')
			assert(use_count == 1, 'bracket choice: use not once')
			assert(rel_count == 1, 'bracket choice: release not once')
			assert(last_aborted == true,
				'bracket choice: aborted flag should be true when losing')
		end

		do
			local acq_count, use_count, rel_count = 0, 0, 0
			local last_aborted, fallback_called

			local bracket_ev = op.bracket(
				function ()
					acq_count = acq_count + 1
					return 'R'
				end,

				function (_, aborted)
					rel_count    = rel_count + 1
					last_aborted = aborted
				end,

				function (r)
					use_count = use_count + 1
					assert(r == 'R')
					return never()
				end
			)

			local ev = bracket_ev:or_else(function ()
				fallback_called = true
				return 'FALLBACK'
			end)

			assert(perform(ev) == 'FALLBACK',
				'bracket+or_else: expected fallback result')
			assert(fallback_called == true,
				'bracket+or_else: fallback thunk not called')
			assert(acq_count == 1, 'bracket+or_else: acquire once')
			assert(use_count == 1, 'bracket+or_else: use once')
			assert(rel_count == 1, 'bracket+or_else: release once')
			assert(last_aborted == true,
				'bracket+or_else: aborted flag should be true when losing')
		end
	end

	--------------------------------------------------------
	-- 11) finally: cleanup on success and on abort
	--------------------------------------------------------
	do
		do
			local calls = {}

			local ev = always(7):finally(function (aborted)
				calls[#calls + 1] = aborted
			end)

			assert(perform(ev) == 7, 'finally(success): wrong result')
			assert(#calls == 1, 'finally(success): cleanup not called once')
			assert(calls[1] == false,
				'finally(success): aborted should be false')
		end

		do
			local calls = {}

			local base = never():finally(function (aborted)
				calls[#calls + 1] = aborted
			end)

			assert(perform(choice(base, always('WIN'))) == 'WIN',
				'finally(abort): wrong winner')
			assert(#calls == 1,
				'finally(abort): cleanup not called once')
			assert(calls[1] == true,
				'finally(abort): aborted should be true')
		end

		do
			local calls = {}

			local base = choice():finally(function (aborted)
				calls[#calls + 1] = aborted
			end)

			assert(perform(choice(base, always('WIN'))) == 'WIN',
				'finally(empty choice abort): wrong winner')
			assert(#calls == 1,
				'finally(empty choice abort): cleanup not called once')
			assert(calls[1] == true,
				'finally(empty choice abort): aborted should be true')
		end
	end

	print('fibers.op tests: ok')
	runtime.stop()
end)

runtime.main()
