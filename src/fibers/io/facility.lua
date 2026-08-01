-- Shared implementation helpers for host-backed facilities.
--
-- This module is internal. It centralises Scope resolution, structured
-- driver construction, masked option performance during short host-hold
-- intervals, and conversion of host handles into Streams.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Context = require('fibers.internal.context')
local Stream = require('fibers.io.stream')
local Task = require('fibers.task')
local Scope = require('fibers.scope')
local Lifetime = require('fibers.lifetime')
local IOError = require('fibers.io.error')
local Protected = require('fibers.protected')

local IO = {}

function IO.copy_table(value)
  local out = {}
  for key, item in pairs(value or {}) do
    out[key] = item
  end
  return out
end

function IO.scope_of(value)
  return Scope.is(value) and value or nil
end

function IO.current_scope(opts, label)
  opts = opts or {}
  local scope = opts.scope or Context.current_scope()
  if not Scope.is(scope) then
    error(label .. ' requires opts.scope or a current Scope', 3)
  end
  return scope
end

function IO.require_scope(value, label)
  return Scope.require(value, label)
end

-- Define, admit and start a domain Lifetime whose body runs in a private
-- Scope.  This is the common ownership protocol used by host-backed facilities:
-- the public value and its driver are two views of one Lifetime, and admission
-- and task start commit together.
function IO.admit_driven_lifetime_op(scope, value, spec)
  spec = spec or {}
  scope = IO.require_scope(scope, spec.label or 'driven Lifetime admission')
  if type(spec.run) ~= 'function' then
    error('driven Lifetime admission requires spec.run', 2)
  end

  Lifetime.define(value, {
    name = assert(spec.name, 'driven Lifetime admission requires spec.name'),
    role = assert(spec.role, 'driven Lifetime admission requires spec.role'),
    closure = assert(spec.closure, 'driven Lifetime admission requires spec.closure'),
    children = spec.children,
  })
  for _, state in ipairs(spec.causal_states or {}) do
    Lifetime._mark_causal_state(value, state)
  end

  local private_scope = Scope.for_lifetime(value._lifetime)
  local driver = Task._new(function()
    return private_scope:run(spec.run)
  end, spec.name, scope, { lifetime = value._lifetime, closure = scope.closure })
  value.driver = driver

  return scope:admit_op(value)
    :and_then(driver:spawn_effect_op())
    :map(function() return value end)
end


local function driver_exit_error(exit)
  if type(exit) ~= 'table' then
    return IOError.protocol('runtime', 'driver_exit', 'driver returned an invalid Exit value')
  end
  if exit.tag == 'cancelled' then
    return Runtime.cancelled(exit.reason, exit.token)
  end
  if exit.tag == 'failed' then
    return exit.error
  end
  if exit.tag ~= 'returned' then
    return IOError.protocol('runtime', 'driver_exit', 'unknown driver Exit tag', { tag = exit.tag })
  end
  return nil
end

-- A host-backed facility is closed only after both its public terminal condition
-- and the complete body of its private structured driver have settled. The body
-- ordinarily wraps a private Scope, so observing its Exit also joins all private
-- descendants. opts.require_returned preserves facilities whose driver failure
-- is not already represented by the terminal operation.
function IO.closed_after_driver_op(task, terminal_op, opts)
  if opts ~= nil and type(opts) ~= 'table' then
    error('closed_after_driver_op options must be a table', 2)
  end
  opts = opts or {}
  if opts.require_returned ~= nil and type(opts.require_returned) ~= 'boolean' then
    error('closed_after_driver_op require_returned must be boolean', 2)
  end
  if task ~= nil and type(task.body_result_op) ~= 'function' then
    error('closed_after_driver_op expects a Task-like driver', 2)
  end
  if not Op.is_op(terminal_op) then
    error('closed_after_driver_op expects a terminal Op', 2)
  end
  if task == nil then return terminal_op end

  return task:body_result_op():and_then(Op.guard(function(exit)
    if opts.require_returned == true then
      local err = driver_exit_error(exit)
      if err ~= nil then return Op.always(nil, err) end
    end
    return terminal_op
  end))
end

function IO.masked_perform(rt, option)
  return rt:_perform_current(option, nil, true)
end

function IO.close_value(domain, value, reason)
  if value and type(value.close) == 'function' then
    return value:close(reason)
  end
  return nil, IOError.unsupported(domain, 'close')
end

function IO.protocol_error(domain, action, err, fields)
  fields = fields or {}
  fields.cause = fields.cause or err
  return IOError.protocol(domain, action, tostring(err), fields)
end

function IO.safe_close(domain, value, reason, fields)
  fields = fields or {}
  local ok, closed, err = Protected.pcall(IO.close_value, domain, value, reason)
  if not ok then
    return nil, IO.protocol_error(domain, fields.action or 'close', closed, fields)
  end
  if not closed then
    return nil, IOError.normalise(err, fields)
  end
  return true
end

function IO.open_handle_stream(rt, scope, handle, opts)
  return IO.masked_perform(
    rt,
    Stream.open_op(handle, {
      scope = scope,
      name = opts.name,
      read = opts.read == true,
      write = opts.write == true,
      read_capacity = opts.read_capacity or opts.capacity,
      write_capacity = opts.write_capacity or opts.capacity,
      read_chunk_size = opts.read_chunk_size or opts.chunk_size,
      write_chunk_size = opts.write_chunk_size or opts.chunk_size,
    })
  )
end

return IO
