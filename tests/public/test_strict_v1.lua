package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local Runtime = require('fibers.runtime')
local Stream = require('fibers.stream')
local socket = require('fibers.socket')
local Address = require('fibers.net.address')
local Process = require('fibers.process')
local DNSResolver = require('fibers.dns.resolver')

local function rejects(label, fn)
  local ok = pcall(fn)
  if ok then error(label .. ' should reject malformed v1 input', 2) end
end

-- nil is the omission/default sentinel. Wrongly typed values are not treated as nil.
rejects('Stream.memory_pair false options', function() Stream.memory_pair(false) end)
rejects('Runtime numeric string budget', function() Runtime.new({ search_step_budget = '100' }) end)
rejects('Runtime fractional budget', function() Runtime.new({ search_step_budget = 1.5 }) end)

-- Public option tables are closed records rather than bags of hints.
rejects('listener unknown option', function()
  socket.listen_op(Address.ipv4('127.0.0.1', 0), { legacy_hint = true })
end)
rejects('listener truthy boolean', function()
  socket.listen_op(Address.ipv4('127.0.0.1', 0), { nodelay = 1 })
end)
rejects('numeric dial unknown option', function()
  socket.dial_op(Address.ipv4('127.0.0.1', 80), { retry = true })
end)
rejects('named dial unknown option', function()
  socket.dial_op(Address.name('example.test', 80), { retry = true })
end)
rejects('named dial truthy dns flag', function()
  socket.dial_op(Address.name('example.test', 80), { dns = 1 })
end)

-- Canonical vocabulary has no pre-v1 aliases.
rejects('Address.name family alias', function()
  Address.name('example.test', 80, { family = 'inet4' })
end)
rejects('process new_session alias', function()
  Process.command({ argv = { 'true' }, new_session = true })
end)

-- Resolver policy is numeric policy, not stringly configuration.
rejects('DNS attempts numeric string', function() DNSResolver.new({ attempts = '2' }) end)
rejects('DNS cache numeric string', function() DNSResolver.new({ maximum_cache_entries = '100' }) end)

-- Lua-file compatibility reads are deliberately absent from the v1 Stream surface.
local left = Stream.memory_pair()
if left.read ~= nil or left.read_op ~= nil then
  error('v1 Stream must not expose Lua-file read compatibility methods', 2)
end

return true
