-- Linux host adapter using neopallium's nixio.
--
-- This adapter is optional.  It uses nixio.gettime/nanosleep for time and
-- nixio.poll for readiness waits.  Requiring the module without nixio succeeds;
-- is_supported() returns false and new() raises a clear error.

local Host = require('fibers.host')

local ok_nixio, nixio = pcall(require, 'nixio')
if not ok_nixio or type(nixio) ~= 'table' then
  return {
    is_supported = function() return false end,
    new = function() error('fibers.host.nixio requires nixio', 2) end,
  }
end

local Nixio = {}
Nixio.__index = Nixio

local function read_uptime()
  local f = io.open('/proc/uptime', 'r')
  if not f then return nil end
  local line = f:read('*l')
  f:close()
  local first = line and line:match('^%s*(%S+)')
  return first and tonumber(first) or nil
end

local function monotonic()
  return read_uptime() or nixio.gettime()
end

local function nanosleep(seconds)
  seconds = tonumber(seconds) or 0
  if seconds <= 0 then return true end
  local deadline = monotonic() + seconds
  while true do
    local remaining = deadline - monotonic()
    if remaining <= 0 then return true end
    local sec = math.floor(remaining)
    local nsec = math.floor((remaining - sec) * 1e9 + 0.5)
    if nsec >= 1000000000 then sec = sec + 1; nsec = nsec - 1000000000 end
    local ok, err, eno = nixio.nanosleep(sec, nsec)
    if not ok then
      local msg = tostring(err or eno or '')
      -- nixio reports EINTR differently across versions; recomputing the
      -- remaining time is safe for interruptions and soft failures.
      if msg ~= '' and msg ~= 'EINTR' and msg ~= 'interrupted system call' then
        return nil, 'nixio.nanosleep failed: ' .. msg
      end
    end
  end
end

local function poll_flags(...)
  return nixio.poll_flags(...)
end

local function add_event(events, mode)
  if events == nil then return poll_flags(mode) end
  return poll_flags(events, mode)
end

local function collect_readiness(waits)
  local fds, by_key, unsupported = {}, {}, false
  local readiness = Host.readiness_waits(waits)
  for i = 1, #readiness do
    local w = readiness[i]
    local key = w.readiness_key
    if key == nil then
      unsupported = true
    else
      local poll_key = (type(key) == 'table' and (key.handle or key.nixio)) or key
      local rec = by_key[poll_key]
      if not rec then
        rec = { key = poll_key, events = nil, waits = {} }
        by_key[poll_key] = rec
        fds[#fds + 1] = rec
      end
      local mode = w.mode or 'read'
      if mode == 'write' or mode == 'wr' then rec.events = add_event(rec.events, 'out') else rec.events = add_event(rec.events, 'in') end
      rec.waits[#rec.waits + 1] = w
    end
  end
  return fds, by_key, unsupported
end

function Nixio.is_supported()
  return type(nixio.gettime) == 'function'
    and type(nixio.nanosleep) == 'function'
    and type(nixio.poll) == 'function'
    and type(nixio.poll_flags) == 'function'
end

function Nixio.new(opts)
  opts = opts or {}
  if not Nixio.is_supported() then error('fibers.host.nixio: required nixio functions are unavailable', 2) end
  local self = setmetatable({
    kind = 'nixio',
    name = 'nixio',
    family = 'nixio',
    on_wait = opts.on_wait,
    on_wake = opts.on_wake,
    on_unsupported = opts.on_unsupported,
  }, Nixio)
  self.now = function(_rt) return monotonic() end
  self.fd = require('fibers.host.fd_nixio')
  self.capabilities = { time = true, readiness = true, fd = self.fd.is_supported(), pipe = self.fd.is_supported() }
  return self
end

function Nixio:sleep(seconds)
  return nanosleep(seconds)
end

function Nixio:block(rt, waits, status, _opts)
  waits = waits or {}
  local deadline = Host.earliest_deadline(waits)
  local fd_recs, _by_key, unsupported = collect_readiness(waits)

  if unsupported then
    if self.on_unsupported then self.on_unsupported(waits, status) end
    return nil, 'unsupported-readiness-key'
  end

  if #fd_recs == 0 then
    if deadline ~= nil then
      local delay = Host.delay_until(rt, deadline) or 0
      if delay > 0 then
        if self.on_wait then self.on_wait(deadline, delay, waits, status) end
        local ok, err = self:sleep(delay)
        if not ok then error(err, 2) end
        if self.on_wake then self.on_wake(deadline, waits, status) end
      end
      return true, 'time'
    end
    if self.on_unsupported then self.on_unsupported(waits, status) end
    return nil, 'unsupported-waits'
  end

  local poll_fds = {}
  for i = 1, #fd_recs do
    local rec = fd_recs[i]
    poll_fds[i] = { fd = rec.key, events = rec.events }
  end

  local timeout_ms = Host.timeout_ms(rt, deadline)
  local nready, ret = nixio.poll(poll_fds, timeout_ms)
  if not nready then
    -- Treat EINTR as a soft wake so that the runner can re-enter the runtime.
    return true, 'poll-interrupted'
  end

  local delivered = false
  if nready > 0 and type(ret) == 'table' then
    for _, info in pairs(ret) do
      local revents = info.revents or 0
      if revents ~= 0 then
        local flags = poll_flags(revents)
        local rd = not not (flags['in'] or flags.hup or flags.err or flags.nval)
        local wr = not not (flags.out or flags.err or flags.nval)
        local rec = _by_key[info.fd]
        if rec then
          for i = 1, #rec.waits do
            local w = rec.waits[i]
            local mode = w.mode or 'read'
            if (mode == 'write' or mode == 'wr') and wr then
              rt:deliver(w.feed, 'write', true); delivered = true
            elseif mode ~= 'write' and mode ~= 'wr' and rd then
              rt:deliver(w.feed, 'read', true); delivered = true
            end
          end
        end
      end
    end
  end

  if delivered then return true, 'readiness' end
  if deadline ~= nil and rt:now() >= deadline then return true, 'time' end
  return true, 'poll'
end

function Nixio:close()
  -- nixio.poll is stateless; no persistent host descriptor to close.
end

return Nixio
