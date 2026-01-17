-- tests/test_stream_mem.lua
--
-- Synthetic tests for fibers.io.stream using an in-memory backend.
print('testing: fibers.io.stream')

-- look one level up
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

-- In-memory duplex backend with partial I/O and readiness notifications.
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
		-- Deliberately read at most 1 byte to exercise partial reads.
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

-- Variant backend to assert 'want' propagation:
-- rd_io:read_string returns want='wr' when empty; and only 'wr' waiters are notified.
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
			-- Would block; request registration on writability.
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
		-- Only notify "wr". If Stream ignores want and waits on "rd", it will hang.
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

local function test_basic_line_read()
	local rd, wr, shared = make_stream_pair()

	wr:setvbuf('line')
	assert(wr.line_buffering == true, "setvbuf('line') did not set line_buffering")

	local message = 'hello, world\n'

	fibers.spawn(function ()
		sleep.sleep(0.01)
		local n, err = wr:write(message)
		assert(err == nil, 'write error: ' .. tostring(err))
		assert(n == #message, 'write wrote ' .. tostring(n) .. ' bytes, expected ' .. #message)
		wr:close()
	end)

	local line, err = rd:read('*L')
	assert(err == nil, "read('*L') returned error: " .. tostring(err))
	assert(line == message,
		("read('*L') returned %q, expected %q"):format(tostring(line), tostring(message)))

	rd:close()
	assert(shared.waitset:size('rd') == 0, 'waitset still has readers after close')
end

local function test_close_unblocks_reader_no_crash()
	local rd, wr, shared = make_stream_pair()

	fibers.spawn(function ()
		sleep.sleep(0.01)
		rd:close()
	end)

	local won, line, err = with_timeout(rd:read_op('*L'), 0.2)
	assert(won == true, 'timed out waiting for blocked read to resolve on close')
	assert(line == nil, 'expected nil line on close, got ' .. tostring(line))
	assert(err == 'stream closed', 'expected err "stream closed", got ' .. tostring(err))

	assert(shared.waitset:size('rd') == 0, 'waitset still has readers after close-unblock')

	wr:close()
end

local function test_abort_unlinks_waiters()
	local rd, wr, shared = make_stream_pair()

	-- Block a read, then abort it via timeout choice.
	local won = with_timeout(rd:read_exactly_op(1), 0.02)
	assert(won == false, 'expected timeout branch to win')

	-- The op lost the choice; its wait registration must be cancelled.
	assert(shared.waitset:size('rd') == 0, 'waitset leaked readers after abort')

	rd:close()
	wr:close()
end

local function test_want_wiring_wr()
	local rd, wr, shared = make_stream_pair_want_wr()

	local message = 'x\n'

	fibers.spawn(function ()
		sleep.sleep(0.01)
		local n, err = wr:write(message)
		assert(err == nil, 'write error: ' .. tostring(err))
		assert(n == #message, 'write wrote ' .. tostring(n) .. ' bytes, expected ' .. #message)
		wr:close()
	end)

	local won, line, err = with_timeout(rd:read_op('*L'), 0.2)
	assert(won == true, 'timed out: want="wr" registration did not wake')
	assert(err == nil, 'read returned error: ' .. tostring(err))
	assert(line == message, ('read returned %q, expected %q'):format(tostring(line), tostring(message)))

	-- Strong regression checks: should register on_writable (want='wr'), not on_readable.
	assert(shared.wr_regs > 0, 'expected on_writable registrations (want="wr")')
	assert(shared.rd_regs == 0, 'unexpected on_readable registrations; want wiring may be ignored')

	rd:close()
	assert(shared.waitset:size('wr') == 0, 'waitset leaked wr waiters')
end

local function main()
	test_basic_line_read()
	test_close_unblocks_reader_no_crash()
	test_abort_unlinks_waiters()
	test_want_wiring_wr()
end

fibers.run(main)

print('selftest: ok')
