package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua', './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Platform = require('fibers.io.platform')
local Manual = require('fibers.embed.manual')

local closed = {}
local function provider(name, family, methods, capabilities)
  local out = {
    name = name,
    kind = name,
    family = family,
    wait_domain = family,
    capabilities = capabilities or {},
  }
  for key, value in pairs(methods or {}) do out[key] = value end
  function out:close()
    closed[#closed + 1] = self.name
    return true
  end
  return out
end

local driver = Manual.new({ name = 'driver', family = 'numeric-fd', now = 12 })
local close_driver = driver.close
function driver:close()
  closed[#closed + 1] = self.name
  return close_driver(self)
end
local sockets = provider('sockets', 'numeric-fd', {
  create_listener = function(self, address)
    return self.name .. ':' .. address
  end,
  start_dial = function(self, address)
    return self.name .. ':' .. address
  end,
}, { socket_ipv4 = true, socket_unix = true })
local files_and_processes = provider('system', 'numeric-fd', {
  create_pipe = function(self) return self.name .. ':reader', self.name .. ':writer' end,
  file_provider = function(self) return self.name .. ':files' end,
  start_process = function(self, spec) return self.name .. ':' .. spec.command end,
}, { file_backend = 'worker', process_groups = 'session' })
local resolver = provider('resolver', 'callback', {
  resolve = function(self, endpoint) return { self.name .. ':' .. endpoint.host } end,
}, { resolver_blocking = false })


assert(Platform.compose == nil, 'Platform.compose should be removed')
local legacy_ok, legacy_err = pcall(Platform.new, { driver = driver })
assert(not legacy_ok and tostring(legacy_err):match('does not accept'), 'legacy top-level platform slots should fail')
legacy_ok, legacy_err = pcall(Platform.new, { providers = { driver = driver } })
assert(not legacy_ok and tostring(legacy_err):match('does not accept'), 'legacy provider aliases should fail')

local platform = Platform.new({
  name = 'mixed',
  providers = {
    clock = driver,
    wait = driver,
    socket = sockets,
    pipe = files_and_processes,
    file = files_and_processes,
    process = files_and_processes,
    resolver = resolver,
  },
})

assert(platform:now() == 12)
assert(platform:create_listener('local') == 'sockets:local')
assert(platform:start_dial('peer') == 'sockets:peer')
local reader, writer = platform:create_pipe()
assert(reader == 'system:reader' and writer == 'system:writer')
assert(platform:file_provider() == 'system:files')
assert(platform:start_process({ command = 'worker' }) == 'system:worker')
assert(platform:resolve({ host = 'example' })[1] == 'resolver:example')
assert(platform.capabilities.socket_ipv4 and platform.capabilities.socket_unix)
assert(platform.capabilities.file and platform.capabilities.process and platform.capabilities.resolver)
assert(platform:provider('socket') == sockets)
assert(platform:close())
assert(#closed == 4, 'each distinct owned provider should close once')


local complete = provider('complete', 'numeric-fd', {
  now = function() return 4 end,
  block = function() return nil, 'not-ready' end,
  create_listener = function() return 'complete-listener' end,
})
local from_complete = Platform.from(complete, { owns_providers = false })
assert(from_complete:now() == 4)
assert(from_complete:create_listener() == 'complete-listener')
assert(from_complete:close())

local incompatible = provider('incompatible', 'opaque-handle', {
  create_listener = function() return true end,
})
local ok, err = pcall(Platform.new, {
  providers = { clock = driver, wait = driver, socket = incompatible },
})
assert(not ok and tostring(err):match('cannot combine wait domain'))

local allowed = Platform.new({
  providers = { clock = driver, wait = driver, socket = incompatible },
  owns_providers = false,
  compatible_wait_domains = { ['numeric-fd:opaque-handle'] = true },
})
assert(allowed.capabilities.socket)
assert(allowed:close())

return true
