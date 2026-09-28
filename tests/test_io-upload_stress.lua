-- tests/test_io-upload_stress.lua
--
-- Small upload-shaped regression test for long-lived scopes.  It exercises the
-- socket -> stream -> file path repeatedly in the same scope and asserts that
-- the scope's cancellation/fault one-shots do not retain cancelled waiters from
-- completed I/O operations.

print('testing: fibers.io upload stress')

package.path = '../src/?.lua;' .. package.path
package.path = package.path .. ';/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua'

if os.getenv('LUA_FIBERS_SKIP_UPLOAD_STRESS') == '1' then
	print('test_io-upload_stress.lua: skipped by LUA_FIBERS_SKIP_UPLOAD_STRESS=1')
	return
end

local fibers     = require 'fibers'
local socket_mod = require 'fibers.io.socket'
local file_mod   = require 'fibers.io.file'
local waitgroup  = require 'fibers.waitgroup'
local safe       = require 'coxpcall'

local perform = fibers.perform

local MB          = tonumber(os.getenv('LUA_FIBERS_UPLOAD_STRESS_MB') or '4')
local REPEAT      = tonumber(os.getenv('LUA_FIBERS_UPLOAD_STRESS_REPEAT') or '3')
local WRITE_CHUNK = tonumber(os.getenv('LUA_FIBERS_UPLOAD_STRESS_WRITE_CHUNK') or tostring(64 * 1024))
local READ_CHUNK  = tonumber(os.getenv('LUA_FIBERS_UPLOAD_STRESS_READ_CHUNK') or tostring(32 * 1024))

assert(MB and MB > 0, 'bad LUA_FIBERS_UPLOAD_STRESS_MB')
assert(REPEAT and REPEAT > 0, 'bad LUA_FIBERS_UPLOAD_STRESS_REPEAT')
assert(WRITE_CHUNK and WRITE_CHUNK > 0, 'bad LUA_FIBERS_UPLOAD_STRESS_WRITE_CHUNK')
assert(READ_CHUNK and READ_CHUNK > 0, 'bad LUA_FIBERS_UPLOAD_STRESS_READ_CHUNK')

local TOTAL_BYTES = MB * 1024 * 1024

local function waiter_slots(os)
	local ws = os and os.waiters
	return ws and #ws or 0
end

local function collect_full()
	collectgarbage('collect')
	collectgarbage('collect')
end

local function checked_spawn(scope, wg, errors, fn)
	wg:add(1)
	scope:spawn(function ()
		local ok, err = safe.pcall(fn)
		if not ok then
			errors[#errors + 1] = err
		end
		wg:done()
	end)
end

local function close_best_effort(obj)
	if obj and obj.close then
		safe.pcall(function () obj:close() end)
	end
end

local function write_all(stream, data)
	local n, err = perform(stream:write_op(data))
	assert(err == nil, 'write failed: ' .. tostring(err))
	assert(n == #data, ('short write: %s of %s'):format(tostring(n), tostring(#data)))
end

local function run_upload_once(scope, iter)
	local tmpdir = os.getenv('TMPDIR') or '/tmp'
	local path = string.format('%s/fibers_upload_stress.%d.%d.%d.sock',
		tmpdir, os.time(), math.random(1, 1000000), iter)

	local listener, lerr = socket_mod.listen_unix(path, { ephemeral = true })
	assert(listener, 'listen_unix failed: ' .. tostring(lerr))

	local out, ferr = file_mod.tmpfile()
	assert(out, 'tmpfile failed: ' .. tostring(ferr))

	local wg = waitgroup.new()
	local errors = {}
	local chunk = string.rep('u', WRITE_CHUNK)

	checked_spawn(scope, wg, errors, function ()
		local conn, aerr = listener:accept()
		assert(conn, 'accept failed: ' .. tostring(aerr))

		local got = 0
		while true do
			local data, cnt, rerr = perform(conn:core_read_op {
				min = 1,
				max = READ_CHUNK,
				eof_ok = true,
			})
			assert(rerr == nil, 'read failed: ' .. tostring(rerr))
			if not data or cnt == 0 then
				break
			end
			got = got + cnt
			write_all(out, data)
		end

		assert(got == TOTAL_BYTES,
			('server received %d bytes, expected %d'):format(got, TOTAL_BYTES))

		close_best_effort(conn)
		close_best_effort(out)
		close_best_effort(listener)
	end)

	checked_spawn(scope, wg, errors, function ()
		local client, cerr = socket_mod.connect_unix(path)
		assert(client, 'connect_unix failed: ' .. tostring(cerr))

		local sent = 0
		while sent < TOTAL_BYTES do
			local n = math.min(#chunk, TOTAL_BYTES - sent)
			if n == #chunk then
				write_all(client, chunk)
			else
				write_all(client, chunk:sub(1, n))
			end
			sent = sent + n
		end

		close_best_effort(client)
	end)

	perform(wg:wait_op())

	if #errors > 0 then
		error(('upload iteration %d failed: %s'):format(iter, tostring(errors[1])))
	end
end

local function main(scope)
	math.randomseed(os.time())
	collect_full()

	local base_cancel = waiter_slots(scope._cancel_os)
	local base_fault = waiter_slots(scope._fault_os)

	for i = 1, REPEAT do
		run_upload_once(scope, i)
		collect_full()

		local cancel_slots = waiter_slots(scope._cancel_os)
		local fault_slots = waiter_slots(scope._fault_os)
		assert(cancel_slots == base_cancel,
			('scope cancel waiter slots grew after upload %d: base=%d now=%d'):
			format(i, base_cancel, cancel_slots))
		assert(fault_slots == base_fault,
			('scope fault waiter slots grew after upload %d: base=%d now=%d'):
			format(i, base_fault, fault_slots))
	end
end

fibers.run(main)

print(('test_io-upload_stress.lua: %d x %d MiB upload-shaped checks passed'):
	format(REPEAT, MB))
