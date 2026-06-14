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

function Host.earliest_deadline(waits)
  local best
  for i = 1, #(waits or {}) do
    local w = waits[i]
    local d = w and w.deadline
    if w and w.kind == 'time' and is_finite_number(d) and (best == nil or d < best) then
      best = d
    end
  end
  return best
end

function Host.has_non_time_waits(waits)
  for i = 1, #(waits or {}) do
    local w = waits[i]
    if w and w.kind ~= 'time' then return true end
  end
  return false
end


function Host.readiness_waits(waits)
  local out = {}
  for i = 1, #(waits or {}) do
    local w = waits[i]
    if w and w.kind == 'source' and w.source_kind == 'readiness' and w.source then
      out[#out + 1] = w
    end
  end
  return out
end

function Host.has_readiness_waits(waits)
  return #Host.readiness_waits(waits) > 0
end


function Host.normalise_readiness_mode(mode)
  mode = mode or 'read'
  if mode == 'wr' then mode = 'write' end
  if mode ~= 'read' and mode ~= 'write' then error('readiness mode must be read or write', 2) end
  return mode
end

function Host.deliver_readiness(rt, wait)
  if not (wait and wait.kind == 'source' and wait.source_kind == 'readiness' and wait.source) then return false end
  rt:arrive(wait.source, Host.normalise_readiness_mode(wait.mode), true)
  return true
end

function Host.deliver_ready(rt, waits, is_ready)
  local n = 0
  for i = 1, #(waits or {}) do
    local w = waits[i]
    if w and w.kind == 'source' and w.source_kind == 'readiness' and w.source then
      local mode = Host.normalise_readiness_mode(w.mode)
      local key = w.readiness_key
      if is_ready == nil or is_ready(key, mode, w) then
        rt:arrive(w.source, mode, true)
        n = n + 1
      end
    end
  end
  return n
end

function Host.delay_until(rt, deadline)
  if deadline == nil then return nil end
  local delay = deadline - rt:now()
  if delay < 0 then delay = 0 end
  return delay
end

function Host.timeout_ms(rt, deadline)
  if deadline == nil then return -1 end
  local delay = Host.delay_until(rt, deadline) or 0
  local ms = math.ceil(delay * 1000)
  if ms < 0 then ms = 0 end
  return ms
end

function Host.block(host, rt, waits, status, opts)
  if host and type(host.block) == 'function' then
    return host:block(rt, waits or {}, status, opts or {})
  end
  return nil, 'host-does-not-block'
end

function Host.pure(opts)
  return require('fibers.host.pure').new(opts)
end

function Host.manual(opts)
  return require('fibers.host.manual').new(opts)
end

function Host.luajit_linux(opts)
  return require('fibers.host.luajit_linux').new(opts)
end

function Host.nixio(opts)
  return require('fibers.host.nixio').new(opts)
end


function Host.luaposix(opts)
  return require('fibers.host.luaposix').new(opts)
end

function Host.cffi_linux(opts)
  return require('fibers.host.cffi_linux').new(opts)
end

local host_names = {
  pure = 'fibers.host.pure',
  manual = 'fibers.host.manual',
  luajit_linux = 'fibers.host.luajit_linux',
  cffi_linux = 'fibers.host.cffi_linux',
  luaposix = 'fibers.host.luaposix',
  nixio = 'fibers.host.nixio',
}

function Host.select(name, opts)
  local modname = host_names[name]
  if not modname then error('unknown host backend ' .. tostring(name), 2) end
  return require(modname).new(opts)
end

function Host.available()
  local out = {}
  for name, modname in pairs(host_names) do
    local ok, mod = pcall(require, modname)
    local supported, reason = false, 'not loadable'
    if ok and mod and type(mod.is_supported) == 'function' then
      supported, reason = mod.is_supported()
    elseif ok then
      supported = true
    else
      reason = mod
    end
    out[#out + 1] = { name = name, module = modname, supported = not not supported, reason = reason }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

function Host.default(opts)
  local order = { 'luajit_linux', 'cffi_linux', 'luaposix', 'nixio', 'pure' }
  for i = 1, #order do
    local name = order[i]
    local ok, mod = pcall(require, host_names[name])
    if ok and mod and type(mod.is_supported) == 'function' and mod.is_supported() then
      return mod.new(opts)
    elseif ok and name == 'pure' then
      return mod.new(opts)
    end
  end
  return require('fibers.host.pure').new(opts)
end

Host.Handle = require('fibers.host.handle')



return Host
