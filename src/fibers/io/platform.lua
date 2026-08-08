-- Composable host compiled once from capability providers.

local Base = require('fibers.internal.host.base')
local Label = require('fibers.internal.label')
local Contract = require('fibers.internal.contract')

local Platform = {}
Platform.__index = Platform
setmetatable(Platform, { __index = Base })

local SLOTS = {
  'clock', 'wait', 'readiness', 'pipe', 'socket', 'datagram',
  'resolver', 'process', 'file', 'descriptor',
}
local SLOT_SET = {}
for i = 1, #SLOTS do SLOT_SET[SLOTS[i]] = true end

local OPTIONS = {
  providers = true, backend = true, allow_mixed_wait_domains = true,
  compatible_wait_domains = true, kind = true, label = true, family = true,
  owns_providers = true,
}
local WAIT_BOUND = { 'pipe', 'socket', 'datagram', 'process', 'file', 'descriptor' }
local METHODS = {
  sleep = 'clock', block = 'wait', supports_interest = 'wait',
  set_readiness = 'readiness', clear_readiness = 'readiness',
  create_pipe = 'pipe', create_listener = 'socket', start_dial = 'socket',
  sort_destination_addresses = 'socket', create_datagram = 'datagram',
  resolve = 'resolver', start_process = 'process', file_provider = 'file',
  set_wake_callback = 'wait', _has_pending_wake = 'wait', _consume_wake = 'wait',
  _has_external = 'wait', _drain_external = 'wait', enqueue = 'wait', deliver = 'wait',
  clear = 'wait', wake = 'wait', mark_done = 'wait', wait_done = 'wait',
}
local CONTRACTS = {
  readiness = { 'set_readiness' }, pipe = { 'create_pipe' },
  socket = { 'create_listener', 'start_dial' }, datagram = { 'create_datagram' },
  resolver = { 'resolve' }, process = { 'start_process' }, file = { 'file_provider' },
}
local DECLARED = {
  socket = { 'socket_ipv4', 'socket_ipv6', 'socket_unix' },
  datagram = { 'datagram_truncation' }, resolver = { 'resolver_blocking' },
  process = { 'process_close_fds', 'process_groups' }, file = { 'file_backend' },
}
local next_platform = 0

local function domain(provider)
  return type(provider) == 'table' and (provider._wait_domain or provider.wait_domain or provider.readiness_domain or provider.family) or nil
end

local function compatible(opts, left, right, slot, provider)
  if left == nil or right == nil or left == right or opts.allow_mixed_wait_domains == true then return true end
  local policy = opts.compatible_wait_domains
  if type(policy) == 'function' then return policy(left, right, slot, provider) == true end
  if type(policy) ~= 'table' then return false end
  local a, b = tostring(left), tostring(right)
  local key = a < b and (a .. ':' .. b) or (b .. ':' .. a)
  return policy[key] == true
    or type(policy[left]) == 'table' and policy[left][right] == true
    or type(policy[right]) == 'table' and policy[right][left] == true
end

local function contract(provider, methods, label, required)
  if provider == nil then return false end
  if type(provider) ~= 'table' then error(label .. ' provider must be a table', 3) end
  local n = 0
  for i = 1, #methods do if type(provider[methods[i]]) == 'function' then n = n + 1 end end
  if n ~= #methods and (required or n ~= 0) then
    error(label .. ' provider does not implement its complete method contract', 3)
  end
  return n == #methods
end

local function feature_source(provider)
  if type(provider) ~= 'table' then return nil end
  if type(provider.feature) == 'function' then
    return function(name) return provider:feature(name) end
  end
  local values = provider.features
  if type(values) == 'table' then return function(name) return values[name] end end
  return nil
end

local function close_platform(host)
  if not host._owns_providers then return true end
  local failures = {}
  for i = 1, #host._close_order do
    local provider = host._close_order[i]
    if type(provider.close) == 'function' then
      local ok, closed, err = pcall(provider.close, provider)
      if not ok then failures[#failures + 1] = closed
      elseif closed == false or closed == nil and err ~= nil then
        failures[#failures + 1] = err or 'provider close failed'
      end
    end
  end
  return #failures == 0 and true or nil, #failures > 0 and failures or nil
end

function Platform.new(opts)
  opts = Contract.options(opts, OPTIONS, 'fibers.io.platform options', 2)
  Contract.options(opts.providers, SLOT_SET, 'fibers.io.platform providers', 2)
  Contract.optional_boolean(opts.allow_mixed_wait_domains, 'allow_mixed_wait_domains', 2)
  Contract.optional_boolean(opts.owns_providers, 'owns_providers', 2)
  if opts.compatible_wait_domains ~= nil
      and type(opts.compatible_wait_domains) ~= 'table'
      and type(opts.compatible_wait_domains) ~= 'function' then
    error('compatible_wait_domains must be a table, function or nil', 2)
  end
  if opts.backend ~= nil and type(opts.backend) ~= 'table' then
    error('fibers.io.platform backend must be a provider table or nil', 2)
  end

  local input, providers = opts.providers or {}, {}
  for i = 1, #SLOTS do
    local slot = SLOTS[i]
    providers[slot] = input[slot] or opts.backend
  end
  local clock, wait = providers.clock, providers.wait
  if type(clock) ~= 'table' or type(clock.now) ~= 'function' then
    error('fibers.io.platform requires a clock provider with now()', 2)
  end
  if type(wait) ~= 'table' or type(wait.block) ~= 'function' then
    error('fibers.io.platform requires a wait provider with block()', 2)
  end
  local wait_domain = domain(wait)
  for i = 1, #WAIT_BOUND do
    local slot, provider = WAIT_BOUND[i], providers[WAIT_BOUND[i]]
    local d = domain(provider)
    if provider and not compatible(opts, wait_domain, d, slot, provider) then
      error('fibers.io.platform cannot combine wait domain ' .. tostring(wait_domain)
        .. ' with ' .. slot .. ' provider domain ' .. tostring(d), 2)
    end
  end

  local features = { time = true }
  for slot, methods in pairs(CONTRACTS) do
    local provider = providers[slot]
    if contract(provider, methods, slot, input[slot] ~= nil) then
      features[slot] = true
      local get = feature_source(provider)
      local names = DECLARED[slot]
      if get and names then
        for i = 1, #names do
          local value = get(names[i])
          if value ~= nil and value ~= false then features[names[i]] = value end
        end
      end
    end
  end

  local close_order, seen = {}, {}
  for _, slot in ipairs({ 'file', 'process', 'resolver', 'datagram', 'socket', 'pipe',
      'descriptor', 'readiness', 'wait', 'clock' }) do
    local provider = providers[slot]
    if type(provider) == 'table' and not seen[provider] then
      seen[provider], close_order[#close_order + 1] = true, provider
    end
  end

  next_platform = next_platform + 1
  local host = Label.attach(setmetatable({
    _fibers_id = 'io-platform-' .. tostring(next_platform),
    kind = opts.kind or 'composed', family = opts.family or wait_domain or 'composed',
    _owns_providers = opts.owns_providers ~= false,
    _close_order = close_order,
    _wait_domain = wait_domain,
    fd = providers.descriptor and providers.descriptor.fd or nil,
  }, Platform), opts.label)
  for i = 1, #SLOTS do host['_' .. SLOTS[i]] = providers[SLOTS[i]] end
  Base.init(host, features, close_platform)
  host.now = function() return clock.now(clock) end
  return host
end

for method, slot in pairs(METHODS) do
  local field = '_' .. slot
  Platform[method] = function(self, ...)
    local provider = self[field]
    local fn = provider and provider[method]
    if fn then return fn(provider, ...) end
  end
end

function Platform.from(provider, opts)
  opts = Contract.options(opts, {
    allow_mixed_wait_domains = true, compatible_wait_domains = true,
    kind = true, label = true, family = true, owns_providers = true,
  }, 'fibers.io.platform.from options', 2)
  if type(provider) ~= 'table' then error('fibers.io.platform.from provider must be a table', 2) end
  local out = {}
  for key, value in pairs(opts) do out[key] = value end
  out.backend = provider
  return Platform.new(out)
end

return Platform
