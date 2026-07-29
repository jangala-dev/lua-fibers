-- Shared public handle and ownership protocol for outbound socket dials.
--
-- Direct and named connection strategies differ only in how they produce a
-- connected Stream.  They share one lifecycle, one custody-transfer surface and
-- one structured driver wrapper.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local HostError = require('fibers.host.error')
local Address = require('fibers.socket.address')
local IO = require('fibers.host.io')
local DialLifecycle = require('fibers.socket.dial.lifecycle')
local Closure = require('fibers.closure')
local Protected = require('fibers.protected')
local perform = require('fibers.perform')

local Module = {}
local Dial = {}
Dial.__index = Dial

local next_dial = 0

-- Keep strategy loading lazy to avoid the socket/resolver module cycle, while
-- retaining literal require sites so portable-build dependency discovery can
-- include both strategy modules.
local function direct_strategy()
  return require('fibers.socket.dial.direct')
end

local function named_strategy()
  return require('fibers.socket.dial.named')
end

local function copy_error(err)
  if not HostError.is(err) then
    return err
  end
  local out = {}
  for key, value in pairs(err) do
    out[key] = value
  end
  return setmetatable(out, getmetatable(err))
end

local function attach_report(err, report)
  if report == nil then
    return err
  end
  local out = copy_error(err)
  if not HostError.is(out) then
    out = HostError.system('socket', 'dial', tostring(err), nil, nil)
  end
  out.report = report
  return out
end

local function dial_closure(dial)
  return Closure.request_then_wait(function(_ctx, _record, reason)
    return dial:close_op(reason or 'scope closure')
  end, function()
    return dial:closed_op()
  end, {
    name = 'dial',
    finish_result = Closure.require_ok('dial closure failed'),
  })
end

local function closed_result(state)
  if state.fatal and state.error then
    return nil, state.error
  end
  return true
end

local function terminal_fields(dial)
  return {
    endpoint = dial.endpoint,
    address = dial.endpoint,
    strategy = dial.strategy,
  }
end

local function cancelled_error(dial, err)
  local fields = terminal_fields(dial)
  fields.reason = err.reason or 'dial cancelled'
  return HostError.closed('socket', 'dial', fields)
end

local function unexpected_error(dial, err)
  if HostError.is(err) then
    return err, false
  end
  return IO.protocol_error('socket', 'dial_driver', err, terminal_fields(dial)), true
end

local function driver(dial, driver_scope)
  local rt = Runtime.current()
  local ok, connection, err, report = Protected.pcall(dial._strategy.run, dial, driver_scope, dial._options)

  if not ok then
    local thrown = connection
    if Runtime.is_cancelled(thrown) then
      local closed = cancelled_error(dial, thrown)
      local cancelled_report = dial._strategy.terminal_report
          and dial._strategy.terminal_report(dial, 'cancelled', closed, rt:now())
        or nil
      IO.masked_perform(
        rt,
        dial.lifecycle:closed_op(
          thrown.reason or 'dial cancelled',
          attach_report(closed, cancelled_report),
          false,
          cancelled_report
        )
      )
      return
    end

    local failure, fatal = unexpected_error(dial, thrown)
    local failure_report = dial._strategy.terminal_report
        and dial._strategy.terminal_report(dial, 'failed', failure, rt:now())
      or nil
    failure = attach_report(failure, failure_report)
    local state = dial.lifecycle:state_value()
    if state.kind == 'closing' then
      IO.masked_perform(rt, dial.lifecycle:closed_op(state.reason, failure, fatal, failure_report))
    else
      IO.masked_perform(rt, dial.lifecycle:publish_failure_op(failure, fatal, failure_report))
    end
    return
  end

  if not connection then
    err = attach_report(err, report)
    local state = dial.lifecycle:state_value()
    if state.kind == 'closing' then
      IO.masked_perform(rt, dial.lifecycle:closed_op(state.reason, err, false, report))
    else
      IO.masked_perform(rt, dial.lifecycle:publish_failure_op(err, false, report))
    end
    return
  end

  local published, state =
    IO.masked_perform(rt, dial.lifecycle:publish_connected_op(connection, driver_scope, report))
  if not published then
    if state.kind == 'closing' or state.kind == 'closed' then
      return
    end
    error(
      HostError.protocol('socket', 'publish_connected', 'Dial lifecycle rejected a connection', {
        endpoint = dial.endpoint,
        strategy = dial.strategy,
        state = state.kind,
      }),
      0
    )
  end

  -- Keep the private scope, and therefore an untaken winning Stream, alive until
  -- custody moves to the caller or the Dial closes.
  local released, release_state = Protected.pcall(perform, dial.lifecycle:driver_release_op())
  if not released then
    if Runtime.is_cancelled(release_state) then
      local state_now = dial.lifecycle:state_value()
      local closed = cancelled_error(dial, release_state)
      local cancelled_report = state_now.report
        or (
          dial._strategy.terminal_report
          and dial._strategy.terminal_report(dial, 'cancelled', closed, rt:now())
        )
      IO.masked_perform(
        rt,
        dial.lifecycle:closed_op(
          release_state.reason or state_now.reason or 'dial cancelled',
          attach_report(closed, cancelled_report),
          false,
          cancelled_report
        )
      )
      return
    end
    error(release_state, 0)
  end
  if release_state.kind == 'closing' then
    IO.masked_perform(rt, dial.lifecycle:closed_op(release_state.reason, nil, false, release_state.report))
  end
end

function Dial:lifetime()
  return self._lifetime
end

function Dial:state_op()
  return self.lifecycle:state_op()
end

function Dial:state_value()
  return self.lifecycle:state_value()
end

local function take_to_scope_op(dial, scope, include_report)
  return dial.lifecycle:take_op():and_then(function(connection, source_scope, report)
    return source_scope:move_op(connection, scope):map(function()
      if include_report then
        return connection, report
      end
      return connection
    end)
  end)
end

local function transfer_op(dial, target, include_report)
  return IO.with_target_scope_op(
    target,
    'Dial connection transfer expects a target Scope, or a current Scope',
    function(scope)
      return take_to_scope_op(dial, scope, include_report)
    end
  )
end

function Dial:connected_op(target)
  return transfer_op(self, target, false)
end

function Dial:failed_op()
  return self.lifecycle:failure_op()
end

function Dial:result_op(target)
  return self:connected_op(target):or_else(self:failed_op():map(function(err)
    return nil, err
  end))
end

local function result_with_report_op(dial, target)
  return transfer_op(dial, target, true):or_else(dial:failed_op():map(function(err)
    return nil, err
  end))
end

function Dial:report_op()
  return self.lifecycle:report_op()
end

function Dial:close_op(reason)
  reason = reason or 'dial closed'
  local cancel = self.driver and self.driver:request_cancel_op(reason) or Op.always(true)
  return self.lifecycle:request_close_op(reason):and_then(function(first)
    if first and self.driver then
      return cancel:map(function()
        return true
      end)
    end
    return Op.always(true)
  end, Op.dependencies(cancel))
end

function Dial:closed_op()
  return IO.closed_after_driver_op(self.driver, self.lifecycle:terminal_op():map(closed_result))
end

function Dial:result(target)
  return perform(self:result_op(target))
end

-- Strong convenience: a returned connection has moved to the target and every
-- losing descendant of the selected strategy has closed.
function Dial:connect(target)
  local connection, result = perform(result_with_report_op(self, target))
  local closed, close_err = self:closed()
  if not closed then
    if connection and type(connection.abort) == 'function' then
      Protected.pcall(connection.abort, connection, close_err or 'Dial closure failed')
    end
    return nil, close_err
  end
  return connection, result
end

function Dial:report()
  return perform(self:report_op())
end

function Dial:close(reason)
  return perform(self:close_op(reason))
end

function Dial:closed()
  return perform(self:closed_op())
end

local function new_op(endpoint, opts, strategy)
  opts = opts or {}
  local scope = IO.current_scope(opts, 'socket.dial_op')
  next_dial = next_dial + 1
  local name = opts.name or ('dial-' .. tostring(next_dial))
  local dial = setmetatable({
    kind = 'socket_dial',
    name = name,
    endpoint = endpoint,
    strategy = strategy.name,
    lifecycle = DialLifecycle.new(name, endpoint),
    _strategy = strategy,
    _options = opts,
  }, Dial)

  return IO.admit_driven_lifetime_op(scope, dial, {
    label = 'socket.dial_op',
    name = name,
    role = 'socket_dial',
    closure = dial_closure(dial),
    causal_states = { dial.lifecycle.state },
    run = function(driver_scope)
      return driver(dial, driver_scope)
    end,
  })
end

function Module.dial_op(endpoint, opts)
  endpoint = Address.validate(endpoint, 'socket.dial_op')
  local strategy = Address.is_name(endpoint) and named_strategy() or direct_strategy()
  return new_op(endpoint, strategy.normalise_options(opts, endpoint), strategy)
end

Module.Dial = Dial
return Module
