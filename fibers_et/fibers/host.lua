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

function Host.luajit_linux(opts)
  return require('fibers.host.luajit_linux').new(opts)
end

function Host.nixio_linux(opts)
  return require('fibers.host.nixio_linux').new(opts)
end

function Host.luaposix(opts)
  return require('fibers.host.luaposix').new(opts)
end

function Host.cffi_linux(opts)
  return require('fibers.host.cffi_linux').new(opts)
end

return Host
