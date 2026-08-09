-- Shared implementation helpers for host-backed facilities.
--
-- This module is internal. It centralises Scope resolution, structured
-- driver construction, masked option performance during short host-hold
-- intervals, and conversion of host handles into Streams.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Stream = require('fibers.io.stream')
local Task = require('fibers.task')
local Scope = require('fibers.scope')
local Lifetime = require('fibers.lifetime')
local IOError = require('fibers.io.error')
local Protected = require('fibers.protected')
local Contract = require('fibers.internal.contract')

local IO = {}

function IO.copy_table(value)
  value = value == nil and {} or Contract.table(value, 'options', 2)
  local out = {}
  for key, item in pairs(value) do
    out[key] = item
  end
  return out
end

function IO.scope_of(value)
  return Scope.is(value) and value or nil
end

function IO.current_scope(opts, label)
  opts = opts == nil and {} or Contract.table(opts, (label or 'operation') .. ' options', 3)
  local scope = opts.scope or Runtime.current_scope()
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
  spec = Contract.table(spec, 'driven Lifetime admission spec', 2)
  scope = IO.require_scope(scope, spec.operation or spec.role or 'driven Lifetime admission')
  if type(spec.run) ~= 'function' then
    error('driven Lifetime admission requires spec.run', 2)
  end

  Lifetime.define(value, {
    label = spec.label,
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
  end, scope, {
    lifetime = value._lifetime,
    closure = scope._lifetime._closure,
    label = spec.label,
  })
  value._driver = driver

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
-- and the complete Lifetime of its private structured driver have settled. A
-- Task body Exit is deliberately earlier than Lifetime outcome, so closure must
-- join outcome explicitly rather than treating body_result_op as a structural
-- join. opts.require_returned preserves facilities whose driver body failure is
-- not already represented by the terminal operation.
function IO.closed_after_driver_op(task, terminal_op, opts)
  opts = Contract.options(opts, { require_returned = true }, 'closed_after_driver_op options', 2)
  Contract.optional_boolean(opts.require_returned, 'closed_after_driver_op require_returned', 2)
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
    -- Keep the driver's structural join separate from its prompt body Exit.
    -- and_then yields the terminal operation's values, preserving the public
    -- closure result while requiring the complete driver Lifetime to settle.
    return task:outcome_op():and_then(terminal_op)
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
      label = opts.label,
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
