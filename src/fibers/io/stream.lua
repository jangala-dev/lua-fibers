-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

---@module 'fibers.io.stream'

local wait    = require 'fibers.wait'
local bytes   = require 'fibers.utils.bytes'
local op      = require 'fibers.op'
local perform = require 'fibers.performer'.perform

local RingBuf   = bytes.RingBuf
local LinearBuf = bytes.LinearBuf

--- Backend interface expected by Stream.
---@class StreamBackend
---@field read_string fun(self: StreamBackend, max: integer): string|nil, string|nil
---@field write_string fun(self: StreamBackend, data: string): integer|nil, string|nil
---@field on_readable fun(self: StreamBackend, task: Task): WaitToken
---@field on_writable fun(self: StreamBackend, task: Task): WaitToken
---@field close fun(self: StreamBackend): boolean, string|nil
---@field seek fun(self: StreamBackend, whence: string, offset: integer): integer|nil, string|nil
---@field nonblock fun(self: StreamBackend)|nil
---@field block fun(self: StreamBackend)|nil
---@field filename string|nil
---@field fileno fun(self: StreamBackend): integer|nil  -- optional, used by file.tmpfile

--- Buffered IO stream over a StreamBackend.
---@class Stream
---@field io StreamBackend|nil
---@field rx RingBuf|nil
---@field tx RingBuf|nil
---@field line_buffering boolean   # flag only; behaviour is caller-defined
---@field flush_output fun(self: Stream)|nil
---@field flush fun(self: Stream)|nil
---@field rename fun(self: Stream, newname: string): boolean|nil, string|nil
local Stream = {}
Stream.__index = Stream

local DEFAULT_BUFFER_SIZE = 2^12

--- Open a new Stream over a backend.
---@param io_backend StreamBackend
---@param readable? boolean  # default true
---@param writable? boolean  # default true
---@param bufsize? integer   # per-direction buffer size
---@return Stream
local function open(io_backend, readable, writable, bufsize)
  local s = setmetatable({
    io             = io_backend,
    line_buffering = false,
  }, Stream)

  if readable ~= false then
    s.rx = RingBuf.new(bufsize or DEFAULT_BUFFER_SIZE)
  end
  if writable ~= false then
    s.tx = RingBuf.new(bufsize or DEFAULT_BUFFER_SIZE)
  end

  return s
end

--- Check whether a value is a Stream instance.
---@param x any
---@return boolean
local function is_stream(x)
  return type(x) == 'table' and getmetatable(x) == Stream
end

function Stream:nonblock()
  if self.io and self.io.nonblock then
    self.io:nonblock()
  end
end

function Stream:block()
  if self.io and self.io.block then
    self.io:block()
  end
end

----------------------------------------------------------------------
-- Internal step machines
----------------------------------------------------------------------

---@param stream Stream
---@param buf LinearBuf
---@param min integer
---@param max integer
---@param terminator string|nil
---@return fun(): boolean, ...  # step()
local function make_read_step(stream, buf, min, max, terminator)
  local tally = 0

  local function adjust_for_terminator()
    if not terminator then return end
    local loc = stream.rx:find(terminator)
    if loc then
      local final = tally + loc + #terminator
      min, max = final, final
    end
  end

  return function()
    while true do
      adjust_for_terminator()

      local avail = stream.rx:read_avail()
      if avail > 0 and tally < max then
        local need  = math.min(avail, max - tally)
        local chunk = stream.rx:take(need)
        if #chunk > 0 then
          buf:append(chunk)
          tally = tally + #chunk
          if tally >= min then
            return true, buf, tally
          end
        end
      end

      if not (stream.io and stream.io.read_string) then
        return true, buf, tally, "backend does not support read_string"
      end

      local room = stream.rx:write_avail()
      if room <= 0 then
        if tally >= min then
          return true, buf, tally
        end
        return true, buf, tally, "buffer capacity exhausted"
      end

      local data, err = stream.io:read_string(room)
      if err then
        return true, buf, tally, err
      end
      if not data then
        if tally >= min then
          return true, buf, tally
        end
        return false
      end
      if #data == 0 then
        return true, buf, tally
      end

      stream.rx:put(data)
    end
  end
end

---@param stream Stream
---@param src_str string
---@return fun(): boolean, ...  # step()
local function make_write_step(stream, src_str)
  local offset = 0
  local len    = #src_str

  return function()
    if offset == len then
      return true, len
    end

    if not (stream.io and stream.io.write_string) then
      return true, offset, "backend does not support write_string"
    end

    local chunk = src_str:sub(offset + 1)
    local n, err = stream.io:write_string(chunk)
    if err then
      return true, offset, err
    end
    if n == nil then
      return false
    end
    if n == 0 then
      return true, offset
    end

    offset = offset + n
    if offset >= len then
      return true, offset
    end
    return false
  end
end

----------------------------------------------------------------------
-- Core stream primitives
----------------------------------------------------------------------

---@param buf LinearBuf
---@param opts? { min?: integer, max?: integer, terminator?: string, eof_ok?: boolean }
---@return Op
function Stream:read_into_op(buf, opts)
  assert(self.rx, "stream is not readable")

  opts = opts or {}
  local min        = opts.min or 1
  local max        = opts.max or min
  local terminator = opts.terminator
  local eof_ok     = not not opts.eof_ok

  local step = make_read_step(self, buf, min, max, terminator)

  local function wrap(ret_buf, cnt, err)
    if cnt == 0 and not eof_ok then
      return nil, cnt, err
    end
    return ret_buf, cnt, err
  end

  return wait.waitable(
    function(task)
      return self.io:on_readable(task)
    end,
    step,
    wrap
  )
end

---@param opts? { min?: integer, max?: integer, terminator?: string, eof_ok?: boolean }
---@return Op
function Stream:read_string_op(opts)
  local buf = LinearBuf.new()
  local ev  = self:read_into_op(buf, opts)

  return ev:wrap(function(ret_buf, cnt, err)
    if not ret_buf then
      return nil, cnt, err
    end
    local s = ret_buf:tostring()
    if cnt == 0 and s == "" then
      return nil, 0, err
    end
    return s, cnt, err
  end)
end

---@param str string
---@return Op
function Stream:write_string_op(str)
  assert(self.tx, "stream is not writable")
  assert(type(str) == "string", "write_string_op expects a string")

  local step = make_write_step(self, str)

  local function wrap(bytes_written, err)
    return bytes_written, err
  end

  return wait.waitable(
    function(task)
      return self.io:on_writable(task)
    end,
    step,
    wrap
  )
end

---@return Op
function Stream:flush_output_op()
  -- Unbuffered write path: there is nothing to flush at the Stream level.
  -- Writes only return once the backend has accepted the data (or errored).
  return op.always(0, nil)
end

----------------------------------------------------------------------
-- Derived per-stream ops
----------------------------------------------------------------------

---@param opts? { terminator?: string, keep_terminator?: boolean, max?: integer }
---@return Op  -- when performed: line:string|nil, err:string|nil
function Stream:read_line_op(opts)
  assert(self.rx, "stream is not readable")

  opts = opts or {}
  local term      = opts.terminator or "\n"
  local keep_term = not not opts.keep_terminator
  local max_bytes = opts.max or math.huge

  local ev = self:read_string_op{
    min        = max_bytes,
    max        = max_bytes,
    terminator = term,
    eof_ok     = true,
  }

  return ev:wrap(function(s, cnt, err)
    if err then return nil, err end

    if not s or cnt == 0 then return nil, nil end

    if not keep_term and #term > 0 and s:sub(-#term) == term then
      s = s:sub(1, -#term - 1)
    end

    return s, nil
  end)
end

---@param n integer
---@return Op  -- when performed: data:string|nil, err:string|nil
function Stream:read_exactly_op(n)
  assert(type(n) == "number" and n >= 0, "read_exactly_op: n must be non-negative")

  return self:read_string_op{
    min    = n,
    max    = n,
    eof_ok = false,
  }:wrap(function(s, cnt, err)
    if err then return nil, err end

    if not s or cnt ~= n then return nil, "short read" end

    return s, nil
  end)
end

---@return Op  -- when performed: data:string, err:string|nil
function Stream:read_all_op()
  assert(self.rx, "stream is not readable")

  -- Read until EOF or error in a single op.
  local ev = self:read_string_op{
    min    = math.huge,
    max    = math.huge,
    eof_ok = true,
  }

  return ev:wrap(function(s, _, err)
    -- read_string_op returns:
    --   s == nil, cnt == 0   : no data at all (EOF or error-before-data)
    --   s ~= nil, cnt > 0    : some data read, possibly with err
    if not s then return "", err end -- Normalise “no data” to empty string.

    return s, err
  end)
end

----------------------------------------------------------------------
-- Misc and lifecycle
----------------------------------------------------------------------

function Stream:flush_input()
  if self.rx then
    self.rx:reset()
  end
end

---@return boolean ok, string|nil err
function Stream:close()
  local ok, err
  if self.io and self.io.close then
    ok, err = self.io:close()
  else
    ok, err = true, nil
  end
  self.rx, self.tx, self.io = nil, nil, nil
  return ok, err
end

---@param whence? string
---@param offset? integer
---@return integer|nil pos, string|nil err
function Stream:seek(whence, offset)
  if not (self.io and self.io.seek) then
    return nil, 'stream is not seekable'
  end
  whence = whence or "cur"
  offset = offset or 0
  return self.io:seek(whence, offset)
end

---@param mode '"no"'|'"line"'|'"full"'
---@param _ any
---@return Stream
function Stream:setvbuf(mode, _)
  if mode == 'no' then
    self.line_buffering = false
  elseif mode == 'line' then
    self.line_buffering = true
  elseif mode == 'full' then
    self.line_buffering = false
  else
    error('bad mode: ' .. tostring(mode))
  end
  return self
end

---@return string|nil
function Stream:filename()
  return self.io and self.io.filename
end

----------------------------------------------------------------------
-- Synchronous convenience wrappers
----------------------------------------------------------------------

function Stream:read_string(opts)
  return perform(self:read_string_op(opts))
end

function Stream:read_all()
  return perform(self:read_all_op())
end

function Stream:read_exactly(n)
  return perform(self:read_exactly_op(n))
end

function Stream:write_string(str)
  return perform(self:write_string_op(str))
end

function Stream:flush_output()
  return perform(self:flush_output_op())
end

function Stream:flush()
  return self:flush_output()
end

----------------------------------------------------------------------
-- Lua compatibility surface
----------------------------------------------------------------------

---@param fmt? string|integer
---@return Op  -- when performed: value|nil, err|string|nil
function Stream:read_op(fmt)
  assert(self.rx, "stream is not readable")

  local t = type(fmt)

  -- Default / "*l": line without terminator
  if fmt == nil or fmt == "*l" then return self:read_line_op() end

  -- "*L": line with terminator
  if fmt == "*L" then return self:read_line_op{ keep_terminator = true } end

  -- "*a": read all
  if fmt == "*a" then return self:read_all_op() end

  -- numeric: read up to n bytes
  if t == "number" then
    local n = fmt
    assert(n >= 0, "read_op: n must be non-negative")

    -- Lua: f:read(0) returns "" immediately
    if n == 0 then return op.always("", nil) end

    -- read up to n bytes; allow EOF
    local ev = self:read_string_op{ min = 1, max = n, eof_ok = true }

    return ev:wrap(function(s, cnt, err)
      if err then return nil, err end
      if not s or cnt == 0 then return nil, nil end -- EOF before any data
      return s, nil
    end)
  else
    error("read_op: invalid format " .. tostring(fmt))
  end
end

function Stream:read(fmt)
  return perform(self:read_op(fmt))
end

---@param ... any
---@return Op  -- when performed: bytes_written:integer, err:string|nil
function Stream:write_op(...)
  assert(self.tx, "stream is not writable")

  local n = select("#", ...)
  if n == 0 then
    -- Match the “no-op but succeed” flavour.
    return op.always(0, nil)
  end

  local parts = {}
  for i = 1, n do
    local v = select(i, ...)
    -- Follow Lua’s io.write behaviour: tostring each argument.
    parts[i] = (type(v) == "string") and v or tostring(v)
  end

  local s = table.concat(parts)
  return self:write_string_op(s)
end

function Stream:write(...)
  return perform(self:write_op(...))
end

----------------------------------------------------------------------
-- Module-level helpers
----------------------------------------------------------------------

--- Race a single line read across multiple named streams.
---
--- When performed, returns:
---   name : string
---   line : string|nil
---   err  : string|nil
---@param named_streams table<string, Stream>
---@param opts? { terminator?: string, keep_terminator?: boolean, max?: integer }
---@return Op
local function merge_lines_op(named_streams, opts)
  local arms = {}
  for name, s in pairs(named_streams) do
    arms[name] = s:read_line_op(opts)
  end
  return op.named_choice(arms)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
  open           = open,
  is_stream      = is_stream,
  merge_lines_op = merge_lines_op,
}
