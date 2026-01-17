-- tests/test_stream_mem.lua
--
-- Synthetic tests for fibers.io.stream using in-memory backends.
print('testing: fibers.io.stream')

package.path = '../src/?.lua;' .. package.path

local fibers  = require 'fibers'
local stream  = require 'fibers.io.stream'
local wait    = require 'fibers.wait'
local runtime = require 'fibers.runtime'
local sleep   = require 'fibers.sleep'
local op      = require 'fibers.op'
local perform = require 'fibers.performer'.perform

local function with_timeout(ev, timeout_s)
	-- op.boolean_choice returns: (won:boolean, ...results...)
	return perform(op.boolean_choice(ev, sleep.sleep_op(timeout_s)))
end

local function assert_eq(a, b, msg)
	if a ~= b then
		error((msg or 'assert_eq failed') .. (': got ' .. tostring(a) .. ', expected ' .. tostring(b)), 2)
	end
end

local function assert_truthy(v, msg)
	if not v then error(msg or 'expected truthy', 2) end
end

----------------------------------------------------------------------
-- Backend 1: basic duplex, partial writes, only "rd" notifications
-- (matches your original tests; sufficient for read-focused tests)
----------------------------------------------------------------------

local function make_stream_pair()
	local shared = {
		buf     = '',
		closed  = false,
		waitset = wait.new_waitset(), -- key "rd" for readability
	}

	local rd_io = { shared = shared }
	local wr_io = { shared = shared }

	function rd_io:read_string(max)
		if #self.shared.buf == 0 then
			if self.shared.closed then
				return '', nil -- EOF
			end
			return nil, nil -- would block
		end
		max = max or 1
		local n = math.min(1, max, #self.shared.buf)
		local s = self.shared.buf:sub(1, n)
		self.shared.buf = self.shared.buf:sub(n + 1)
		return s, nil
	end

	function wr_io:write_string(str)
		if self.shared.closed then
			return nil, 'closed'
		end
		if #str == 0 then
			return 0, nil
		end
		local n    = 1
		local ch   = str:sub(1, n)
		shared.buf = shared.buf .. ch
		shared.waitset:notify_all('rd', runtime.current_scheduler)
		return n, nil
	end

	function rd_io:on_readable(task)
		return shared.waitset:add('rd', task)
	end

	function wr_io:on_writable(task)
		runtime.current_scheduler:schedule(task)
		return { unlink = function () end }
	end

	function rd_io:close()
		shared.closed = true
		shared.waitset:notify_all('rd', runtime.current_scheduler)
		return true
	end

	function wr_io:close()
		shared.closed = true
		shared.waitset:notify_all('rd', runtime.current_scheduler)
		return true
	end

	function rd_io:seek() return nil, 'not seekable' end
	function wr_io:seek() return nil, 'not seekable' end
	function rd_io:nonblock() end
	function rd_io:block() end
	function wr_io:nonblock() end
	function wr_io:block() end

	local rd = stream.open(rd_io, true, false)
	local wr = stream.open(wr_io, false, true)
	return rd, wr, shared
end

----------------------------------------------------------------------
-- Backend 2: "want='wr'" read wakeups to validate want propagation
----------------------------------------------------------------------

local function make_stream_pair_want_wr()
	local shared = {
		buf      = '',
		closed   = false,
		waitset  = wait.new_waitset(), -- use key "wr" only for wakeups
		rd_regs  = 0,
		wr_regs  = 0,
	}

	local rd_io = { shared = shared }
	local wr_io = { shared = shared }

	function rd_io:read_string(max)
		if #self.shared.buf == 0 then
			if self.shared.closed then
				return '', nil -- EOF
			end
			return nil, nil, 'wr'
		end
		max = max or 1
		local n = math.min(1, max, #self.shared.buf)
		local s = self.shared.buf:sub(1, n)
		self.shared.buf = self.shared.buf:sub(n + 1)
		return s, nil
	end

	function wr_io:write_string(str)
		if self.shared.closed then
			return nil, 'closed'
		end
		if #str == 0 then
			return 0, nil
		end
		local n    = 1
		local ch   = str:sub(1, n)
		shared.buf = shared.buf .. ch
		shared.waitset:notify_all('wr', runtime.current_scheduler)
		return n, nil
	end

	function rd_io:on_readable(task)
		shared.rd_regs = shared.rd_regs + 1
		return shared.waitset:add('rd', task)
	end

	function rd_io:on_writable(task)
		shared.wr_regs = shared.wr_regs + 1
		return shared.waitset:add('wr', task)
	end

	function wr_io:on_writable(task)
		runtime.current_scheduler:schedule(task)
		return { unlink = function () end }
	end

	function rd_io:close()
		shared.closed = true
		shared.waitset:notify_all('wr', runtime.current_scheduler)
		shared.waitset:notify_all('rd', runtime.current_scheduler)
		return true
	end

	function wr_io:close()
		shared.closed = true
		shared.waitset:notify_all('wr', runtime.current_scheduler)
		shared.waitset:notify_all('rd', runtime.current_scheduler)
		return true
	end

	function rd_io:seek() return nil, 'not seekable' end
	function wr_io:seek() return nil, 'not seekable' end
	function rd_io:nonblock() end
	function rd_io:block() end
	function wr_io:nonblock() end
	function wr_io:block() end

	local rd = stream.open(rd_io, true, false)
	local wr = stream.open(wr_io, false, true)
	return rd, wr, shared
end

----------------------------------------------------------------------
-- Backend 3: full duplex for buffered write/flush tests
-- - supports on_writable waiters and explicit "wr" notifications
-- - write_string appends 1 byte to a "wire" buffer (partial write)
-- - read_string drains from the wire buffer (partial read)
----------------------------------------------------------------------

local function make_stream_pair_full()
	local shared = {
		wire    = '',
		closed  = false,
		waitset = wait.new_waitset(), -- keys: 'rd'
	}

	local rd_io = { shared = shared }
	local wr_io = { shared = shared }

	function rd_io:read_string(max)
		if #self.shared.wire == 0 then
			if self.shared.closed then
				return '', nil -- EOF
			end
			return nil, nil -- would block
		end

		max = max or 1
		local n = math.min(1, max, #self.shared.wire)
		local s = self.shared.wire:sub(1, n)
		self.shared.wire = self.shared.wire:sub(n + 1)
		return s, nil
	end

	function wr_io:write_string(str)
		if self.shared.closed then
			return nil, 'closed'
		end
		if #str == 0 then
			return 0, nil
		end

		-- partial: accept only 1 byte per call
		local ch = str:sub(1, 1)
		self.shared.wire = self.shared.wire .. ch

		-- writing makes reads possible
		self.shared.waitset:notify_all('rd', runtime.current_scheduler)
		return 1, nil
	end

	function rd_io:on_readable(task)
		return self.shared.waitset:add('rd', task)
	end

	-- Model "always writable": wake immediately.
	function wr_io:on_writable(task)
		runtime.current_scheduler:schedule(task)
		return { unlink = function () end }
	end

	function rd_io:close()
		self.shared.closed = true
		self.shared.waitset:notify_all('rd', runtime.current_scheduler)
		return true
	end

	function wr_io:close()
		self.shared.closed = true
		self.shared.waitset:notify_all('rd', runtime.current_scheduler)
		return true
	end

	function rd_io:seek() return nil, 'not seekable' end
	function wr_io:seek() return nil, 'not seekable' end
	function rd_io:nonblock() end
	function rd_io:block() end
	function wr_io:nonblock() end
	function wr_io:block() end

	local rd = stream.open(rd_io, true, false)
	local wr = stream.open(wr_io, false, true)
	return rd, wr, shared
end

-- Full duplex backend with backpressure:
-- - wire has a finite capacity; write_string blocks when full (want='wr')
-- - read_string frees space and notifies 'wr'
local function make_stream_pair_full_backpressure(cap)
	cap = cap or 8

	local shared = {
		wire    = '',
		closed  = false,
		waitset = wait.new_waitset(), -- keys: 'rd', 'wr'
		cap     = cap,
	}

	local rd_io = { shared = shared }
	local wr_io = { shared = shared }

	function rd_io:read_string(max)
		if #self.shared.wire == 0 then
			if self.shared.closed then
				return '', nil -- EOF
			end
			return nil, nil -- would block
		end

		max = max or 1
		local n = math.min(1, max, #self.shared.wire)
		local s = self.shared.wire:sub(1, n)
		self.shared.wire = self.shared.wire:sub(n + 1)

		-- freeing space enables writers
		self.shared.waitset:notify_all('wr', runtime.current_scheduler)
		return s, nil
	end

	function wr_io:write_string(str)
		if self.shared.closed then
			return nil, 'closed'
		end
		if #str == 0 then
			return 0, nil
		end

		-- backpressure: wire full -> would block, request 'wr'
		if #self.shared.wire >= self.shared.cap then
			return nil, nil, 'wr'
		end

		-- partial: accept only 1 byte
		local ch = str:sub(1, 1)
		self.shared.wire = self.shared.wire .. ch

		-- writing enables readers
		self.shared.waitset:notify_all('rd', runtime.current_scheduler)
		return 1, nil
	end

	function rd_io:on_readable(task)
		return self.shared.waitset:add('rd', task)
	end

	function wr_io:on_writable(task)
		return self.shared.waitset:add('wr', task)
	end

	function rd_io:close()
		self.shared.closed = true
		self.shared.waitset:notify_all('rd', runtime.current_scheduler)
		self.shared.waitset:notify_all('wr', runtime.current_scheduler)
		return true
	end

	function wr_io:close()
		self.shared.closed = true
		self.shared.waitset:notify_all('rd', runtime.current_scheduler)
		self.shared.waitset:notify_all('wr', runtime.current_scheduler)
		return true
	end

	function rd_io:seek() return nil, 'not seekable' end
	function wr_io:seek() return nil, 'not seekable' end
	function rd_io:nonblock() end
	function rd_io:block() end
	function wr_io:nonblock() end
	function wr_io:block() end

	local rd = stream.open(rd_io, true, false)
	local wr = stream.open(wr_io, false, true)
	return rd, wr, shared
end


----------------------------------------------------------------------
-- Existing tests (kept)
----------------------------------------------------------------------

local function test_basic_line_read()
	local rd, wr, shared = make_stream_pair()

	rd:setvbuf('full')
	wr:setvbuf('line')
	assert_truthy(wr.line_buffering == true, "setvbuf('line') did not set line_buffering")

	local message = 'hello, world\n'

	fibers.spawn(function ()
		sleep.sleep(0.01)
		local n, err = perform(wr:write_op(message))
		assert_eq(err, nil, 'write error')
		assert_eq(n, #message, 'write length mismatch')

		local ok, cerr = perform(wr:close_op())
		assert_eq(ok, true, 'close ok expected')
		assert_eq(cerr, nil, 'close err expected nil')
	end)

	local line, err, complete = perform(rd:read_line_op { keep_terminator = true })
	assert_eq(err, nil, 'read_line_op error')
	assert_eq(complete, true, 'expected complete line read')
	assert_eq(line, message, 'read_line_op returned wrong line')

	local ok, cerr = perform(rd:close_op())
	assert_eq(ok, true, 'close ok expected')
	assert_eq(cerr, nil, 'close err expected nil')

	assert_eq(shared.waitset:size('rd'), 0, 'waitset still has readers after close')
end

local function test_close_unblocks_reader_no_crash()
	local rd, wr, shared = make_stream_pair()

	fibers.spawn(function ()
		sleep.sleep(0.01)
		local ok, cerr = perform(rd:close_op())
		assert_eq(ok, true)
		assert_eq(cerr, nil)
	end)

	local won, line, err, complete = with_timeout(rd:read_line_op { keep_terminator = true }, 0.2)
	assert_eq(won, true, 'timed out waiting for blocked read to resolve on close')
	assert_eq(line, nil, 'expected nil line on close')
	assert_eq(err, 'closed', 'expected err "closed" on close')
	assert_eq(complete, false, 'expected complete=false on close')

	assert_eq(shared.waitset:size('rd'), 0, 'waitset still has readers after close-unblock')

	local ok, cerr = perform(wr:close_op())
	assert_eq(ok, true)
	assert_eq(cerr, nil)
end

local function test_abort_unlinks_waiters()
	local rd, wr, shared = make_stream_pair()

	local won = with_timeout(rd:read_exactly_op(1), 0.02)
	assert_eq(won, false, 'expected timeout branch to win')

	assert_eq(shared.waitset:size('rd'), 0, 'waitset leaked readers after abort')

	perform(rd:close_op())
	perform(wr:close_op())
end

local function test_want_wiring_wr()
	local rd, wr, shared = make_stream_pair_want_wr()

	local message = 'x\n'

	fibers.spawn(function ()
		sleep.sleep(0.01)
		local n, err = perform(wr:write_op(message))
		assert_eq(err, nil)
		assert_eq(n, #message)
		perform(wr:close_op())
	end)

	local won, line, err, complete = with_timeout(rd:read_line_op { keep_terminator = true }, 0.2)
	assert_eq(won, true, 'timed out: want="wr" registration did not wake')
	assert_eq(err, nil)
	assert_eq(complete, true)
	assert_eq(line, message)

	assert_truthy(shared.wr_regs > 0, 'expected on_writable registrations (want="wr")')
	assert_eq(shared.rd_regs, 0, 'unexpected on_readable registrations; want wiring may be ignored')

	perform(rd:close_op())
	assert_eq(shared.waitset:size('wr'), 0, 'waitset leaked wr waiters')
end

----------------------------------------------------------------------
-- New thorough surface tests
----------------------------------------------------------------------

local function test_flush_is_noop_on_readonly()
	local rd, _, _ = make_stream_pair()

	local ok, err = perform(rd:flush_op())
	assert_eq(ok, true, 'flush on read-only should succeed')
	assert_eq(err, nil, 'flush on read-only should have nil err')

	perform(rd:close_op())
end

local function test_read_some_and_exactly_and_all_eof_shapes()
	local rd, wr, _ = make_stream_pair_full()

	-- write then close writer: reader should be able to read remaining bytes then EOF
	local msg = 'abcdef'
	local n, werr = perform(wr:write_op(msg))
	assert_eq(werr, nil)
	assert_eq(n, #msg)

	-- flush and close writer
	local fok, ferr = perform(wr:flush_op())
	assert_eq(fok, true); assert_eq(ferr, nil)
	perform(wr:close_op())

	-- read_some max=2: should get 1..2 bytes (backend is 1-byte partial, but stream may coalesce)
	local s1, e1 = perform(rd:read_some_op(2))
	assert_eq(e1, nil)
	assert_truthy(type(s1) == 'string' and #s1 > 0 and #s1 <= 2, 'read_some size')

	-- read_exactly remaining-? eventually should succeed until depleted
	local rest_needed = #msg - #s1
	local s2, e2 = perform(rd:read_exactly_op(rest_needed))
	assert_eq(e2, nil)
	assert_eq(#s2, rest_needed)

	-- next read_some should return eof
	local s3, e3 = perform(rd:read_some_op(10))
	assert_eq(s3, nil)
	assert_eq(e3, 'eof')

	-- read_all on immediate EOF returns empty string + err (your stream returns '' and err)
	local all, aerr = perform(rd:read_all_op())
	assert_eq(all, '')
	-- aerr may be 'eof' or nil depending on whether stream reported EOF in the same op; accept both.
	assert_truthy(aerr == nil or aerr == 'eof', 'read_all err on eof')

	perform(rd:close_op())
end

local function test_write_buffering_write_then_flush_drains()
	local rd, wr, shared = make_stream_pair_full()

	local msg = ('x'):rep(256)

	-- Write should complete quickly (commit into tx/big), not wait for backend drain.
	local won, n, err = with_timeout(wr:write_op(msg), 0.05)
	assert_eq(won, true, 'write_op should not block on backend drain')
	assert_eq(err, nil)
	assert_eq(n, #msg)

	-- Not necessarily drained yet; now flush should drain to backend.
	local won2, ok, ferr = with_timeout(wr:flush_op(), 0.5)
	assert_eq(won2, true, 'flush_op should complete')
	assert_eq(ok, true)
	assert_eq(ferr, nil)

	-- Now read all should retrieve the full message (then EOF after close).
	perform(wr:close_op())

	local got, rerr = perform(rd:read_all_op())
	assert_eq(rerr, nil) -- may be nil if EOF cleanly after some data
	assert_eq(got, msg)

	perform(rd:close_op())

	-- No leftover waiters.
	assert_eq(shared.waitset:size('rd'), 0, 'rd waiters leaked')
	assert_eq(shared.waitset:size('wr'), 0, 'wr waiters leaked')
end

local function test_concurrent_writers_are_serialised_no_interleave()
	local rd, wr, shared = make_stream_pair_full()
	local wg = require('fibers.waitgroup').new()

	local a = ('A'):rep(64)
	local b = ('B'):rep(64)

	wg:add(2)

	fibers.spawn(function ()
		local n, err = perform(wr:write_op(a))
		assert_eq(err, nil); assert_eq(n, #a)
		wg:done()
	end)

	fibers.spawn(function ()
		local n, err = perform(wr:write_op(b))
		assert_eq(err, nil); assert_eq(n, #b)
		wg:done()
	end)

	-- Ensure both writes have committed before flushing/closing.
	wg:wait()

	local ok, ferr = perform(wr:flush_op())
	assert_eq(ok, true); assert_eq(ferr, nil)

	perform(wr:close_op())

	local all, rerr = perform(rd:read_all_op())
	assert_eq(rerr, nil)
	assert_eq(#all, #a + #b)

	local ab = a .. b
	local ba = b .. a
	assert_truthy(all == ab or all == ba, 'write interleaving detected: got=' .. tostring(all))

	perform(rd:close_op())

	assert_eq(shared.waitset:size('rd'), 0)
end

local function test_abort_unlinks_write_waiters_and_does_not_deadlock()
	-- Small wire capacity to force backpressure.
	local rd, wr, shared = make_stream_pair_full_backpressure(8)

	local msg = ('z'):rep(512)
	local n, err = perform(wr:write_op(msg))
	assert_eq(err, nil); assert_eq(n, #msg)

	-- No reader draining yet; flush should block and timeout should win.
	local won1 = with_timeout(wr:flush_op(), 0.001)
	assert_eq(won1, false, 'expected timeout branch to win (flush should block under backpressure)')

	-- After abort, we may legitimately have *one* wr waiter (the stream's drain pump).
	-- The key property is that repeated aborts do not accumulate waiters.
	local wr1 = shared.waitset:size('wr')
	local rd1 = shared.waitset:size('rd')
	assert_truthy(wr1 == 0 or wr1 == 1, ('unexpected wr waiter count after abort: %d'):format(wr1))
	assert_eq(rd1, 0, ('unexpected rd waiters after abort: %d'):format(rd1))

	local won2 = with_timeout(wr:flush_op(), 0.001)
	assert_eq(won2, false, 'expected timeout branch to win again')

	local wr2 = shared.waitset:size('wr')
	local rd2 = shared.waitset:size('rd')
	assert_eq(rd2, 0, ('unexpected rd waiters after second abort: %d'):format(rd2))
	assert_eq(wr2, wr1, ('wr waiter count grew across aborts: %d -> %d'):format(wr1, wr2))

	-- Now drain the wire so flush can complete.
	local wg = require('fibers.waitgroup').new()
	wg:add(1)

	fibers.spawn(function ()
		local s, rerr = perform(rd:read_exactly_op(#msg))
		assert_eq(rerr, nil)
		assert_eq(#s, #msg)
		wg:done()
	end)

	local won3, ok3, ferr3 = with_timeout(wr:flush_op(), 0.5)
	assert_eq(won3, true, 'flush did not complete after reader drained')
	assert_eq(ok3, true)
	assert_eq(ferr3, nil)

	-- Once drained, the pump should have unregistered.
	assert_eq(shared.waitset:size('wr'), 0, 'wr waiters not cleared after successful flush')
	assert_eq(shared.waitset:size('rd'), 0, 'rd waiters not cleared after successful flush')

	perform(wr:close_op())
	wg:wait()
	perform(rd:close_op())

	assert_eq(shared.waitset:size('wr'), 0, 'wr waiters leaked at end')
	assert_eq(shared.waitset:size('rd'), 0, 'rd waiters leaked at end')
end

local function test_seek_and_setvbuf_surface()
	local rd, wr, _ = make_stream_pair()

	-- setvbuf
	rd:setvbuf('full')
	assert_eq(rd.line_buffering, false)

	wr:setvbuf('line')
	assert_eq(wr.line_buffering, true)

	wr:setvbuf('no')
	assert_eq(wr.line_buffering, false)

	-- seek should fail on our backends
	local pos, err = rd:seek('cur', 0)
	assert_eq(pos, nil)
	assert_truthy(err ~= nil)

	perform(rd:close_op())
	perform(wr:close_op())
end

local function test_close_is_idempotent_and_unblocks_waiters()
	local rd, wr, shared = make_stream_pair_full()

	-- Block a read, then close.
	fibers.spawn(function ()
		sleep.sleep(0.01)
		perform(rd:close_op())
	end)

	local won, line, err, complete = with_timeout(rd:read_line_op { keep_terminator = true }, 0.2)
	assert_eq(won, true)
	assert_eq(line, nil)
	assert_eq(err, 'closed')
	assert_eq(complete, false)

	-- Second close should succeed too.
	local ok2, err2 = perform(rd:close_op())
	assert_eq(ok2, true)
	assert_eq(err2, nil)

	perform(wr:close_op())

	assert_eq(shared.waitset:size('rd'), 0)
	assert_eq(shared.waitset:size('wr'), 0)
end

----------------------------------------------------------------------
-- Main
----------------------------------------------------------------------

local function main()
	-- existing
	test_basic_line_read()
	test_close_unblocks_reader_no_crash()
	test_abort_unlinks_waiters()
	test_want_wiring_wr()

	-- new
	test_flush_is_noop_on_readonly()
	test_read_some_and_exactly_and_all_eof_shapes()
	test_write_buffering_write_then_flush_drains()
	test_concurrent_writers_are_serialised_no_interleave()
	test_abort_unlinks_write_waiters_and_does_not_deadlock()
	test_seek_and_setvbuf_surface()
	test_close_is_idempotent_and_unblocks_waiters()
end

fibers.run(main)

print('selftest: ok')
