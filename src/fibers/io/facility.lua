-- Shared implementation helpers for host-backed facilities.
--
-- This module is internal. It centralises Scope resolution, structured
-- driver construction, masked option performance during short host-setup
-- intervals, and conversion of host handles into Streams.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Stream = require('fibers.io.stream')
local Scope = require('fibers.scope')
local IOError = require('fibers.io.error')
local Protected = require('fibers.protected')
local Closure = require('fibers.closure')
local Contract = require('fibers.internal.contract')

local IO = {}

function IO.copy_table(value)
  return Contract.copy_table(value, 'options', 2)
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

local unpack_ = table.unpack or unpack

local function driver_exit_error(exit)
  if type(exit) ~= 'table' then
    return IOError.protocol('runtime', 'driver_exit', 'driver returned an invalid Exit value')
  end
  if exit.tag == 'cancelled' then return Runtime.cancelled(exit.reason, exit.token) end
  if exit.tag == 'failed' then return exit.error end
  if exit.tag ~= 'returned' then
    return IOError.protocol('runtime', 'driver_exit', 'unknown driver Exit tag', { tag = exit.tag })
  end
end

-- Wait for the complete driver Lifetime. With a terminal operation, preserve the
-- facility's domain terminal result; without one, the driver's returned values
-- are themselves authoritative.
function IO.closed_after_driver_op(task, terminal_op, opts)
  opts = Contract.options(opts, { require_returned = true }, 'closed_after_driver_op options', 2)
  Contract.optional_boolean(opts.require_returned, 'closed_after_driver_op require_returned', 2)
  if task ~= nil and type(task.body_result_op) ~= 'function' then
    error('closed_after_driver_op expects a Task-like driver', 2)
  end
  if terminal_op ~= nil and not Op.is_op(terminal_op) then
    error('closed_after_driver_op expects a terminal Op or nil', 2)
  end
  if task == nil then return terminal_op end

  return task:outcome_op():and_then(Op.guard(function(outcome)
    local report = type(outcome) == 'table' and outcome.report
    local exit = type(report) == 'table' and report.body_exit
    local err = opts.require_returned == true and driver_exit_error(exit) or nil
    if err ~= nil then return Op.always(nil, err) end
    if terminal_op ~= nil then return terminal_op end
    local values = exit and exit.values or { n = 0 }
    return Op.always(unpack_(values, 1, values.n or #values))
  end))
end

function IO.masked_perform(rt, option)
  return rt:_perform_current(option, nil, true)
end

-- Common closure protocol for host-backed values whose public contract is
-- request-close then wait until closed.  This centralises the policy while
-- leaving each facility's close/closed operations authoritative.
function IO._closeable_closure(value, opts)
  opts = Contract.options(opts, {
    name = true, reason = true, request = true, finish = true, finish_result = true,
  }, '_closeable_closure options', 2)
  local request = opts.request or 'close_op'
  local finish = opts.finish or 'closed_op'
  Contract.non_empty_string(request, '_closeable_closure request method', 2)
  Contract.non_empty_string(finish, '_closeable_closure finish method', 2)
  if opts.reason ~= nil then Contract.non_empty_string(opts.reason, '_closeable_closure reason', 2) end
  local finish_result = opts.finish_result
  if type(finish_result) == 'string' then
    finish_result = Closure.require_ok(finish_result)
  else
    Contract.optional_function(finish_result, '_closeable_closure finish_result', 2)
  end
  return Closure.request_then_wait(function(_ctx, _record, reason)
    return value[request](value, reason or opts.reason)
  end, function()
    return value[finish](value)
  end, { name = opts.name, finish_result = finish_result })
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

function IO.open_handle_stream(rt, scope, handle, opts, tuning)
  tuning = tuning or opts
  return IO.masked_perform(
    rt,
    Stream.open_op(handle, {
      scope = scope,
      label = opts.label,
      read = opts.read == true,
      write = opts.write == true,
      read_capacity = tuning.read_capacity or tuning.capacity,
      write_capacity = tuning.write_capacity or tuning.capacity,
      read_chunk_size = tuning.read_chunk_size or tuning.chunk_size,
      write_chunk_size = tuning.write_chunk_size or tuning.chunk_size,
    })
  )
end

return IO
