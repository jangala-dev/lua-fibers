-- fibers/op.lua
-- Pure Op descriptors: try (non-blocking), install(ctx, susp) (non-blocking).
-- Lua 5.1/LuaJIT compatible.

local Op     = {}
Op.__index   = Op

local unpack = rawget(table, "unpack") or _G.unpack   -- Lua 5.1 fallback
local pack   = rawget(table, "pack") or function(...) -- Lua 5.1 fallback
    return { n = select("#", ...), ... }
end

-- op.new(wrap_fn|nil, try_fn, install_fn)
--  wrap_fn(...): winner-only mapper (optional; identity by default)
--  try_fn() -> (ready:boolean, ...values) -- non-blocking probe
--  install_fn(ctx, susp) -> nil           -- may call susp:complete(...); must not block
local function new(wrap_fn, try_fn, install_fn)
  return setmetatable({
    _wrap    = wrap_fn or function(...) return ... end,
    _try     = assert(try_fn, "op.new: try_fn required"),
    _install = assert(install_fn, "op.new: install_fn required"),
  }, Op)
end

-- Accessors used by scope
function Op:_wrap_call(...) return self._wrap(...) end

function Op:_try_call() return self._try() end

function Op:_install_call(ctx, susp) return self._install(ctx, susp) end

-- Combinators (small, shallow)

-- map: transform winner values at commit time
local function map(base, f)
  return new(function(...) return f(base:_wrap_call(...)) end,
    function() return base:_try_call() end,
    function(ctx, susp) return base:_install_call(ctx, susp) end)
end

-- always: ready immediately with given values
local function always(...)
  local values = pack(...)
  return new(nil,
    function() return true, unpack(values, 1, values.n) end,
    function() end)
end

-- never: never ready
local function never()
  return new(nil,
    function() return false end,
    function() end)
end

-- guard: lazily construct the inner Op at install time
local function guard(make)
  return new(nil,
    function() return false end,
    function(ctx, susp) make():_install_call(ctx, susp) end)
end

return {
  new    = new,
  map    = map,
  always = always,
  never  = never,
  guard  = guard
}
