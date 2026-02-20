-- tests/test_stream.lua
package.path = '../?.lua;' .. package.path

local sched_mod  = require 'fibers.sched'
local runtime    = require 'fibers.runtime'
local poller_mod = require 'fibers.io.poller.core'
local stream_mod = require 'fibers.io.stream'

local now = 0
local function now_fn() return now end
local function block_fn(dt) now = now + dt end

local function make_always_ready_poller()
  -- Whenever polled and any fd is present in rd_set/wr_set, report it ready.
  local ops = {
    new_backend = function() return {} end,
    poll = function(_backend, _timeout_ms, rd_set, wr_set)
      local ev = {}
      local any = false
      for fd, _ in pairs(rd_set) do
        ev[fd] = ev[fd] or {}
        ev[fd].rd = true
        any = true
      end
      for fd, _ in pairs(wr_set) do
        ev[fd] = ev[fd] or {}
        ev[fd].wr = true
        any = true
      end
      return any and ev or nil
    end,
    close_backend = function(_backend) end,
  }

  return poller_mod.new(ops)
end

local FakeIO = {}
FakeIO.__index = FakeIO

function FakeIO.new(opts)
  opts = opts or {}
  return setmetatable({
    _fd = opts.fd or 100,
    readq = opts.readq or {},
    writeq = opts.writeq or {},
    closed = false,
  }, FakeIO)
end

function FakeIO:fileno() return self._fd end

-- Returns: data, err, want_dir
function FakeIO:read_string(_want)
  local r = table.remove(self.readq, 1)
  if not r then
    return nil, nil, 'rd' -- default would-block
  end
  return r.data, r.err, r.want_dir
end

-- Returns: n, err, want_dir
function FakeIO:write_string(_chunk)
  local r = table.remove(self.writeq, 1)
  if not r then
    return 0, nil, 'wr'
  end
  return r.n, r.err, r.want_dir
end

function FakeIO:close() self.closed = true end

do
  local sched = sched_mod.new()
  local poller = make_always_ready_poller()
  runtime.init(sched, { now = now_fn, block = block_fn, poller = poller })

  local io = FakeIO.new({
    fd = 101,
    readq = {
      { data = 'ab', err = nil },
      { data = nil, err = nil, want_dir = 'rd' }, -- would-block
      { data = 'cd', err = nil },
    }
  })

  local s = stream_mod.open(io, true, true)

  local got, err = nil, nil

  runtime.spawn(function()
    got, err = s:read_exactly(4)
    assert(got == 'abcd' and err == nil)
    assert(s._rd_owner == nil, 'read lane should be released')
  end, 'stream_read')

  runtime.main()

  assert(got == 'abcd' and err == nil)
  assert(poller.watchers == 0, 'no lingering watchers after read completion')
end

do
  local sched = sched_mod.new()
  local poller = make_always_ready_poller()
  runtime.init(sched, { now = now_fn, block = block_fn, poller = poller })

  local io = FakeIO.new({
    fd = 102,
    writeq = {
      { n = 2, err = nil },                    -- wrote 2
      { n = nil, err = nil, want_dir = 'wr' }, -- would-block
      { n = 3, err = nil },                    -- wrote 3
    }
  })

  local s = stream_mod.open(io, true, true)

  local written, werr = nil, nil

  runtime.spawn(function()
    written, werr = s:write('abcde')
    assert(written == 5 and werr == nil)
    assert(s._wr_owner == nil, 'write lane should be released')
  end, 'stream_write')

  runtime.main()

  assert(written == 5 and werr == nil)
  assert(poller.watchers == 0, 'no lingering watchers after write completion')
end

do
  -- Lane serialisation: second reader waits until first finishes.
  local sched = sched_mod.new()
  local poller = make_always_ready_poller()
  runtime.init(sched, { now = now_fn, block = block_fn, poller = poller })

  local io = FakeIO.new({
    fd = 103,
    readq = {
      { data = nil, err = nil, want_dir = 'rd' }, -- first reader blocks
      { data = 'x', err = nil },                 -- first completes
      { data = 'y', err = nil },                 -- second completes
    }
  })

  local s = stream_mod.open(io, true, true)
  local r1, r2 = nil, nil

  runtime.spawn(function()
    r1 = s:read_some(1)
    assert(r1 == 'x')
  end, 'r1')

  runtime.spawn(function()
    r2 = s:read_some(1)
    assert(r2 == 'y')
  end, 'r2')

  runtime.main()

  assert(r1 == 'x' and r2 == 'y')
end

print('test_io-stream.lua: ok')
