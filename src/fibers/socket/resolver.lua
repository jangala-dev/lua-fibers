-- Asynchronous resolver queries as running Lifetimes.
--
-- The host decides how resolution is performed. A simple host may execute a
-- blocking resolver call in the committed driver fibre and advertises that fact
-- through its capability table; embedded hosts may provide a worker or native
-- asynchronous resolver instead.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Address = require('fibers.socket.address')
local Completion = require('fibers.resource.completion')
local HostError = require('fibers.host.error')
local DNSResolver = require('fibers.dns.resolver')
local IO = require('fibers.host.io')
local Lifetime = require('fibers.lifetime')
local Task = require('fibers.task')
local Scope = require('fibers.scope')
local Protected = require('fibers.internal.protected')
local Closure = require('fibers.closure')
local perform = require('fibers.perform')

local Module = {}
local Query = {}
Query.__index = Query
local next_query = 0

local function query_closure(query)
  return Closure.request_then_wait(function(_ctx, _record, reason)
    return query:close_op(reason or 'resolver query closure')
  end, function()
    return query:closed_op()
  end, {
    name = 'resolver_query',
    finish_result = Closure.require_ok('resolver query closure failed'),
  })
end

local FAMILIES = { 'inet6', 'inet4' }

local function family_completion(query, family, level)
  if family ~= 'inet4' and family ~= 'inet6' then
    error('resolver family must be inet4 or inet6', level or 3)
  end
  return query.family_completions[family]
end

function Query:family_addresses_op(family)
  return family_completion(self, family):success_op()
end

Query.family_ready_op = Query.family_addresses_op

function Query:family_failed_op(family)
  return family_completion(self, family):failure_op()
end

function Query:family_result_op(family)
  local completion = family_completion(self, family)
  return completion:success_op():or_else(completion:failure_op():map(function(err)
    return nil, err
  end))
end

function Query:family_finished_op(family)
  return family_completion(self, family):terminal_op()
end

Query.family_state_op = Query.family_finished_op

local function terminal_values(state)
  if state.kind ~= 'succeeded' then
    return nil
  end
  local values = state.values
  return values and values[1] or state.value
end

local function combine_family_states(query, families)
  local addresses, errors, preferred_error = {}, {}, nil
  for i = 1, #FAMILIES do
    local family = FAMILIES[i]
    local state = families[family]
    local values = terminal_values(state)
    if values then
      for j = 1, #values do
        addresses[#addresses + 1] = values[j]
      end
    elseif state.kind == 'failed' then
      errors[#errors + 1] = state.error
      if not preferred_error and (type(state.error) ~= 'table' or state.error.code ~= 'EAI_FAMILY') then
        preferred_error = state.error
      end
    elseif state.kind == 'cancelled' then
      errors[#errors + 1] = state.reason
      preferred_error = preferred_error or state.reason
    end
  end
  if #addresses > 0 then
    return addresses
  end
  return nil,
    preferred_error or errors[1] or HostError.system(
      'resolver',
      'resolve',
      'name resolved to no usable addresses',
      'EAI_NONAME',
      nil,
      { endpoint = query.endpoint }
    )
end

function Query:result_op()
  return Op.named_all({
    inet6 = self:family_finished_op('inet6'),
    inet4 = self:family_finished_op('inet4'),
  }):map(function(families)
    return combine_family_states(self, families)
  end)
end

function Query:addresses_op()
  return self:result_op():and_then(function(addresses)
    if addresses then
      return Op.always(addresses)
    end
    return Op.never()
  end)
end

function Query:failed_op()
  return self:result_op():and_then(function(addresses, err)
    if not addresses then
      return Op.always(err)
    end
    return Op.never()
  end)
end

function Query:state_op()
  return Op.named_all({
    inet6 = self:family_finished_op('inet6'),
    inet4 = self:family_finished_op('inet4'),
  }):map(function(families)
    local addresses, err = combine_family_states(self, families)
    if addresses then
      return { kind = 'succeeded', value = addresses, families = families }
    end
    return { kind = 'failed', error = err, families = families }
  end)
end

function Query:close_op(reason)
  reason = reason or 'resolver query closed'
  local cancel = self.driver and self.driver:request_cancel_op(reason) or Op.always(true)
  local err = HostError.closed('resolver', 'resolve', {
    reason = reason,
    endpoint = self.endpoint,
  })
  local publishes = {}
  for i = 1, #FAMILIES do
    publishes[#publishes + 1] = self.family_completions[FAMILIES[i]]:publish_cancelled_op(err)
  end
  return cancel:and_then(function()
    return Op.all(publishes):map(function()
      return true
    end)
  end)
end

function Query:closed_op()
  local terminal = Op.named_all({
    inet6 = self:family_finished_op('inet6'),
    inet4 = self:family_finished_op('inet4'),
  }):map(function()
    return true
  end)
  return IO.closed_after_driver_op(self.driver, terminal)
end

local function normalise_addresses(values, endpoint, allow_empty, expected_family)
  if type(values) ~= 'table' then
    return nil,
      HostError.protocol('resolver', 'resolve', 'host resolver must return an address list', {
        endpoint = endpoint,
      })
  end
  local out = {}
  local seen = {}
  for i = 1, #values do
    local ok, address_or_err = Protected.pcall(Address.validate, values[i], 'resolver result')
    if not ok then
      return nil,
        HostError.protocol('resolver', 'resolve', tostring(address_or_err), {
          endpoint = endpoint,
          index = i,
        })
    end
    local address = address_or_err
    if not Address.is_numeric(address) then
      return nil,
        HostError.protocol('resolver', 'resolve', 'resolver returned an unresolved endpoint', {
          endpoint = endpoint,
          index = i,
        })
    end
    if expected_family and address.kind ~= expected_family then
      return nil,
        HostError.protocol(
          'resolver',
          'resolve_family',
          'resolver returned an address from the wrong family',
          {
            endpoint = endpoint,
            expected_family = expected_family,
            actual_family = address.kind,
            index = i,
          }
        )
    end
    local key = Address.key(address)
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = address
    end
  end
  if #out == 0 and not allow_empty then
    return nil,
      HostError.system('resolver', 'resolve', 'name resolved to no usable addresses', 'EAI_NONAME', nil, {
        endpoint = endpoint,
      })
  end
  return out
end

local function dns_options(opts, host)
  local source = type(opts.dns) == 'table' and opts.dns or opts
  local out = {}
  for key, value in pairs(source or {}) do
    out[key] = value
  end
  out.host = out.host or host
  return out
end

local function select_backend(rt, host, opts)
  if type(opts.resolver) == 'table' and type(opts.resolver.resolve) == 'function' then
    return opts.resolver, true
  end
  if type(opts.dns) == 'table' and type(opts.dns.resolve) == 'function' then
    return opts.dns, true
  end
  if opts.dns == true or type(opts.dns) == 'table' or opts.nameservers or opts.nameserver then
    return DNSResolver.new(dns_options(opts, host)), true
  end

  local capabilities = host and host.capabilities or {}
  if
    opts.dns ~= false
    and capabilities.resolver_blocking == true
    and capabilities.datagram == true
    and capabilities.socket == true
  then
    if not rt._fibers_dns_resolver or rt._fibers_dns_resolver.host ~= host then
      rt._fibers_dns_resolver = DNSResolver.new(dns_options(opts, host))
    end
    return rt._fibers_dns_resolver, false
  end
  return nil, false
end

local function host_resolve(host, endpoint, opts)
  if not host or type(host.resolve) ~= 'function' then
    return nil, HostError.unsupported('host', 'resolve', { endpoint = endpoint })
  end
  return host:resolve(endpoint, opts)
end

local function family_error(query, family, message, code)
  return HostError.system('resolver', 'resolve', message, code or 'EAI_NODATA', nil, {
    endpoint = query.endpoint,
    family = family,
  })
end

local function publish_family(rt, query, family, addresses, err)
  local completion = query.family_completions[family]
  if addresses then
    IO.masked_perform(rt, completion:publish_success_op(addresses))
  else
    IO.masked_perform(
      rt,
      completion:publish_failure_op(HostError.normalise(err, {
        domain = 'resolver',
        action = 'resolve',
        endpoint = query.endpoint,
        family = family,
      }))
    )
  end
end

local function publish_cancelled(rt, query, reason)
  local err = HostError.closed('resolver', 'resolve', {
    reason = reason,
    endpoint = query.endpoint,
  })
  for i = 1, #FAMILIES do
    local completion = query.family_completions[FAMILIES[i]]
    if completion:is_pending() then
      IO.masked_perform(rt, completion:publish_cancelled_op(err))
    end
  end
end

local function requested_families(endpoint, opts)
  local family = opts.family or endpoint.family_hint or 'unspec'
  if family == 'inet4' or family == 'inet6' then
    return { family }
  end
  return { 'inet6', 'inet4' }
end

local function mark_unrequested(rt, query, requested)
  local selected = {}
  for i = 1, #requested do
    selected[requested[i]] = true
  end
  for i = 1, #FAMILIES do
    local family = FAMILIES[i]
    if not selected[family] then
      publish_family(
        rt,
        query,
        family,
        nil,
        family_error(query, family, 'address family was not requested', 'EAI_FAMILY')
      )
    end
  end
end

local function split_families(addresses)
  local out = { inet6 = {}, inet4 = {} }
  for i = 1, #addresses do
    local address = addresses[i]
    if out[address.kind] then
      out[address.kind][#out[address.kind] + 1] = address
    end
  end
  return out
end

local function drive_combined(query, opts, rt, resolve_fn)
  local requested = requested_families(query.endpoint, opts)
  mark_unrequested(rt, query, requested)
  local addresses, err = resolve_fn()
  if not addresses then
    for i = 1, #requested do
      publish_family(rt, query, requested[i], nil, err)
    end
    return nil, err
  end
  local normalised, normalise_err = normalise_addresses(addresses, query.endpoint)
  if not normalised then
    for i = 1, #requested do
      publish_family(rt, query, requested[i], nil, normalise_err)
    end
    return nil, normalise_err
  end
  local by_family = split_families(normalised)
  local selected = {}
  for i = 1, #requested do
    local family = requested[i]
    if #by_family[family] > 0 then
      publish_family(rt, query, family, by_family[family])
      for j = 1, #by_family[family] do
        selected[#selected + 1] = by_family[family][j]
      end
    else
      publish_family(
        rt,
        query,
        family,
        nil,
        family_error(query, family, 'name resolved to no addresses in this family')
      )
    end
  end
  if #selected == 0 then
    return nil, family_error(query, requested[1], 'name resolved to no usable addresses', 'EAI_NONAME')
  end
  return selected
end

local function drive_dns(query, backend, opts, rt)
  local scope = Runtime.current_scope()
  local requested = requested_families(query.endpoint, opts)
  mark_unrequested(rt, query, requested)

  for i = 1, #requested do
    local family = requested[i]
    scope:spawn(function()
      local ok, addresses, err = Protected.pcall(function()
        return backend:resolve_family(query.endpoint, family, opts)
      end)
      if not ok then
        if Runtime.is_cancelled(addresses) then
          error(addresses, 0)
        end
        err = IO.protocol_error('resolver', 'resolve_family', addresses, {
          endpoint = query.endpoint,
          family = family,
        })
        addresses = nil
      end
      if addresses then
        local normalised, normalise_err = normalise_addresses(addresses, query.endpoint, true, family)
        addresses, err = normalised, normalise_err
      end
      publish_family(rt, query, family, addresses, err)
      return addresses, err
    end, query.name .. ':' .. family)
  end

  -- The two family completions are authoritative. The driver waits on their
  -- derived product rather than manually aggregating child-task results.
  return perform(query:result_op())
end

local function drive(query, opts)
  local rt = Runtime.current()
  local host = opts.host or (rt and rt.host)
  local backend, explicit = select_backend(rt, host, opts)

  if
    backend
    and not explicit
    and opts.require_nonblocking ~= true
    and type(backend.configuration) == 'function'
    and type(backend.has_static_name) == 'function'
    and not backend:has_static_name(query.endpoint.host)
  then
    local config = backend:configuration()
    if not config then
      backend = nil
    end
  end

  local ok, addresses, err = Protected.pcall(function()
    if backend and type(backend.resolve_family) == 'function' then
      return drive_dns(query, backend, opts, rt)
    end
    if backend then
      return drive_combined(query, opts, rt, function()
        return backend:resolve(query.endpoint, opts)
      end)
    end
    return drive_combined(query, opts, rt, function()
      return host_resolve(host, query.endpoint, opts)
    end)
  end)
  if not ok then
    if Runtime.is_cancelled(addresses) then
      error(addresses, 0)
    end
    local failure = IO.protocol_error('resolver', 'resolve', addresses, { endpoint = query.endpoint })
    for i = 1, #FAMILIES do
      local completion = query.family_completions[FAMILIES[i]]
      if completion:is_pending() then
        IO.masked_perform(rt, completion:publish_failure_op(failure))
      end
    end
    error(failure, 0)
  end
  -- The combined Query result is a projection of the two authoritative family
  -- completions. There is no third completion to publish or keep consistent.
end

function Module.resolve_op(endpoint, opts)
  opts = IO.copy_table(opts)
  endpoint = Address.validate(endpoint, 'socket.resolve_op')
  if not Address.is_name(endpoint) then
    error('socket.resolve_op expects a name endpoint', 2)
  end
  local scope = IO.current_scope(opts, 'socket.resolve_op')
  next_query = next_query + 1
  local name = opts.name or ('resolver-query-' .. tostring(next_query))
  local driver_parent = IO.require_scope(scope, 'socket.resolve_op')
  local query = setmetatable({
    kind = 'resolver_query',
    name = name,
    endpoint = endpoint,
    family_completions = {
      inet6 = Completion.new(name .. ':inet6'),
      inet4 = Completion.new(name .. ':inet4'),
    },
    driver = nil,
  }, Query)
  Lifetime.define(query, {
    name = name,
    role = 'resolver_query',
    closure = query_closure(query),
  })
  local private_scope = Scope.for_lifetime(query._lifetime)
  query.driver = Task._new(function()
    return private_scope:run(function()
      local ok, err = Protected.pcall(drive, query, opts)
      if ok then
        return
      end
      if Runtime.is_cancelled(err) then
        publish_cancelled(Runtime.current(), query, err.reason or 'resolver query cancelled')
        return
      end
      error(err, 0)
    end)
  end, name, driver_parent, { lifetime = query._lifetime, closure = driver_parent.closure })

  return scope
    :admit_op(query)
    :and_then(function()
      return query.driver:spawn_effect_op()
    end, false)
    :map(function()
      return query
    end)
end

function Query:family_addresses(family)
  return perform(self:family_addresses_op(family))
end

Query.family_ready = Query.family_addresses

function Query:family_failed(family)
  return perform(self:family_failed_op(family))
end

function Query:family_result(family)
  return perform(self:family_result_op(family))
end

function Query:family_finished(family)
  return perform(self:family_finished_op(family))
end

function Query:addresses()
  return perform(self:addresses_op())
end

function Query:failed()
  return perform(self:failed_op())
end

function Query:result()
  return perform(self:result_op())
end

function Query:close(reason)
  return perform(self:close_op(reason))
end

function Query:closed()
  return perform(self:closed_op())
end

Module.Query = Query
return Module
