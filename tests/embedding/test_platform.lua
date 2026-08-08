package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua', './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Platform = require('fibers.io.platform')
local Manual = require('fibers.embed.manual')

local closed = {}
local function provider(name, family, methods, features)
  local out = {
    name = name,
    kind = name,
    family = family,
    wait_domain = family,
    features = features or {},
  }
  for key, value in pairs(methods or {}) do out[key] = value end
  function out:close()
    closed[#closed + 1] = self.name
    return true
  end
  return out
end

local driver = Manual.new({ label = 'driver', family = 'numeric-fd', now = 12 })
local close_driver = driver.close
function driver:close()
  closed[#closed + 1] = self:label() or self.kind
  return close_driver(self)
end
local sockets = provider('sockets', 'numeric-fd', {
  create_listener = function(self, address)
    return self.name .. ':' .. address
  end,
  start_dial = function(self, address)
    return self.name .. ':' .. address
  end,
}, { socket = true, socket_ipv4 = true, socket_unix = true })
local files_and_processes = provider('system', 'numeric-fd', {
  create_pipe = function(self) return self.name .. ':reader', self.name .. ':writer' end,
  file_provider = function(self) return self.name .. ':files' end,
  start_process = function(self, spec) return self.name .. ':' .. spec.command end,
}, { pipe = true, file = true, process = true, file_backend = 'worker', process_groups = 'session' })
local resolver = provider('resolver', 'callback', {
  resolve = function(self, endpoint) return { self.name .. ':' .. endpoint.host } end,
}, { resolver = true, resolver_blocking = false })


local platform = Platform.new({
  label = 'mixed',
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
assert(platform:feature('socket_ipv4') and platform:feature('socket_unix'))
assert(platform:feature('file') and platform:feature('process') and platform:feature('resolver'))
assert(platform.capabilities == nil and platform.features == nil and platform.providers == nil)
assert(platform.application == nil and platform.closed == nil)
assert(platform:close())
assert(#closed == 4, 'each distinct owned provider should close once')


local complete = provider('complete', 'numeric-fd', {
  now = function() return 4 end,
  block = function() return nil, 'not-ready' end,
  create_listener = function() return 'complete-listener' end,
  start_dial = function() return 'complete-dial' end,
}, { socket = true })
local from_complete = Platform.from(complete, { owns_providers = false })
assert(from_complete:now() == 4)
assert(from_complete:create_listener() == 'complete-listener')
assert(from_complete:close())

local incompatible = provider('incompatible', 'opaque-handle', {
  create_listener = function() return true end,
  start_dial = function() return true end,
}, { socket = true })
local ok, err = pcall(Platform.new, {
  providers = { clock = driver, wait = driver, socket = incompatible },
})
assert(not ok and tostring(err):match('cannot combine wait domain'))

local allowed = Platform.new({
  providers = { clock = driver, wait = driver, socket = incompatible },
  owns_providers = false,
  compatible_wait_domains = { ['numeric-fd:opaque-handle'] = true },
})
assert(allowed:feature('socket'))
assert(allowed:close())

local method_defined = provider('method-defined', 'numeric-fd', {
  create_pipe = function() return true end,
})
local method_platform = Platform.new({
  providers = { clock = driver, wait = driver, pipe = method_defined },
  owns_providers = false,
})
assert(method_platform:feature('pipe') == true)

local incomplete = provider('incomplete', 'numeric-fd', {})
local ok_missing, err_missing = pcall(Platform.new, {
  providers = { clock = driver, wait = driver, pipe = incomplete },
  owns_providers = false,
})
assert(not ok_missing and tostring(err_missing):match('does not implement its complete method contract'))

return true
