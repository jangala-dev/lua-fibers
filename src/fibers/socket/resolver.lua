-- Owned asynchronous resolver queries.
--
-- The host decides how resolution is performed. A simple host may execute a
-- blocking resolver call in the committed driver fibre and advertises that fact
-- through its capability table; embedded hosts may provide a worker or native
-- asynchronous resolver instead.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Address = require('fibers.socket.address')
local Completion = require('fibers.internal.completion')
local HostError = require('fibers.host.error')
local IO = require('fibers.internal.io')
local Ownership = require('fibers.internal.ownership')
local Owned = require('fibers.lifetime.region').Owned
local Protected = require('fibers.internal.protected')
local Settlement = require('fibers.internal.settlement')
local perform = require('fibers.perform')

local Module = {}
local Query = {}
Query.__index = Query
local next_query = 0

local function query_settlement(query)
  return Settlement.request_then_wait(
    function(_ctx, _record, reason)
      return query:close_op(reason or 'resolver query settlement')
    end,
    function()
      return query:closed_op()
    end
  )
end

function Query:owned(children)
  return Owned.tree(self, self._fibers_settle, children or {}, {
    role = 'resolver_query',
    settle_name = 'resolver_query',
  })
end

function Query:addresses_op()
  return self.completion:success_op()
end

function Query:failed_op()
  return self.completion:failure_op()
end

function Query:result_op()
  return self:addresses_op():or_else(self:failed_op():map(function(err)
    return nil, err
  end))
end

function Query:state_op()
  return self.completion:terminal_op()
end

function Query:close_op(reason)
  reason = reason or 'resolver query closed'
  local cancel = self.driver and self.driver:request_cancel_op(reason) or Op.always(true)
  return cancel:and_then(function()
    return self.completion:publish_cancelled_op(HostError.closed('resolver', 'resolve', {
      reason = reason,
      endpoint = self.endpoint,
    }))
  end, false):map(function()
    return true
  end)
end

function Query:closed_op()
  local joined = self.driver and self.driver:exit_op() or Op.always(true)
  return joined:and_then(function()
    return self.completion:terminal_op():map(function()
      return true
    end)
  end)
end

local function normalise_addresses(values, endpoint)
  if type(values) ~= 'table' then
    return nil, HostError.protocol('resolver', 'resolve', 'host resolver must return an address list', {
      endpoint = endpoint,
    })
  end
  local out = {}
  local seen = {}
  for i = 1, #values do
    local ok, address_or_err = Protected.pcall(Address.validate, values[i], 'resolver result')
    if not ok then
      return nil, HostError.protocol('resolver', 'resolve', tostring(address_or_err), {
        endpoint = endpoint,
        index = i,
      })
    end
    local address = address_or_err
    if not Address.is_numeric(address) then
      return nil, HostError.protocol('resolver', 'resolve', 'resolver returned an unresolved endpoint', {
        endpoint = endpoint,
        index = i,
      })
    end
    local key = Address.key(address)
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = address
    end
  end
  if #out == 0 then
    return nil, HostError.system('resolver', 'resolve', 'name resolved to no usable addresses', 'EAI_NONAME', nil, {
      endpoint = endpoint,
    })
  end
  return out
end

local function drive(query, opts)
  local rt = Runtime.current()
  local host = opts.host or (rt and rt.host)
  if not host or type(host.resolve) ~= 'function' then
    IO.masked_perform(rt, query.completion:publish_failure_op(HostError.unsupported('host', 'resolve', {
      endpoint = query.endpoint,
    })))
    return
  end

  local ok, addresses, err = Protected.pcall(function()
    return host:resolve(query.endpoint, opts)
  end)
  if not ok then
    local failure = IO.protocol_error('resolver', 'resolve', addresses, { endpoint = query.endpoint })
    IO.masked_perform(rt, query.completion:publish_failure_op(failure))
    error(failure, 0)
  end
  if not addresses then
    IO.masked_perform(rt, query.completion:publish_failure_op(HostError.normalise(err, {
      domain = 'resolver',
      action = 'resolve',
      endpoint = query.endpoint,
    })))
    return
  end
  local normalised, normalise_err = normalise_addresses(addresses, query.endpoint)
  if not normalised then
    IO.masked_perform(rt, query.completion:publish_failure_op(normalise_err))
    return
  end
  IO.masked_perform(rt, query.completion:publish_success_op(normalised))
end

function Module.resolve_op(endpoint, opts)
  opts = IO.copy_table(opts)
  endpoint = Address.validate(endpoint, 'socket.resolve_op')
  if not Address.is_name(endpoint) then
    error('socket.resolve_op expects a name endpoint', 2)
  end
  local owner = IO.current_owner(opts, 'socket.resolve_op')
  next_query = next_query + 1
  local name = opts.name or ('resolver-query-' .. tostring(next_query))
  local query = Ownership.handle(name, {
    kind = 'resolver_query',
    endpoint = endpoint,
    completion = Completion.new(name .. ':completion'),
    driver = nil,
  })
  setmetatable(query, Query)
  query._fibers_settle = query_settlement(query)
  query._fibers_settle_name = 'resolver_query'

  local driver_parent = IO.scope_for_owner(owner, 'socket.resolve_op')
  query.driver = IO.new_driver_task(driver_parent, name .. ':driver', function()
    local ok, err = Protected.pcall(drive, query, opts)
    if ok then
      return
    end
    if Runtime.is_cancelled(err) then
      local rt = Runtime.current()
      if query.completion:is_pending() then
        IO.masked_perform(rt, query.completion:publish_cancelled_op(HostError.closed('resolver', 'resolve', {
          reason = err.reason or 'resolver query cancelled',
          endpoint = endpoint,
        })))
      end
      return
    end
    error(err, 0)
  end)

  return owner
    :admit_op(query:owned({ query.driver:owned() }))
    :and_then(function()
      return query.driver:spawn_effect_op()
    end, false)
    :map(function()
      return query
    end)
end

function Query:addresses() return perform(self:addresses_op()) end

function Query:failed() return perform(self:failed_op()) end

function Query:result() return perform(self:result_op()) end

function Query:close(reason) return perform(self:close_op(reason)) end

function Query:closed() return perform(self:closed_op()) end

Module.Query = Query
return Module
