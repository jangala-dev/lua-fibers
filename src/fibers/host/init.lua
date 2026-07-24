-- Host adapter helpers.
--
-- A host adapter is the boundary between the embeddable Runtime and a process
-- that wants to drive it as a standalone application.  The Runtime reports typed
-- waits; the host decides how, or whether, the process should block until one of
-- those waits may have changed.

local Host = {}

function Host.supports(host, capability)
  return type(host) == 'table'
    and type(host.capabilities) == 'table'
    and host.capabilities[capability] == true
end

local WaitSet = require('fibers.host.wait_set')

Host.earliest_deadline = function(waits)
  return WaitSet.build(waits).deadline
end
Host.has_non_time_waits = function(waits)
  return WaitSet.build(waits).has_non_time
end
Host.delay_until = WaitSet.delay_until
Host.timeout_ms = WaitSet.timeout_ms
Host.readiness_waits = WaitSet.readiness_waits
Host.poller_waits = WaitSet.poller_waits
Host.normalise_readiness_mode = WaitSet.normalise_mode

function Host.block(host, rt, waits, status, opts)
  if host and type(host.block) == 'function' then
    return host:block(rt, waits or {}, status, opts or {})
  end
  return nil, 'host-does-not-block'
end

local FAMILY_MODULES = {
  pure = 'fibers.host.pure',
  manual = 'fibers.host.manual',
  roblox = 'fibers.host.roblox',
  luajit_linux = 'fibers.host.luajit_linux',
  cffi_linux = 'fibers.host.cffi_linux',
  luaposix = 'fibers.host.luaposix',
  nixio = 'fibers.host.nixio',
}
-- Roblox is an embedded, non-blocking host and is selected explicitly through
-- fibers.roblox.prepare/attach rather than by the standalone Host.default path.
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
Host.Reactor = require('fibers.host.reactor')

return Host
