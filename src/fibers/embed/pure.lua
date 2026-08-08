-- Deliberately small pure-Lua host. It supports time waits only.

local WaitSet = require('fibers.embed.wait_set')
local Base = require('fibers.internal.host.base')
local Label = require('fibers.internal.label')
local Contract = require('fibers.internal.contract')

local next_pure = 0
local Pure = {}
Pure.__index = Pure
setmetatable(Pure, { __index = Base })

local function default_now()
  return os.time()
end

local function default_sleep(seconds)
  seconds = Contract.non_negative_number(seconds, 'PureHost sleep seconds', 3)
  if seconds == 0 then return true end
  local whole = math.ceil(seconds)
  if whole <= 0 then return true end
  local execute = os and os.execute
  if type(execute) ~= 'function' then
    return nil, 'pure host cannot sleep: os.execute is unavailable; supply opts.sleep'
  end
  return execute('sleep ' .. tostring(whole))
end

local PURE_OPTIONS = {
  now = Contract.func, sleep = Contract.func, label = Contract.non_empty_string,
}

function Pure.new(opts)
  opts = Contract.record(opts, PURE_OPTIONS, 'PureHost options', 2)
  local now, sleep = opts.now or default_now, opts.sleep or default_sleep
  next_pure = next_pure + 1
  local self = Label.attach(setmetatable({
    _fibers_id = 'pure-host-' .. tostring(next_pure),
    kind = 'pure', family = 'pure', _sleep = sleep,
  }, Pure), opts.label)
  Base.init(self, { time = true })
  self.now = function() return now() end
  return self
end

function Pure:sleep(seconds)
  return self._sleep(seconds)
end

function Pure:block(rt, waits)
  return WaitSet.block_without_io(self, rt, WaitSet.build(waits))
end

return Pure
