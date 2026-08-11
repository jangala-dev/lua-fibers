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
local Cell = require('fibers.resource.cell')
local Counter = require('fibers.resource.counter')
local Lifetime = require('fibers.lifetime')
local Machine = require('fibers.resource.machine')
local Index = require('fibers.resource.index')
local ClaimSet = require('fibers.resource.claim_set')
local Signal = require('fibers.resource.signal')
local EventQueue = require('fibers.resource.event_queue')
local Readiness = require('fibers.io.readiness')
local Grant = require('fibers.grant')
local Scope = require('fibers.scope')
local Task = require('fibers.task')
local Flow = require('fibers.resource.flow')
local HostHandle = require('fibers.io.handle')
local File = require('fibers.file')

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


-- Mutable algebraic resources do not expose side-channel snapshots or epochs.
do
  local cell = Cell.new('sealed')
  if cell.value ~= nil or cell.version ~= nil or cell.changed_op ~= nil or cell.changed ~= nil then
    error('v1 Cell must expose state only through algebraic operations', 2)
  end

  local counter = Counter.new(1)
  if counter.value ~= nil or counter.version ~= nil or counter.changed_op ~= nil or counter.changed ~= nil
      or counter.min ~= nil or counter.max ~= nil then
    error('v1 Counter must expose state only through algebraic operations', 2)
  end

  local machine = Machine.new('sealed')
  if machine.value ~= nil or machine.version ~= nil then
    error('v1 Machine must expose state only through algebraic operations', 2)
  end

  local index = Index.new()
  if index.entries ~= nil or index.version ~= nil or index.changed_op ~= nil or index.changed ~= nil then
    error('v1 Index must expose state only through algebraic operations', 2)
  end

  local claim_set = ClaimSet.new()
  if claim_set.holders ~= nil or claim_set.versions ~= nil or claim_set.version ~= nil or claim_set.compat ~= nil then
    error('v1 ClaimSet must expose state only through algebraic operations', 2)
  end

  local signal = Signal.new()
  if signal.version ~= nil then
    error('v1 Signal must not expose its internal epoch', 2)
  end

  local events = EventQueue.new()
  if events.version ~= nil or events.length ~= nil then
    error('v1 EventQueue must expose queued events only through algebraic operations', 2)
  end

  local readiness = Readiness.new('strict-v1')
  if readiness.version ~= nil or readiness.key ~= nil or readiness.mode ~= nil then
    error('v1 Readiness must not expose its internal epoch', 2)
  end

  local flow = Flow.new(8)
  if flow.capacity ~= nil or flow:inlet().flow ~= nil or flow:outlet().flow ~= nil then
    error('v1 Flow must not expose authoritative capacity or endpoint back-references', 2)
  end

  local handle = HostHandle.new({ close = function() return true end })
  for _, name in ipairs({ 'key', 'handle', 'host', 'readiness', 'feed', 'runtime', 'stream', 'closed', 'close_error' }) do
    if handle[name] ~= nil then
      error('v1 HostHandle must not expose mutable host state: ' .. name, 2)
    end
  end

  local life = Lifetime.new()
  for _, name in ipairs({
    'current_state', 'inspect_op', 'cancellation_op',
    'runtime', 'closure', 'body', 'has_body', 'role', 'rights', 'meta', 'value',
    'bind_runtime', 'record_map', 'assert_runtime_compatible',
  }) do
    if life[name] ~= nil then
      error('v1 Lifetime must not expose generic live-state observation: ' .. name, 2)
    end
  end
  for _, name in ipairs({ 'runtime', 'closure', 'offers', 'interrupt', 'cancellation', 'mask_depth' }) do
    if Scope.new()[name] ~= nil then
      error('v1 Scope must not proxy Lifetime internals: ' .. name, 2)
    end
  end
  for _, name in ipairs({ 'inspect_op', 'children_op', 'custody_op', 'subtree_op', 'running_children_op', 'cancellation_op' }) do
    if Scope[name] ~= nil then
      error('v1 Scope must not expose generic live-state observation: ' .. name, 2)
    end
  end
  if Task.state_op ~= nil then
    error('v1 Task must expose body/outcome facts, not a generic state snapshot', 2)
  end
  if Grant.inspect ~= nil or Grant.inspect_op ~= nil then
    error('v1 Grant must expose immutable authority queries, not custody snapshots', 2)
  end

  local ProcessClass = Process.Process
  for _, name in ipairs({ 'state_op', 'state_value', 'host_handle' }) do
    if ProcessClass[name] ~= nil then
      error('v1 Process must expose focused lifecycle facts rather than generic live state: ' .. name, 2)
    end
  end
  for _, name in ipairs({ 'pid', 'stdin', 'stdout', 'stderr' }) do
    if type(ProcessClass[name .. '_op']) ~= 'function' or type(ProcessClass[name]) ~= 'function' then
      error('v1 Process focused fact must provide an Option and performing twin: ' .. name, 2)
    end
  end

  for label, class in pairs({
    Listener = socket.Listener,
    Dial = socket.Dial,
    Query = socket.Query,
    DatagramSocket = socket.DatagramSocket,
  }) do
    for _, name in ipairs({ 'state_op', 'state_value', 'host_handle', 'inspect_op' }) do
      if class[name] ~= nil then
        error('v1 ' .. label .. ' must not expose generic live-state observation: ' .. name, 2)
      end
    end
  end
  for _, class in ipairs({ socket.Listener, socket.DatagramSocket }) do
    if type(class.local_address_op) ~= 'function' or type(class.local_address) ~= 'function' then
      error('v1 bound-address facts must be Options with performing twins', 2)
    end
  end

end


-- Regular-file bytes use the shared Flow data plane; the old per-operation
-- Request/RPC surface must not creep back into v1.
if File.Request ~= nil then
  error('v1 File must not expose a data-plane Request type', 2)
end
for _, name in ipairs({
  'submit_read_op', 'submit_read_exactly_op', 'submit_read_line_op',
  'submit_write_op', 'submit_write_all_op',
}) do
  if File.RegularFile[name] ~= nil then
    error('v1 RegularFile data plane must transact directly rather than submit ' .. name, 2)
  end
end
if type(File.RegularFile.read_some_op) ~= 'function' or type(File.RegularFile.write_some_op) ~= 'function' then
  error('v1 RegularFile must expose the shared Stream byte-plane vocabulary', 2)
end
for _, name in ipairs({ 'read_exactly', 'read_all', 'write_all' }) do
  if type(File.RegularFile[name]) ~= 'function' or type(File.RegularFile[name .. '_op']) ~= 'function' then
    error('v1 RegularFile bounded byte protocol must expose direct and atomic forms: ' .. name, 2)
  end
end

-- Lua-file compatibility reads are deliberately absent from the v1 Stream surface.
local left = Stream.memory_pair()
for _, name in ipairs({ 'read_exactly', 'read_all', 'write_all' }) do
  if type(left[name]) ~= 'function' or type(left[name .. '_op']) ~= 'function' then
    error('v1 Stream bounded byte protocol must expose direct and atomic forms: ' .. name, 2)
  end
end
if left.read ~= nil or left.read_op ~= nil then
  error('v1 Stream must not expose Lua-file read compatibility methods', 2)
end
for _, name in ipairs({ 'close_state', 'state_op', 'state_value', 'inspect_op' }) do
  if left[name] ~= nil then
    error('v1 Stream must not expose generic live-state observation: ' .. name, 2)
  end
end

return true
