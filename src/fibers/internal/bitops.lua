-- Portable bit-operation resolver for optional native host backends.
--
-- Production files retain Lua 5.1 syntax.  On Lua 5.3 and later the native
-- bitwise implementation is compiled from a string so older parsers never see
-- the newer operators.

local M = {}

local cached_bit
local cached_source
local cached_error

local function usable(candidate)
  return type(candidate) == 'table'
    and type(candidate.band) == 'function'
    and type(candidate.bor) == 'function'
    and type(candidate.bnot) == 'function'
    and type(candidate.lshift) == 'function'
end

local function try_module(name)
  local ok, candidate = pcall(require, name)
  if ok and usable(candidate) then
    return candidate
  end
  return nil
end

local NATIVE_SOURCE = [[
return {
  band = function(a, b, ...)
    local value = a & b
    for i = 1, select('#', ...) do
      value = value & select(i, ...)
    end
    return value
  end,
  bor = function(a, b, ...)
    local value = a | b
    for i = 1, select('#', ...) do
      value = value | select(i, ...)
    end
    return value
  end,
  bnot = function(value)
    return ~value
  end,
  lshift = function(value, displacement)
    return value << displacement
  end,
}
]]

local function try_native()
  local compile = rawget(_G, 'loadstring') or rawget(_G, 'load')
  if type(compile) ~= 'function' then
    return nil, 'dynamic loader unavailable'
  end

  local ok_compile, chunk, compile_error = pcall(
    compile,
    NATIVE_SOURCE,
    '=(fibers native bit operations)'
  )
  if not ok_compile then
    return nil, tostring(chunk)
  end
  if type(chunk) ~= 'function' then
    return nil, tostring(compile_error or 'native bitwise syntax unavailable')
  end

  local ok_run, candidate = pcall(chunk)
  if not ok_run then
    return nil, tostring(candidate)
  end
  if not usable(candidate) then
    return nil, 'native bit-operation implementation is incomplete'
  end
  return candidate
end

function M.resolve()
  if cached_bit then
    return cached_bit, cached_source
  end
  if cached_error then
    return nil, cached_error
  end

  local candidate

  -- LuaJIT's bit library is part of the runtime and should take precedence
  -- over compatibility modules.  It may already be global or may need to be
  -- loaded explicitly.
  if type(rawget(_G, 'jit')) == 'table' then
    candidate = rawget(_G, 'bit')
    if not usable(candidate) then
      candidate = try_module('bit')
    end
    if candidate then
      cached_bit = candidate
      cached_source = 'LuaJIT bit library'
      return cached_bit, cached_source
    end
  end

  -- Stock Lua 5.3 and later provide bitwise operators in the language.  Try
  -- them before any compatibility module, while keeping this source file
  -- parseable by Lua 5.1.
  local native, native_error = try_native()
  if native then
    cached_bit = native
    cached_source = 'native Lua bitwise operators'
    return cached_bit, cached_source
  end

  candidate = rawget(_G, 'bit')
  if usable(candidate) then
    cached_bit = candidate
    cached_source = 'global bit'
    return cached_bit, cached_source
  end

  candidate = try_module('bit')
  if candidate then
    cached_bit = candidate
    cached_source = 'bit module'
    return cached_bit, cached_source
  end

  candidate = rawget(_G, 'bit32')
  if usable(candidate) then
    cached_bit = candidate
    cached_source = 'global bit32'
    return cached_bit, cached_source
  end

  candidate = try_module('bit32')
  if candidate then
    cached_bit = candidate
    cached_source = 'bit32 module'
    return cached_bit, cached_source
  end

  cached_error = 'bit operations unavailable: ' .. tostring(native_error or 'no provider found')
  return nil, cached_error
end

return M
