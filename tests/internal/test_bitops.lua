package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local BitOps = require('fibers.internal.bitops')
local bit, source = BitOps.resolve()
assert(bit, source)
assert(type(source) == 'string' and source ~= '')
assert(bit.band(0x0f, 0x06) == 0x06)
assert(bit.bor(0x08, 0x03) == 0x0b)
assert(bit.band(bit.bnot(0x04), 0x0f) == 0x0b)
assert(bit.lshift(1, 30) == 1073741824)
assert(bit.band(0x0f, 0x07, 0x03) == 0x03)
assert(bit.bor(0x01, 0x02, 0x04) == 0x07)

print('tests/test_bitops.lua: ok (' .. source .. ')')

local function fake_provider(marker)
  return {
    marker = marker,
    band = function(a, b)
      return a + b
    end,
    bor = function(a, b)
      return a + b
    end,
    bnot = function(value)
      return -value
    end,
    lshift = function(value, displacement)
      return value + displacement
    end,
  }
end

local function with_providers(bit_provider, bit32_provider, options, fn)
  options = options or {}

  local original_require = require
  local original_bit = rawget(_G, 'bit')
  local original_bit32 = rawget(_G, 'bit32')
  local original_jit = rawget(_G, 'jit')
  local original_load = rawget(_G, 'load')
  local original_loadstring = rawget(_G, 'loadstring')

  _G.bit = nil
  _G.bit32 = nil
  if options.hide_jit then
    _G.jit = nil
  end
  if options.hide_native then
    _G.load = nil
    _G.loadstring = nil
  end

  _G.require = function(name)
    if name == 'bit' then
      if bit_provider then
        return bit_provider
      end
      error('bit provider hidden for precedence test', 2)
    end
    if name == 'bit32' then
      if bit32_provider then
        return bit32_provider
      end
      error('bit32 provider hidden for precedence test', 2)
    end
    return original_require(name)
  end

  local ok, err = pcall(fn)
  _G.require = original_require
  _G.bit = original_bit
  _G.bit32 = original_bit32
  _G.jit = original_jit
  _G.load = original_load
  _G.loadstring = original_loadstring
  assert(ok, err)
end

if _VERSION == 'Lua 5.3' or _VERSION == 'Lua 5.4' or _VERSION == 'Lua 5.5' then
  with_providers(fake_provider('bit'), fake_provider('bit32'), {}, function()
    local NativeBitOps = dofile('src/fibers/internal/bitops.lua')
    local native, native_source = NativeBitOps.resolve()
    assert(native, native_source)
    assert(native_source == 'native Lua bitwise operators')
    assert(native.band(native.bnot(0x04), 0x0f) == 0x0b)
    assert(native.lshift(1, 30) == 1073741824)
  end)
end

local fake_bit = fake_provider('bit')
local fake_bit32 = fake_provider('bit32')

with_providers(fake_bit, fake_bit32, {
  hide_jit = true,
  hide_native = true,
}, function()
  local ModuleBitOps = dofile('src/fibers/internal/bitops.lua')
  local selected, selected_source = ModuleBitOps.resolve()
  assert(selected == fake_bit)
  assert(selected_source == 'bit module')
end)

with_providers(nil, fake_bit32, {
  hide_jit = true,
  hide_native = true,
}, function()
  local Bit32Ops = dofile('src/fibers/internal/bitops.lua')
  local selected, selected_source = Bit32Ops.resolve()
  assert(selected == fake_bit32)
  assert(selected_source == 'bit32 module')
end)

if type(rawget(_G, 'jit')) == 'table' then
  local LuaJITBitOps = dofile('src/fibers/internal/bitops.lua')
  local selected, selected_source = LuaJITBitOps.resolve()
  assert(selected, selected_source)
  assert(selected_source == 'LuaJIT bit library')
end
