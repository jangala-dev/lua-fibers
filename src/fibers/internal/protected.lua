-- fibers.internal.protected
--
-- Yieldable protected calls for fibre code.
--
-- Lua 5.1 cannot generally yield through the native pcall/xpcall boundary.
-- This module provides coroutine-backed pcall/xpcall when needed, while using
-- native protected calls on hosts where they are already yield-safe.
--
-- The transaction kernel should not use this as a general hot-path wrapper.
-- It is for ordinary fibre/user-code boundaries where performing an Op may
-- suspend and later resume.

local M = {}

local native_pcall = pcall
local native_xpcall = xpcall
local unpack_ = table.unpack or unpack

local function pack(...)
  return { n = select('#', ...), ... }
end

local function running_raw()
  local co, is_main = coroutine.running()
  if is_main then
    return nil
  end
  return co
end

local function force_fallback()
  if rawget(_G, '__FIBERS_PROTECTED_FORCE_FALLBACK') then
    return true
  end
  if os and os.getenv then
    local v = os.getenv('FIBERS_PROTECTED_FORCE_FALLBACK')
    return v == '1' or v == 'true' or v == 'yes'
  end
  return false
end

local function probe_yieldable_pcall()
  local co = coroutine.create(function()
    return native_pcall(function()
      coroutine.yield('fibers.internal.protected.probe')
      return 'ok'
    end)
  end)

  local ok, yielded = coroutine.resume(co)
  if not ok or yielded ~= 'fibers.internal.protected.probe' or coroutine.status(co) ~= 'suspended' then
    return false
  end

  local ok2, protected_ok, value = coroutine.resume(co)
  return ok2 and protected_ok == true and value == 'ok' and coroutine.status(co) == 'dead'
end

local function probe_yieldable_xpcall()
  local protected_probe = 'fibers.internal.protected.probe.protected'
  local co = coroutine.create(function()
    return native_xpcall(function()
      coroutine.yield(protected_probe)
      return 'ok'
    end, function(err)
      return err
    end)
  end)

  local ok, yielded = coroutine.resume(co)
  if not ok or yielded ~= protected_probe or coroutine.status(co) ~= 'suspended' then
    return false
  end

  local ok2, protected_ok, value = coroutine.resume(co)
  if not (ok2 and protected_ok == true and value == 'ok' and coroutine.status(co) == 'dead') then
    return false
  end

  -- Some Lua 5.1-derived runtimes allow the protected function to yield but
  -- still prohibit yielding from the error handler.  Fibers handlers may
  -- perform operations, so select the native path only when both boundaries
  -- are yieldable.
  local handler_probe = 'fibers.internal.protected.probe.handler'
  local handler_co = coroutine.create(function()
    return native_xpcall(function()
      error('probe error', 0)
    end, function()
      coroutine.yield(handler_probe)
      return 'handled'
    end)
  end)

  local handler_ok, handler_yielded = coroutine.resume(handler_co)
  if not handler_ok or handler_yielded ~= handler_probe or coroutine.status(handler_co) ~= 'suspended' then
    return false
  end

  local handler_ok2, handler_protected_ok, handled = coroutine.resume(handler_co)
  return handler_ok2
    and handler_protected_ok == false
    and handled == 'handled'
    and coroutine.status(handler_co) == 'dead'
end

local USE_NATIVE = (not force_fallback()) and probe_yieldable_pcall() and probe_yieldable_xpcall()

-- Child protected-call coroutine -> caller coroutine.  Runtime uses
-- protected.running() so a fibre can still be recognised while user code is
-- executing inside a protected-call child coroutine.
local parent_of = setmetatable({}, { __mode = 'k' })

local function make_coroutine(fn)
  local ok, co = native_pcall(coroutine.create, fn)
  if ok then
    return co
  end

  -- Lua's pcall accepts callable tables.  coroutine.create is stricter on some
  -- hosts, so wrap non-function callables.
  return coroutine.create(function(...)
    return fn(...)
  end)
end

local function resume_until_done(co, ...)
  local args = pack(...)

  while true do
    local r = pack(coroutine.resume(co, unpack_(args, 1, args.n)))

    if not r[1] then
      return false, r[2]
    end

    if coroutine.status(co) == 'suspended' then
      args = pack(coroutine.yield(unpack_(r, 2, r.n)))
    else
      return true, unpack_(r, 2, r.n)
    end
  end
end

function M.running(co)
  co = co or running_raw()
  while co and parent_of[co] do
    co = parent_of[co]
  end
  return co
end

local function fallback_pcall(fn, ...)
  local caller = running_raw()
  if not caller then
    return native_pcall(fn, ...)
  end

  local co = make_coroutine(fn)
  parent_of[co] = caller
  local r = pack(resume_until_done(co, ...))
  parent_of[co] = nil

  if r[1] then
    return true, unpack_(r, 2, r.n)
  end
  return false, r[2]
end

local function run_handler(handler, err, caller)
  local hco = make_coroutine(function()
    return handler(err)
  end)
  if caller then
    parent_of[hco] = caller
  end
  local r = pack(resume_until_done(hco))
  parent_of[hco] = nil
  if r[1] then
    return false, r[2]
  end
  return false, 'error in error handling'
end

local function fallback_xpcall(fn, handler, ...)
  if type(handler) ~= 'function' then
    error('bad argument #2 to xpcall (function expected, got ' .. type(handler) .. ')', 2)
  end

  local caller = running_raw()
  if not caller then
    -- No coroutine means there is nowhere legal to propagate a yield.  Wrap fn
    -- so this API still accepts arguments uniformly on Lua 5.1.
    local args = pack(...)
    return native_xpcall(function()
      return fn(unpack_(args, 1, args.n))
    end, handler)
  end

  local co = make_coroutine(fn)
  parent_of[co] = caller
  local r = pack(resume_until_done(co, ...))
  parent_of[co] = nil

  if r[1] then
    return true, unpack_(r, 2, r.n)
  end
  return run_handler(handler, r[2], caller)
end

if USE_NATIVE then
  -- Use wrappers rather than returning native functions directly so xpcall gets
  -- uniform vararg support even on Lua 5.1-like hosts that omit it.
  function M.pcall(fn, ...)
    return native_pcall(fn, ...)
  end

  function M.xpcall(fn, handler, ...)
    local args = pack(...)
    return native_xpcall(function()
      return fn(unpack_(args, 1, args.n))
    end, handler)
  end
else
  M.pcall = fallback_pcall
  M.xpcall = fallback_xpcall
end

function M.using_native()
  return USE_NATIVE
end

return M
