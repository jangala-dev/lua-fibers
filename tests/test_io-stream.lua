-- tests/test_stream_mem.lua
--
-- Synthetic tests for fibers.io.stream using an in-memory backend.
print('testing: fibers.io.stream')

-- look one level up
package.path = "../src/?.lua;" .. package.path

local fibers  = require 'fibers'
local stream  = require 'fibers.io.stream'
local wait    = require 'fibers.wait'
local runtime = require 'fibers.runtime'
local sleep   = require 'fibers.sleep'

-- In-memory duplex backend with partial I/O and readiness notifications.
local function make_stream_pair()
  local shared = {
    buf     = "",
    closed  = false,
    waitset = wait.new_waitset(),  -- key "rd" for readability
  }

  local rd_io = { shared = shared }
  local wr_io = { shared = shared }

  -- Backend read: string-or-nil as per StreamBackend contract.
  function rd_io:read_string(max)
    if #self.shared.buf == 0 then
      if self.shared.closed then
        return "", nil    -- EOF
      end
      return nil, nil     -- would block
    end
    max = max or 1
    -- Deliberately read at most 1 byte to exercise partial reads.
    local n = math.min(1, max, #self.shared.buf)
    local s = self.shared.buf:sub(1, n)
    self.shared.buf = self.shared.buf:sub(n + 1)
    return s, nil
  end

  -- Backend write: always writes 1 byte to exercise partial writes.
  function wr_io:write_string(str)
    if self.shared.closed then
      return nil, "closed"
    end
    if #str == 0 then
      return 0, nil
    end
    local n   = 1
    local ch  = str:sub(1, n)
    shared.buf = shared.buf .. ch
    -- Notify any waiting readers.
    shared.waitset:notify_all("rd", runtime.current_scheduler)
    return n, nil
  end

  function rd_io:on_readable(task)
    return shared.waitset:add("rd", task)
  end

  function wr_io:on_writable(task)
    -- Always writable: just schedule immediately.
    runtime.current_scheduler:schedule(task)
    return { unlink = function() end }
  end

  function rd_io:close()
    shared.closed = true
  end

  function wr_io:close()
    shared.closed = true
  end

  -- Optional methods used by Stream; safe no-ops here.
  function rd_io:seek() return nil, "not seekable" end
  function wr_io:seek() return nil, "not seekable" end
  function rd_io:nonblock() end
  function rd_io:block() end
  function wr_io:nonblock() end
  function wr_io:block() end

  local rd = stream.open(rd_io, true, false)
  local wr = stream.open(wr_io, false, true)
  return rd, wr, shared
end

local function test()
  local rd, wr, shared = make_stream_pair()

  wr:setvbuf('line')
  assert(wr.line_buffering == true, "setvbuf('line') did not set line_buffering")

  local message = "hello, world\n"

  -- Writer runs in a fibre, so the first read will block and use on_readable.
  fibers.spawn(function()
    sleep.sleep(0.01)
    local n, err = wr:write(message)
    assert(err == nil, "write error: " .. tostring(err))
    assert(n == #message, "write wrote " .. tostring(n) .. " bytes, expected " .. #message)
    wr:close()
  end)

  -- Read full line including terminator (exercise waitable + partial I/O).
  local line, err = rd:read("*L")
  assert(err == nil, "read('*L') returned error: " .. tostring(err))
  assert(line == message,
         ("read('*L') returned %q, expected %q"):format(tostring(line), tostring(message)))

  rd:close()

  -- After close, no readers should remain registered.
  assert(shared.waitset:size("rd") == 0, "waitset still has readers after close")
end

local function main()
  test()
end

fibers.run(main)

print('selftest: ok')
