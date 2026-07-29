---Composable host platform assembled from independent capability providers.
---
---A provider is any table implementing the relevant host methods. Backends may
---supply a complete host for every slot, while embedders may select different
---providers for time, waiting, sockets, files, processes and resolution.
---Readiness-producing providers are checked against the selected wait domain so
---an apparently valid composition cannot silently stall.

local Platform = {}
Platform.__index = Platform

local SLOT_ALIASES = {
  clock = { 'clock', 'time' },
  wait = { 'wait', 'driver', 'poller' },
  readiness = { 'readiness' },
  pipe = { 'pipe', 'pipes' },
  socket = { 'socket', 'sockets', 'network' },
  datagram = { 'datagram', 'datagrams' },
  resolver = { 'resolver', 'dns' },
  process = { 'process', 'processes' },
  file = { 'file', 'files' },
  descriptor = { 'descriptor', 'fd' },
}

local METHOD_SLOTS = {
  now = 'clock',
  sleep = 'clock',
  block = 'wait',
  supports_interest = 'wait',
  set_readiness = 'readiness',
  clear_readiness = 'readiness',
  create_pipe = 'pipe',
  create_listener = 'socket',
  start_dial = 'socket',
  sort_destination_addresses = 'socket',
  create_datagram = 'datagram',
  resolve = 'resolver',
  start_process = 'process',
  file_provider = 'file',
}

local EMBED_METHODS = {
  'set_wake_callback',
  'has_pending_wake',
  'consume_wake',
  'has_external',
  '_drain_external',
  'enqueue',
  'deliver',
  'clear',
  'wake',
  'mark_done',
  'wait_done',
}

local WAIT_BOUND_SLOTS = {
  'pipe',
  'socket',
  'datagram',
  'process',
  'file',
  'descriptor',
}

local function first(value, names)
  for i = 1, #names do
    local found = value[names[i]]
    if found ~= nil then
      return found
    end
  end
end

local function provider_for(opts, slot)
  local providers = opts.providers or {}
  local base = opts.backend or opts.host or opts.default
  return first(providers, SLOT_ALIASES[slot]) or first(opts, SLOT_ALIASES[slot]) or base
end

local function domain_of(provider)
  if type(provider) ~= 'table' then
    return nil
  end
  return provider.wait_domain or provider.readiness_domain or provider.family
end

local function compatibility_key(left, right)
  left, right = tostring(left), tostring(right)
  return left < right and (left .. ':' .. right) or (right .. ':' .. left)
end

local function domains_compatible(opts, left, right, slot, provider)
  if left == nil or right == nil or left == right then
    return true
  end
  if opts.allow_mixed_wait_domains == true then
    return true
  end
  local policy = opts.compatible_wait_domains
  if type(policy) == 'function' then
    return policy(left, right, slot, provider) == true
  end
  if type(policy) == 'table' then
    return policy[compatibility_key(left, right)] == true
      or type(policy[left]) == 'table' and policy[left][right] == true
      or type(policy[right]) == 'table' and policy[right][left] == true
  end
  return false
end

local function call(provider, method, ...)
  return provider[method](provider, ...)
end

local function install_method(platform, method, provider)
  if type(provider) == 'table' and type(provider[method]) == 'function' then
    platform[method] = function(_, ...)
      return call(provider, method, ...)
    end
    return true
  end
  return false
end

local function copy_capability(dst, provider, name, fallback)
  local capabilities = type(provider) == 'table' and provider.capabilities or nil
  local value = capabilities and capabilities[name]
  if value == nil then
    value = fallback
  end
  if value ~= nil and value ~= false then
    dst[name] = value
  end
end

local function add_unique(out, seen, value)
  if type(value) == 'table' and not seen[value] then
    seen[value] = true
    out[#out + 1] = value
  end
end

function Platform.new(opts)
  opts = opts or {}
  local providers = {}
  for slot in pairs(SLOT_ALIASES) do
    providers[slot] = provider_for(opts, slot)
  end

  providers.wait = providers.wait or providers.clock
  providers.clock = providers.clock or providers.wait
  providers.readiness = providers.readiness or providers.wait
  providers.descriptor = providers.descriptor or providers.socket or providers.pipe

  if type(providers.clock) ~= 'table' or type(providers.clock.now) ~= 'function' then
    error('fibers.io.platform requires a clock provider with now()', 2)
  end
  if type(providers.wait) ~= 'table' or type(providers.wait.block) ~= 'function' then
    error('fibers.io.platform requires a wait provider with block()', 2)
  end

  local wait_domain = domain_of(providers.wait)
  for i = 1, #WAIT_BOUND_SLOTS do
    local slot = WAIT_BOUND_SLOTS[i]
    local provider = providers[slot]
    local domain = domain_of(provider)
    if provider and not domains_compatible(opts, wait_domain, domain, slot, provider) then
      error(
        'fibers.io.platform cannot combine wait domain '
          .. tostring(wait_domain)
          .. ' with '
          .. tostring(slot)
          .. ' provider domain '
          .. tostring(domain),
        2
      )
    end
  end

  local platform = setmetatable({
    kind = opts.kind or 'composed',
    name = opts.name or 'composed',
    family = opts.family or wait_domain or 'composed',
    wait_domain = wait_domain,
    providers = providers,
    capabilities = {},
    _owns_providers = opts.owns_providers ~= false,
    _closed = false,
  }, Platform)

  -- Runtime:now calls host.now(runtime), so retain the provider explicitly.
  platform.now = function()
    return call(providers.clock, 'now')
  end

  for method, slot in pairs(METHOD_SLOTS) do
    if method ~= 'now' then
      install_method(platform, method, providers[slot])
    end
  end
  for i = 1, #EMBED_METHODS do
    install_method(platform, EMBED_METHODS[i], providers.wait)
  end

  platform.fd = providers.descriptor and providers.descriptor.fd or nil
  platform.capabilities.time = true
  copy_capability(
    platform.capabilities,
    providers.readiness,
    'readiness',
    type(platform.set_readiness) == 'function' or nil
  )
  if platform.create_pipe then
    platform.capabilities.pipe = true
  end
  if platform.create_listener or platform.start_dial then
    platform.capabilities.socket = true
    for _, name in ipairs({ 'socket_ipv4', 'socket_ipv6', 'socket_unix' }) do
      copy_capability(platform.capabilities, providers.socket, name)
    end
  end
  if platform.create_datagram then
    platform.capabilities.datagram = true
  end
  if platform.resolve then
    platform.capabilities.resolver = true
    copy_capability(platform.capabilities, providers.resolver, 'resolver_blocking')
  end
  if platform.start_process then
    platform.capabilities.process = true
    for _, name in ipairs({ 'process_close_fds', 'process_groups' }) do
      copy_capability(platform.capabilities, providers.process, name)
    end
  end
  if platform.file_provider then
    platform.capabilities.file = true
    copy_capability(platform.capabilities, providers.file, 'file_backend')
  end
  for name, value in pairs(opts.capabilities or {}) do
    if value ~= false and value ~= nil then
      platform.capabilities[name] = value
    end
  end

  local close_order, seen = {}, {}
  for _, slot in ipairs({
    'file',
    'process',
    'resolver',
    'datagram',
    'socket',
    'pipe',
    'descriptor',
    'readiness',
    'wait',
    'clock',
  }) do
    add_unique(close_order, seen, providers[slot])
  end
  platform._close_order = close_order
  return platform
end

Platform.compose = Platform.new

function Platform.from(provider, opts)
  local out = {}
  for key, value in pairs(opts or {}) do
    out[key] = value
  end
  out.backend = provider
  return Platform.new(out)
end

function Platform:provider(slot)
  if SLOT_ALIASES[slot] == nil then
    error('unknown Fibers platform provider slot ' .. tostring(slot), 2)
  end
  return self.providers[slot]
end

function Platform:close()
  if self._closed then
    return true
  end
  self._closed = true
  if not self._owns_providers then
    return true
  end
  local failures = {}
  for i = 1, #self._close_order do
    local provider = self._close_order[i]
    if type(provider.close) == 'function' then
      local ok, closed, err = pcall(provider.close, provider)
      if not ok then
        failures[#failures + 1] = closed
      elseif closed == false or closed == nil and err ~= nil then
        failures[#failures + 1] = err or 'provider close failed'
      end
    end
  end
  if #failures > 0 then
    return nil, failures
  end
  return true
end

return Platform
