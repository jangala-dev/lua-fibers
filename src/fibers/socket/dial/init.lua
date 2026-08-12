-- Shared public handle and ownership protocol for outbound socket dials.
--
-- Direct and named connection strategies differ only in how they produce a
-- connected Stream.  They share one lifecycle, one custody-transfer surface and
-- one structured driver wrapper.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local IOError = require('fibers.io.error')
local Address = require('fibers.net.address')
local IO = require('fibers.io.facility')
local DialLifecycle = require('fibers.socket.dial.lifecycle')
local Protected = require('fibers.protected')
local perform = require('fibers.perform')
local Direct = require('fibers.internal.direct')
local Label = require('fibers.internal.label')

local Module = {}
local Dial = {}
Dial.__index = Dial

-- Keep strategy loading lazy to avoid the socket/resolver module cycle, while
-- retaining literal require sites so portable-build dependency discovery can
-- include both strategy modules.
local function direct_strategy()
  return require('fibers.socket.dial.direct')
end

local function named_strategy()
  return require('fibers.socket.dial.named')
end

local function attach_report(err, report)
  if report == nil then return err end
  local out = IOError.copy(err)
  if not IOError.is(out) then
    out = IOError.system('socket', 'dial', tostring(err), nil, nil)
  end
  out.report = report
  return out
end

local function closed_result(state)
  if state.fatal and state.error then return nil, state.error end
  return true
end

local function terminal_fields(dial)
  return {
    endpoint = dial._endpoint,
    address = dial._endpoint,
    strategy = dial._strategy.name,
  }
end

local function cancelled_error(dial, err)
  local fields = terminal_fields(dial)
  fields.reason = err.reason or 'dial cancelled'
  return IOError.closed('socket', 'dial', fields)
end

local function unexpected_error(dial, err)
  if IOError.is(err) then return err, false end
  return IO.protocol_error('socket', 'dial_driver', err, terminal_fields(dial)), true
end

local function publish_failure(dial, rt, err, fatal, report)
  err = attach_report(err, report)
  local state = dial._lifecycle._location.value
  local op
  if state.kind == 'closing' then
    op = dial._lifecycle:closed_op(state.reason, err, fatal, report)
  else
    op = dial._lifecycle:publish_failure_op(err, fatal, report)
  end
  IO.masked_perform(rt, op)
end

local function publish_cancelled(dial, rt, cancellation)
  local state = dial._lifecycle._location.value
  local closed = cancelled_error(dial, cancellation)
  local report = state.report
    or dial._strategy.terminal_report(dial, 'cancelled', closed, rt:now())
  IO.masked_perform(
    rt,
    dial._lifecycle:closed_op(
      cancellation.reason or state.reason or 'dial cancelled',
      attach_report(closed, report),
      false,
      report
    )
  )
end

local function driver(dial, driver_scope)
  local rt = Runtime.current()
  local ok, connection, err, report = Protected.pcall(dial._strategy.run, dial, driver_scope, dial._options)

  if not ok then
    local thrown = connection
    if Runtime.is_cancelled(thrown) then
      publish_cancelled(dial, rt, thrown)
      return
    end

    local failure, fatal = unexpected_error(dial, thrown)
    local failure_report = dial._strategy.terminal_report(dial, 'failed', failure, rt:now())
    publish_failure(dial, rt, failure, fatal, failure_report)
    -- The lifecycle publication gives observers a deterministic domain result;
    -- an unexpected adapter/strategy defect is also an execution failure of
    -- the Dial Task and must remain visible to its custodian's supervision.
    if fatal then error(failure, 0) end
    return
  end

  if not connection then
    publish_failure(dial, rt, err, false, report)
    return
  end

  local published, state =
    IO.masked_perform(rt, dial._lifecycle:publish_connected_op(connection, driver_scope, report))
  if not published then
    if state.kind == 'closing' or state.kind == 'closed' then return end
    error(
      IOError.protocol('socket', 'publish_connected', 'Dial lifecycle rejected a connection', {
        endpoint = dial._endpoint,
        strategy = dial._strategy.name,
        state = state.kind,
      }),
      0
    )
  end

  -- Keep the private scope, and therefore an untaken winning Stream, alive until
  -- custody moves to the caller or the Dial closes.
  local released, release_state = Protected.pcall(perform, dial._lifecycle:driver_release_op())
  if not released then
    if Runtime.is_cancelled(release_state) then
      publish_cancelled(dial, rt, release_state)
      return
    end
    error(release_state, 0)
  end
  if release_state.kind == 'closing' then
    IO.masked_perform(rt, dial._lifecycle:closed_op(release_state.reason, nil, false, release_state.report))
  end
end

function Dial:lifetime()
  return self._lifetime
end

local function take_to_scope_op(dial, scope, include_report)
  return dial._lifecycle:take_op():and_then(Op.guard(function(connection, source_scope, report)
    return source_scope:move_op(connection, scope):map(function()
      if include_report then return connection, report end
      return connection
    end)
  end))
end

local function transfer_op(dial, target, include_report)
  return take_to_scope_op(dial, IO.require_scope(target, 'Dial connection transfer target'), include_report)
end

function Dial:connected_op(target)
  return transfer_op(self, target, false)
end

function Dial:failed_op()
  return self._lifecycle:failure_op()
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
  return self._lifecycle:report_op()
end

function Dial:request_close_op(reason)
  reason = reason or 'dial closed'
  return self._lifecycle:request_close_op(reason):and_then(Op.guard(function(first)
    if first and self._driver then
      return self._driver:request_cancel_op(reason):map(function() return true end)
    end
    return Op.always(true)
  end))
end

function Dial:closed_op()
  return IO.closed_after_driver_op(self._driver, self._lifecycle:terminal_op():map(closed_result))
end

function Dial:close(reason)
  local requested, request_err = perform(self:request_close_op(reason))
  if not requested then return nil, request_err end
  return perform(self:closed_op())
end

function Dial:result(target)
  target = target or IO.current_scope({}, 'Dial:result')
  return perform(self:result_op(target))
end

-- Strong convenience: a returned connection has moved to the target and every
-- losing descendant of the selected strategy has closed.
function Dial:connect(target)
  target = target or IO.current_scope({}, 'Dial:connect')
  local connection, result = perform(result_with_report_op(self, target))
  local closed, close_err = self:closed()
  if closed and self._driver then
    -- Dial:closed() establishes the local protocol state. connect() has the
    -- stronger documented contract that every losing private descendant has
    -- retired before the winning connection escapes, so ask explicitly for
    -- the complete Dial Lifetime here rather than making every local
    -- closed_op circular with its own Lifetime.
    local retired, retire_err = Protected.pcall(self._driver.await, self._driver)
    if not retired then
      closed, close_err = nil, retire_err
    end
  end
  if not closed then
    if connection and type(connection.abort) == 'function' then
      local cleanup = {}
      IOError.capture_cleanup(cleanup, 'socket', 'dial_cleanup', nil,
        connection.abort, connection, close_err or 'Dial closure failed')
      close_err = IOError.with_cleanup(close_err, 'socket', 'dial_close',
        'Dial closure and returned-connection cleanup both failed', cleanup)
    end
    return nil, close_err
  end
  return connection, result
end




local function new_op(endpoint, opts, strategy)
  local scope = IO.current_scope(opts, 'socket.dial_op')
  local dial = Label.attach(Label.identity(setmetatable({
    kind = 'socket_dial',
    _endpoint = endpoint,
    _lifecycle = DialLifecycle.new(endpoint),
    _strategy = strategy,
    _options = opts,
  }, Dial), 'dial'), opts.label)
  Label.child(dial._lifecycle, dial, 'lifecycle')

  return scope:_drive_op( dial, {
    label = Label.get(dial),
    role = 'socket_dial',
    closure = IO._closeable_closure(dial, {
      name = 'dial', reason = 'scope closure', finish_result = 'dial closure failed',
    }),
    causal_states = { dial._lifecycle },
    run = function(driver_scope) return driver(dial, driver_scope) end,
  })
end

function Module.dial_op(endpoint, opts)
  endpoint = Address.validate(endpoint, 'socket.dial_op')
  local strategy = Address.is_name(endpoint) and named_strategy() or direct_strategy()
  return new_op(endpoint, strategy.normalise_options(opts, endpoint), strategy)
end

Module.Dial = Dial
Direct.install(Dial, { 'report', 'request_close', 'closed' })

return Module
