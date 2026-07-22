-- Host adapter helpers.
--
-- A host adapter is the boundary between the embeddable Runtime and a process
-- that wants to drive it as a standalone application.  The Runtime reports typed
-- waits; the host decides how, or whether, the process should block until one of
-- those waits may have changed.

local Host = {}

local function is_finite_number(x)
  return type(x) == 'number' and x == x and x ~= math.huge and x ~= -math.huge
end

function Host.supports(host, capability)
  return type(host) == 'table'
    and type(host.capabilities) == 'table'
    and host.capabilities[capability] == true
end

function Host.earliest_deadline(waits)
  local best
  for i = 1, #(waits or {}) do
    local w = waits[i]
    local d = w and w.deadline
    if w and w.kind == 'timer' and is_finite_number(d) and (best == nil or d < best) then
      best = d
    end
  end
  return best
end

function Host.has_non_time_waits(waits)
  for i = 1, #(waits or {}) do
    local w = waits[i]
    if w and w.kind ~= 'timer' then
      return true
    end
  end
  return false
end

local function external_waits(waits, kind, owner)
  local out = {}
  for i = 1, #(waits or {}) do
    local wait = waits[i]
    if wait and wait.kind == 'external' and wait.external_kind == kind and wait[owner] and wait.feed then
      out[#out + 1] = wait
    end
  end
  return out
end

function Host.readiness_waits(waits)
  return external_waits(waits, 'readiness', 'resource')
end
function Host.poller_waits(waits)
  return external_waits(waits, 'poller', 'poller')
end

function Host.deliver_poller_ready(rt, wait, registration)
  if not wait or not wait.feed or not registration then
    return false
  end
  rt:deliver(wait.feed, registration.id, registration.generation, registration.mode, registration.key)
  return true
end

function Host.normalise_readiness_mode(mode)
  mode = mode or 'read'
  if mode == 'wr' then
    mode = 'write'
  end
  if mode ~= 'read' and mode ~= 'write' then
    error('readiness mode must be read or write', 2)
  end
  return mode
end

function Host.delay_until(rt, deadline)
  if deadline == nil then
    return nil
  end
  local delay = deadline - rt:now()
  if delay < 0 then
    delay = 0
  end
  return delay
end

function Host.timeout_ms(rt, deadline)
  if deadline == nil then
    return -1
  end
  local delay = Host.delay_until(rt, deadline) or 0
  local ms = math.ceil(delay * 1000)
  if ms < 0 then
    ms = 0
  end
  return ms
end

function Host.block(host, rt, waits, status, opts)
  if host and type(host.block) == 'function' then
    return host:block(rt, waits or {}, status, opts or {})
  end
  return nil, 'host-does-not-block'
end

local FAMILY_MODULES = {
  pure = 'fibers.host.pure',
  manual = 'fibers.host.manual',
  luajit_linux = 'fibers.host.luajit_linux',
  cffi_linux = 'fibers.host.cffi_linux',
  luaposix = 'fibers.host.luaposix',
  nixio = 'fibers.host.nixio',
}
local DEFAULT_ORDER = { 'luajit_linux', 'cffi_linux', 'luaposix', 'nixio', 'pure' }

for name, module_name in pairs(FAMILY_MODULES) do
  local selected_name, selected_module = name, module_name
  Host[selected_name] = function(opts)
    return require(selected_module).new(opts)
  end
end

local function family(name)
  local module = FAMILY_MODULES[name]
  if not module then
    error('unknown host family ' .. tostring(name), 3)
  end
  return require(module)
end

function Host.select(name, opts)
  return family(name).new(opts)
end

function Host.available()
  local out = {}
  for name, module_name in pairs(FAMILY_MODULES) do
    local ok, module = pcall(require, module_name)
    local supported, reason = false, ok and nil or module
    if ok and module then
      if type(module.is_supported) == 'function' then
        supported, reason = module.is_supported()
      else
        supported = true
      end
    end
    out[#out + 1] = { name = name, module = module_name, supported = not not supported, reason = reason }
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

function Host.default(opts)
  for i = 1, #DEFAULT_ORDER do
    local ok, module = pcall(family, DEFAULT_ORDER[i])
    if ok and module and (type(module.is_supported) ~= 'function' or module.is_supported()) then
      return module.new(opts)
    end
  end
  return require('fibers.host.pure').new(opts)
end

Host.Error = require('fibers.host.error')
Host.Handle = require('fibers.host.handle')
Host.Poller = require('fibers.host.poller')
Host.Reactor = require('fibers.host.reactor')

return Host
