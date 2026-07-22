-- Shared parent-side process semantics.
--
-- Families retain spawn, child setup and reaping mechanics.  This module owns
-- process identity, signal names, runtime binding, waiting, signalling and
-- idempotent closure.

local HostError = require('fibers.host.error')
local IOAudit = require('fibers.internal.io_audit')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')

local M = {}

local DEFAULT_SIGNALS = {
  hup = 1,
  int = 2,
  quit = 3,
  kill = 9,
  usr1 = 10,
  usr2 = 12,
  pipe = 13,
  alrm = 14,
  term = 15,
  chld = 17,
  cont = 18,
  stop = 19,
}
local DISPLAY = { hup = 'HUP', int = 'INT', quit = 'QUIT', kill = 'KILL', term = 'TERM' }

function M.signals(overrides)
  local numbers, names = {}, {}
  for key, fallback in pairs(DEFAULT_SIGNALS) do
    local number = overrides and overrides[key] or fallback
    numbers[key] = number
    if DISPLAY[key] then
      names[number] = DISPLAY[key]
    end
  end
  return {
    numbers = numbers,
    name = function(number)
      return names[number]
    end,
    normalise = function(value)
      if type(value) == 'number' and value > 0 and value == math.floor(value) then
        return value
      end
      if type(value) == 'string' then
        local number = numbers[value:lower():gsub('^sig', '')]
        if number then
          return number
        end
      end
      return nil, HostError.invalid_argument('process', 'signal', { signal = value })
    end,
  }
end

function M.exited(code)
  code = tonumber(code) or 0
  return { kind = 'exited', code = code, success = code == 0 }
end

function M.signalled(signals, number, core_dumped)
  number = tonumber(number) or 0
  return {
    kind = 'signalled',
    signal = number,
    signal_name = signals.name(number),
    core_dumped = core_dumped == true,
    success = false,
  }
end

function M.class(spec)
  local Process = {}
  Process.__index = Process

  function Process:bind_runtime(rt)
    self.runtime = rt
    IOAudit.bind(self, rt)
    if spec.bind then
      spec.bind(self, rt)
    end
    return self
  end

  function Process:pid()
    return self._pid
  end

  function Process:wait_op()
    if spec.wait then
      return spec.wait(self)
    end
    if self.status then
      return Op.always(true)
    end
    return Sleep.sleep_op(self.poll_interval)
  end

  Process.reap = assert(spec.reap, 'process class requires reap')

  function Process:signal(value, target)
    if self.reaped then
      return nil, HostError.closed('process', 'signal', { pid = self._pid })
    end
    local number, err = spec.signals.normalise(value)
    if not number then
      return nil, err
    end
    return spec.signal(self, number, target)
  end

  function Process:close(reason)
    if self.closed then
      IOAudit.closing(self, reason)
      IOAudit.closed(self, true, nil, reason)
      return true
    end
    self.closed = true
    IOAudit.closing(self, reason)
    local ok, err = true, nil
    if spec.close then
      ok, err = spec.close(self, reason)
    end
    IOAudit.closed(self, ok ~= nil and ok ~= false, err, reason)
    return ok, err
  end

  return Process
end

return M
