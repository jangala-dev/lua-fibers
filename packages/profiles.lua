-- Named example selections. The builder also accepts arbitrary repeated
-- --entry values; profiles are conveniences rather than prescribed builds.

local portable_resources = {
  'fibers.channel',
  'fibers.mailbox',
  'fibers.pulse',
  'fibers.semaphore',
  'fibers.latch',
  'fibers.sleep',
  'fibers.stream',
  'fibers.resource.cell',
  'fibers.resource.counter',
  'fibers.resource.fifo',
  'fibers.resource.rendezvous',
  'fibers.resource.signal',
  'fibers.resource.event_queue',
}

local function combine(...)
  local out, seen = {}, {}
  for index = 1, select('#', ...) do
    local values = select(index, ...)
    for i = 1, #(values or {}) do
      local value = values[i]
      if not seen[value] then
        seen[value] = true
        out[#out + 1] = value
      end
    end
  end
  return out
end

local core_surface = combine({ 'fibers', 'fibers.op', 'fibers.embed' }, portable_resources)
local core = core_surface
local io_public = {
  'fibers.io',
  'fibers.file',
  'fibers.socket',
  'fibers.process',
}

return {
  ['core-minimal'] = {
    description = 'Root lifecycle and operation algebra only',
    entries = { 'fibers', 'fibers.op' },
  },
  core = {
    description = 'Structured Fibers and portable resources',
    entries = core,
  },
  roblox = {
    description = 'Luau/Roblox embedded runtime and Roblox adapters',
    entries = combine(core, { 'fibers.roblox' }),
  },
  ['io-nixio'] = {
    description = 'Portable I/O facilities with the nixio backend',
    entries = combine(core, io_public, { 'fibers.io.nixio' }),
  },
  ['io-ffi'] = {
    description = 'Portable I/O facilities with the LuaJIT Linux FFI backend',
    entries = combine(core, io_public, { 'fibers.io.luajit_linux' }),
  },
  ['io-cffi'] = {
    description = 'Portable I/O facilities with the CFFI Linux backend',
    entries = combine(core, io_public, { 'fibers.io.cffi_linux' }),
  },
  ['io-luaposix'] = {
    description = 'Portable I/O facilities with the luaposix backend',
    entries = combine(core, io_public, { 'fibers.io.luaposix' }),
  },
  full = {
    description = 'Convenience build with automatic backend discovery and diagnostics',
    entries = combine(core, io_public, {
      'fibers.io.auto',
      'fibers.io.luajit_linux',
      'fibers.io.cffi_linux',
      'fibers.io.luaposix',
      'fibers.io.nixio',
      'fibers.roblox',
      'fibers.diagnostics.search',
      'fibers.diagnostics.io',
    }),
  },
}
