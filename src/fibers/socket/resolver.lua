-- Asynchronous resolver queries as running Lifetimes.
--
-- The host decides how resolution is performed. A simple host may execute a
-- blocking resolver call in the committed driver fiber and advertises that fact
-- through its capability table; embedded hosts may provide a worker or native
-- asynchronous resolver instead.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Address = require('fibers.net.address')
local Completion = require('fibers.resource.completion')
local IOError = require('fibers.io.error')
local DNSResolver = require('fibers.dns.resolver')
local IO = require('fibers.io.facility')
local Protected = require('fibers.protected')
local Closure = require('fibers.closure')
local perform = require('fibers.perform')
local Direct = require('fibers.internal.direct')
local Label = require('fibers.internal.label')

local Module = {}
local Query = {}
Query.__index = Query
local next_query = 0

local SOCKET_RESOLVE_OPTIONS = { scope = true, resolver = true, dns = true }

local function resolver_object(value)
  return type(value) == 'table'
    and (type(value.resolve) == 'function' or type(value.resolve_family) == 'function')
end

local function validate_resolve_options(value)
  local opts = DNSResolver.validate_options(value, SOCKET_RESOLVE_OPTIONS, 'socket.resolve_op options')
  if opts.resolver ~= nil and not resolver_object(opts.resolver) then
    error('socket.resolve_op opts.resolver must provide resolve() or resolve_family()', 3)
  end
  if opts.dns ~= nil and type(opts.dns) ~= 'boolean' and type(opts.dns) ~= 'table' then
    error('socket.resolve_op opts.dns must be a boolean, resolver object or DNS option table', 3)
  end
  if type(opts.dns) == 'table' and not resolver_object(opts.dns) then
    DNSResolver.validate_constructor_options(opts.dns)
  end
  return opts
end

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

local function family_completion(query, family)
  if family ~= 'inet4' and family ~= 'inet6' then
    error('resolver family must be inet4 or inet6', 3)
  end
  return query._family_completions[family]
end

function Query:family_addresses_op(family)
  return family_completion(self, family):success_op()
end


function Query:family_failed_op(family)
  return family_completion(self, family):failure_op()
end

function Query:family_result_op(family)
  return family_completion(self, family):result_op()
end

function Query:family_finished_op(family)
  return family_completion(self, family):terminal_op()
end


function Query:_families_op()
  return Op.named_each({
    inet6 = self:family_finished_op('inet6'),
    inet4 = self:family_finished_op('inet4'),
  })
end

local function combine_family_states(query, families)
  local addresses, first_error, preferred_error = {}, nil, nil
  for i = 1, #FAMILIES do
    local family = FAMILIES[i]
    local state = families[family]
    local values = state.kind == 'succeeded' and state.values[1] or nil
    if values then
      for j = 1, #values do
        addresses[#addresses + 1] = values[j]
      end
    elseif state.kind == 'failed' then
      first_error = first_error or state.error
      if not preferred_error and (type(state.error) ~= 'table' or state.error.code ~= 'EAI_FAMILY') then
        preferred_error = state.error
      end
    elseif state.kind == 'cancelled' then
      first_error = first_error or state.reason
      preferred_error = preferred_error or state.reason
    end
  end
  if #addresses > 0 then
    return addresses
  end
  return nil,
    preferred_error or first_error or IOError.system(
      'resolver',
      'resolve',
      'name resolved to no usable addresses',
      'EAI_NONAME',
      nil,
      { endpoint = query._endpoint }
    )
end

function Query:result_op()
  return self:_families_op():map(function(families)
    return combine_family_states(self, families)
  end)
end

function Query:addresses_op()
  return self:result_op():and_then(Op.guard(function(addresses)
    if addresses then
      return Op.always(addresses)
    end
    return Op.never()
  end))
end

function Query:failed_op()
  return self:result_op():and_then(Op.guard(function(addresses, err)
    if not addresses then
      return Op.always(err)
    end
    return Op.never()
  end))
end

function Query:close_op(reason)
  reason = reason or 'resolver query closed'
  local cancel = self._driver and self._driver:request_cancel_op(reason) or Op.always(true)
  local err = IOError.closed('resolver', 'resolve', {
    reason = reason,
    endpoint = self._endpoint,
  })
  local publishes = {}
  for i = 1, #FAMILIES do
    publishes[#publishes + 1] = self._family_completions[FAMILIES[i]]:publish_cancelled_op(err)
  end
  return cancel:and_then(Op.each(publishes):map(function()
      return true
    end))
end

function Query:closed_op()
  local terminal = self:_families_op():map(function()
    return true
  end)
  return IO.closed_after_driver_op(self._driver, terminal)
end

local function normalise_addresses(values, endpoint, allow_empty, expected_family)
  if type(values) ~= 'table' then
    return nil,
      IOError.protocol('resolver', 'resolve', 'host resolver must return an address list', {
        endpoint = endpoint,
      })
  end
  local out = {}
  local seen = {}
  for i = 1, #values do
    local ok, address_or_err = Protected.pcall(Address.validate, values[i], 'resolver result')
    if not ok then
      return nil,
        IOError.protocol('resolver', 'resolve', tostring(address_or_err), {
          endpoint = endpoint,
          index = i,
        })
    end
    local address = address_or_err
    if not Address.is_numeric(address) then
      return nil,
        IOError.protocol('resolver', 'resolve', 'resolver returned an unresolved endpoint', {
          endpoint = endpoint,
          index = i,
        })
    end
    if expected_family and address.kind ~= expected_family then
      return nil,
        IOError.protocol(
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
      IOError.system('resolver', 'resolve', 'name resolved to no usable addresses', 'EAI_NONAME', nil, {
        endpoint = endpoint,
      })
  end
  return out
end

local function dns_options(opts, host)
  local source = type(opts.dns) == 'table' and opts.dns or opts
  local out = DNSResolver.project_constructor_options(source)
  if out.host == nil then out.host = host end
  return out
end

local function select_backend(rt, host, opts)
  if resolver_object(opts.resolver) then return opts.resolver end
  if resolver_object(opts.dns) then return opts.dns end
  if opts.dns == true or type(opts.dns) == 'table' or opts.nameservers then
    return DNSResolver.new(dns_options(opts, host))
  end

  local function feature(name) return host and type(host.feature) == 'function' and host:feature(name) end
  if
    opts.dns ~= false
    and feature('resolver_blocking') == true
    and feature('datagram') == true
    and feature('socket') == true
  then
    if not rt._fibers_dns_resolver or rt._fibers_dns_resolver.host ~= host then
      rt._fibers_dns_resolver = DNSResolver.new(dns_options(opts, host))
    end
    return rt._fibers_dns_resolver
  end
  return nil
end

local function host_resolve(host, endpoint, opts)
  if not host or type(host.resolve) ~= 'function' then
    return nil, IOError.unsupported('host', 'resolve', { endpoint = endpoint })
  end
  return host:resolve(endpoint, opts)
end

local function family_error(query, family, message, code)
  return IOError.system('resolver', 'resolve', message, code or 'EAI_NODATA', nil, {
    endpoint = query._endpoint,
    family = family,
  })
end

local function publish_family(rt, query, family, addresses, err)
  local completion = query._family_completions[family]
  if addresses then
    IO.masked_perform(rt, completion:publish_success_op(addresses))
  else
    IO.masked_perform(
      rt,
      completion:publish_failure_op(IOError.normalise(err, {
        domain = 'resolver',
        action = 'resolve',
        endpoint = query._endpoint,
        family = family,
      }))
    )
  end
end

local function publish_cancelled(rt, query, reason)
  local err = IOError.closed('resolver', 'resolve', {
    reason = reason,
    endpoint = query._endpoint,
  })
  for i = 1, #FAMILIES do
    local completion = query._family_completions[FAMILIES[i]]
    if completion:_is_pending() then
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
  if #requested == 2 then return end
  local family = requested[1] == 'inet4' and 'inet6' or 'inet4'
  publish_family(
    rt, query, family, nil,
    family_error(query, family, 'address family was not requested', 'EAI_FAMILY')
  )
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
  local requested = requested_families(query._endpoint, opts)
  mark_unrequested(rt, query, requested)
  local addresses, err = resolve_fn()
  if not addresses then
    for i = 1, #requested do publish_family(rt, query, requested[i], nil, err) end
    return
  end

  local normalised, normalise_err = normalise_addresses(addresses, query._endpoint)
  if not normalised then
    for i = 1, #requested do publish_family(rt, query, requested[i], nil, normalise_err) end
    return
  end

  local by_family = split_families(normalised)
  for i = 1, #requested do
    local family = requested[i]
    if #by_family[family] > 0 then
      publish_family(rt, query, family, by_family[family])
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
end

local function drive_dns(query, backend, opts, rt)
  local scope = Runtime.current_scope()
  local requested = requested_families(query._endpoint, opts)
  mark_unrequested(rt, query, requested)

  for i = 1, #requested do
    local family = requested[i]
    scope:spawn(function()
      local backend_opts = DNSResolver.is(backend) and DNSResolver.project_query_options(opts) or opts
      local ok, addresses, err = Protected.pcall(
        backend.resolve_family, backend, query._endpoint, family, backend_opts
      )
      if not ok then
        if Runtime.is_cancelled(addresses) then
          error(addresses, 0)
        end
        err = IO.protocol_error('resolver', 'resolve_family', addresses, {
          endpoint = query._endpoint,
          family = family,
        })
        addresses = nil
      end
      if addresses then
        local normalised, normalise_err = normalise_addresses(addresses, query._endpoint, true, family)
        addresses, err = normalised, normalise_err
      end
      publish_family(rt, query, family, addresses, err)
      return
    end):label(Label.describe(query, query._fibers_id) .. ':' .. family)
  end

  -- The two family completions are authoritative. The driver waits on their
  -- derived product rather than manually aggregating child-task results.
  perform(query:result_op())
end

local function drive(query, opts)
  local rt = Runtime.current()
  local ok, thrown = Protected.pcall(function()
    local host = opts.host or rt.host
    local backend = select_backend(rt, host, opts)
    if backend and type(backend.resolve_family) == 'function' then
      drive_dns(query, backend, opts, rt)
    elseif backend then
      drive_combined(query, opts, rt, function()
        return backend:resolve(query._endpoint, opts)
      end)
    else
      drive_combined(query, opts, rt, function()
        return host_resolve(host, query._endpoint, opts)
      end)
    end
  end)
  if ok then return end
  if Runtime.is_cancelled(thrown) then
    publish_cancelled(rt, query, thrown.reason or 'resolver query cancelled')
    return
  end
  local failure = IO.protocol_error('resolver', 'resolve', thrown, { endpoint = query._endpoint })
  for i = 1, #FAMILIES do
    local completion = query._family_completions[FAMILIES[i]]
    if completion:_is_pending() then
      IO.masked_perform(rt, completion:publish_failure_op(failure))
    end
  end
  error(failure, 0)
end

function Module.resolve_op(endpoint, opts)
  opts = validate_resolve_options(opts)
  endpoint = Address.validate(endpoint, 'socket.resolve_op')
  if not Address.is_name(endpoint) then
    error('socket.resolve_op expects a name endpoint', 2)
  end
  local scope = IO.current_scope(opts, 'socket.resolve_op')
  next_query = next_query + 1
  local id = 'resolver-query-' .. tostring(next_query)
  local query = Label.attach(setmetatable({
    kind = 'resolver_query',
    _fibers_id = id,
    _endpoint = endpoint,
    _family_completions = {
      inet6 = Completion.new(),
      inet4 = Completion.new(),
    },
  }, Query), opts.label)
  Label.child(query._family_completions.inet6, query, 'inet6')
  Label.child(query._family_completions.inet4, query, 'inet4')

  return IO.admit_driven_lifetime_op(scope, query, {
    operation = 'socket.resolve_op',
    label = Label.get(query),
    role = 'resolver_query',
    closure = query_closure(query),
    causal_states = {
      query._family_completions.inet6.state,
      query._family_completions.inet4.state,
    },
    run = function() return drive(query, opts) end,
  })
end










Module.Query = Query
Direct.install(Query, { 'family_addresses', 'family_failed', 'family_result', 'family_finished', 'addresses', 'failed', 'result', 'close', 'closed' })

return Module
