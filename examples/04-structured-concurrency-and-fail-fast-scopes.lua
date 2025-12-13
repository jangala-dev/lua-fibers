package.path = '../src/?.lua;' .. package.path

local fibers    = require 'fibers'
local run       = fibers.run
local spawn     = fibers.spawn
local run_scope = fibers.run_scope
local now       = fibers.now

local sleep = require 'fibers.sleep'.sleep

local function sometimes_fails(name, delay, fail_after)
	for _ = 1, fail_after - 1 do
		print(('[%s] ok at t=%.2f'):format(name, now()))
		sleep(delay)
	end
	error(('[%s] failed after %d iterations'):format(name, fail_after))
end

local function sibling(name, delay)
	while true do
		print(('[%s] still running at t=%.2f'):format(name, now()))
		sleep(delay)
	end
end

local function main()
	print('Main: starting child scope')

	local status, err = run_scope(function (child_scope)
		-- All fibers spawned here are supervised by child_scope.
		spawn(sometimes_fails, 'flaky', 0.3, 4)
		spawn(sibling, 'sibling', 0.2)

		-- Block until child_scope terminates:
		-- - if flaky fails, child_scope becomes "failed" and cancels siblings.
		-- - if everything finishes, status is "ok".
		local s, e = child_scope:status()
		print('Child initial status:', s, e)

		-- wait for completion using the scope join op
		local ok, join_err = child_scope:sync(child_scope:join_op())
		print('child_scope:join_op() ->', ok, join_err)
	end)

	print('Main: child scope finished with:', status, err)

	if status ~= 'ok' then
		print('Main: treating non-ok child status as error')
	end
end

run(main)
