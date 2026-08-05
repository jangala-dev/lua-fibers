-- Fibre scheduler and public execution boundary.

local Op = require('fibers.op')
local Values = require('fibers.internal.values')
local Protected = require('fibers.internal.protected')
local Context = require('fibers.internal.context')
local Engine = require('fibers.internal.engine')
local Execution = require('fibers.internal.execution')
local Label = require('fibers.internal.label')

local function require_optional(module_name, feature)
  local ok, module = pcall(require, module_name)
  if ok then return module end
  error((feature or module_name) .. ' requires optional package module ' .. module_name .. ': ' .. tostring(module), 3)
end

-- Internal perform-boundary interruption tokens.
local InterruptToken = {}
InterruptToken.__index = InterruptToken
function InterruptToken:is_raised()
  return self.raised == true
end

local function new_interrupt(name)
  return setmetatable({
    name = name or 'interrupt',
    version = 0,
    raised = false,
    reason = nil,
    _fibers_interrupt = true,
  }, InterruptToken)
end

local function raise_interrupt(token, reason)
  if type(token) ~= 'table' or token._fibers_interrupt ~= true then
    error('raise_interrupt expects an interrupt token', 2)
  end
  token.raised = true
  token.reason = reason
  token.version = (token.version or 0) + 1
  return true
end

local Runtime = {}
local PERFORM_YIELD = {}
local next_runtime_id = 0

Runtime.__index = Runtime
function Runtime.current()
  return Context.current_runtime()
end
function Runtime.current_scope()
  return Context.current_scope()
end

local unpack_ = table.unpack or unpack
local pack_ = Values.pack
local function unpack_pack(p)
  return unpack_(p, 1, p.n or #p)
end

local Cancellation = {}
Cancellation.__index = Cancellation
Cancellation.__tostring = function(e)
  return e.message or 'fiber cancelled'
end
function Runtime.cancelled(reason, token)
  return setmetatable({
    _fibers_cancelled = true,
    reason = reason,
    token = token,
    message = reason and tostring(reason) or 'fiber cancelled',
  }, Cancellation)
end
function Runtime.is_cancelled(e)
  return type(e) == 'table' and e._fibers_cancelled == true
end

local RuntimeError = {}
RuntimeError.__index = RuntimeError
RuntimeError.__tostring = function(e)
  return e.message or tostring(e.cause)
end

function Runtime:_make_error(kind, err, fields)
  fields = fields or {}
  local out = {
    _fibers_error = true,
    kind = kind,
    phase = fields.phase or self._phase,
    action = fields.action,
    committed = fields.committed,
    message = fields.message or tostring(err),
    cause = err,
  }
  for key, value in pairs(fields) do
    if out[key] == nil then out[key] = value end
  end
  return setmetatable(out, RuntimeError)
end

function Runtime:_fail(kind, err, fields)
  local e = self:_make_error(kind, err, fields)
  error(e, fields and fields.level or 0)
end

function Runtime:_fatal(kind, err, fields)
  fields = fields or {}
  local e = self:_make_error(kind, err, fields)
  e.fatal = true
  self._failed = e
  error(e, fields.level or 0)
end

function Runtime:failed()
  return self._failed
end
function Runtime:_check_not_failed(level)
  if self._failed then
    error(self._failed, level or 0)
  end
end

function Runtime:_is_current_fiber()
  local f = self._current_fiber
  if not f then
    return false
  end
  -- Yieldable protected calls may execute user code in a child coroutine.
  -- Resolve that child back to the owning runtime fibre before enforcing the
  -- perform/driver phase boundary.
  local running = Protected.running(coroutine.running())
  return running == f.co
end

function Runtime:_require_perform_allowed(level)
  if self:_is_current_fiber() and self._phase == 'fiber' then
    return true
  end
  return self:_fail('phase_error', 'perform may only be called by the currently resumed runtime fibre', {
    action = 'perform',
    phase = self._phase,
    level = level or 0,
  })
end

function Runtime:_require_spawn_allowed(level)
  if self._phase == 'external' or self._phase == 'fiber' then
    return true
  end
  return self:_fail('phase_error', 'spawn may not be called from runtime internals', {
    action = 'spawn',
    phase = self._phase,
    level = level or 0,
  })
end

function Runtime:_require_driver_call(action, level)
  if not self:_is_current_fiber() and self._phase == 'external' then
    return true
  end
  return self:_fail('phase_error', tostring(action) .. ' may only be called by external driver code', {
    action = action,
    phase = self._phase,
    level = level or 0,
  })
end

local function finish_phase_call(self, name, kind, fatal, committed, result)
  if result[1] then return unpack_(result, 2, result.n) end
  local err = result[2]
  if type(err) == 'table' and err._fibers_error and not fatal then error(err, 0) end
  if fatal then
    return self:_fatal(kind or 'effect_error', err, { phase = name, committed = committed, level = 0 })
  end
  return self:_fail(kind or 'callback_error', err, { phase = name, level = 0 })
end

function Runtime:_set_phase(name)
  local old = self._phase
  self._phase = name
  return old
end
function Runtime:_restore_phase(old)
  self._phase = old
end
local function phase_pcall(self, name, fn, ...)
  local old = self:_set_phase(name)
  local result = pack_(pcall(fn, ...))
  self:_restore_phase(old)
  return result
end

function Runtime:_call_in_phase(name, kind, fn, ...)
  return finish_phase_call(self, name, kind, false, nil, phase_pcall(self, name, fn, ...))
end
function Runtime:_call_fatal_in_phase(name, kind, committed, fn, ...)
  return finish_phase_call(self, name, kind, true, committed, phase_pcall(self, name, fn, ...))
end

function Runtime.new(opts)
  opts = opts or {}
  local instrumentation
  if opts.instrumentation then
    if type(opts.instrumentation) == 'table' and type(opts.instrumentation.inc) == 'function' then
      instrumentation = opts.instrumentation
    else
      local Instrumentation = require_optional('fibers.diagnostics.search', 'Runtime instrumentation')
      instrumentation = Instrumentation.new(opts.instrumentation)
    end
  end
  next_runtime_id = next_runtime_id + 1
  local runtime = Label.attach(setmetatable({
    _fibers_id = 'runtime-' .. tostring(next_runtime_id),
    host = opts.host or {},
    _phase = 'external',
    _failed = nil,
    _ready_fibers = {},
    _ready_head = 1,
    _ready_tail = 0,
    _live_fibers = 0,
    _next_fiber_id = 0,
    instrumentation = instrumentation,
  }, Runtime))
  runtime.engine = Engine.new(runtime, opts)
  return runtime
end

function Runtime:_lifetime_store()
  local store = self.lifetimes
  if not store then
    store = require('fibers.lifetime.store').new(self)
    self.lifetimes = store
  end
  return store
end

function Runtime:_add_finalizer(fn)
  if type(fn) ~= 'function' then
    error('runtime finalizer must be a function', 2)
  end
  if self._finalized then
    error('runtime is already finalised', 2)
  end
  local finalizers = self._finalizers or {}
  self._finalizers = finalizers
  finalizers[#finalizers + 1] = fn
  return fn
end

function Runtime:_finalize()
  if self._finalized then
    return true
  end
  self._finalized = true
  local first_err
  local finalizers = self._finalizers or {}
  for i = #finalizers, 1, -1 do
    local called, ok, err = pcall(finalizers[i])
    if first_err == nil then
      if not called then
        first_err = ok
      elseif ok == nil or ok == false then
        first_err = err or 'runtime finalizer failed'
      end
    end
    finalizers[i] = nil
  end
  if first_err ~= nil then
    error(first_err, 0)
  end
  return true
end

function Runtime:now()
  local now = self.host and self.host.now
  if type(now) == 'function' then
    return now(self)
  end
  return 0
end


local function spawn_unchecked(self, fn, scope, subject)
  if type(fn) ~= 'function' then
    error('spawn expects a function', 3)
  end
  self._next_fiber_id = self._next_fiber_id + 1
  local id = 'fiber-' .. tostring(self._next_fiber_id)
  local fiber = Label.attach({
    name = id,
    _fibers_id = id,
    _fibers_label_subject = subject,
    co = coroutine.create(fn),
    started = false,
    done = false,
    scope = scope,
    scope_stack = scope and { scope } or nil,
  })
  self._ready_tail = self._ready_tail + 1
  self._ready_fibers[self._ready_tail] = fiber
  self._live_fibers = self._live_fibers + 1
  local instrumentation = self.instrumentation
  if instrumentation then
    instrumentation:inc('fibres_spawned')
    instrumentation:max('live_fibres', self._live_fibers)
    instrumentation:max('ready_fibres', self._ready_tail - self._ready_head + 1)
  end
  return fiber
end

function Runtime:spawn_raw(fn)
  self:_check_not_failed(2)
  self:_require_spawn_allowed(2)
  return spawn_unchecked(self, fn)
end

function Runtime:_spawn_raw(fn, scope, subject)
  self:_check_not_failed(2)
  self:_require_spawn_allowed(2)
  return spawn_unchecked(self, fn, scope, subject)
end

function Runtime:_spawn_committed(fn, scope, subject)
  self:_check_not_failed(2)
  return spawn_unchecked(self, fn, scope, subject)
end

function Runtime:_discharge_interrupt(token, reason)
  raise_interrupt(token, reason)
  return self.engine:interrupt(token, Runtime.cancelled(reason, token))
end

function Runtime:_enter_execution_contract(spec)
  self:_require_perform_allowed(2)
  return Execution.enter(self, spec)
end

function Runtime:_leave_execution_contract(token)
  return Execution.leave(self, token)
end

function Runtime:_suspension_contract(fiber)
  return Execution.suspension_contract(fiber or self._current_fiber)
end

function Runtime:_perform_current(op, interrupt, masked)
  if interrupt and interrupt.raised and not masked then
    error(Runtime.cancelled(interrupt.reason, interrupt), 0)
  end
  local cancelled, packed, wrap = coroutine.yield(PERFORM_YIELD, op, masked and nil or interrupt)
  if cancelled then
    error(cancelled, 0)
  end
  if wrap then
    packed = wrap(packed)
  end
  return unpack_pack(packed)
end

function Runtime:perform(op, opts)
  self:_check_not_failed(2)
  self:_require_perform_allowed(2)
  if not Op.is_op(op) then
    error('perform expects an Op', 2)
  end
  return self:_perform_current(op, opts and opts.interrupt, opts and opts.masked)
end

function Runtime:_finish_fiber(fiber)
  if fiber.done then
    return
  end
  fiber.done = true
  -- A completed fibre handle remains useful for identity and diagnostics, but
  -- its coroutine and dynamic scope graph must not be retained by the runtime.
  fiber.co = nil
  fiber.scope = nil
  fiber.scope_stack = nil
  self._live_fibers = math.max(self._live_fibers - 1, 0)
  local instrumentation = self.instrumentation
  if instrumentation then
    instrumentation:inc('fibres_completed')
  end
end

function Runtime:_resume_fiber(fiber, a, b, c)
  local ok, yielded, yielded_op, yielded_interrupt
  local instrumentation = self.instrumentation
  if instrumentation then
    instrumentation:inc('fibre_resumes')
  end
  local context_token, previous_fiber = Context.enter(self, fiber.scope), self._current_fiber
  self._current_fiber = fiber
  local old_phase = self:_set_phase('fiber')
  if fiber.started then
    ok, yielded, yielded_op, yielded_interrupt = coroutine.resume(fiber.co, a, b, c)
  else
    fiber.started = true
    ok, yielded, yielded_op, yielded_interrupt = coroutine.resume(fiber.co)
  end
  self:_restore_phase(old_phase)
  Context.leave(context_token)
  self._current_fiber = previous_fiber
  if not ok then
    self:_finish_fiber(fiber)
    error(yielded, 0)
  end
  if coroutine.status(fiber.co) == 'dead' then
    self:_finish_fiber(fiber)
    return
  end
  if yielded ~= PERFORM_YIELD or not Op.is_op(yielded_op) then
    self:_finish_fiber(fiber)
    error('runtime received an unsupported coroutine yield', 0)
  end
  self.engine:admit(fiber, yielded_op, yielded_interrupt)
  if Execution.suspension_forbidden(fiber) then
    self.engine:resolve_without_suspension(fiber)
  end
end

function Runtime:_start_one()
  local head, tail = self._ready_head, self._ready_tail
  if head > tail then
    return nil
  end

  local fiber = self._ready_fibers[head]
  self._ready_fibers[head] = nil
  head = head + 1
  if head > tail then
    -- Reset the consumed queue so indices and the backing table do not grow
    -- with the lifetime of a long-running runtime.
    self._ready_head = 1
    self._ready_tail = 0
  else
    self._ready_head = head
  end

  self:_resume_fiber(fiber)
  return fiber
end


local function driver_call(self, action, opts)
  self:_check_not_failed(2)
  self:_require_driver_call(action, 2)
  local result = phase_pcall(self, 'driver', self.engine.advance, self.engine, action, opts)
  if not result[1] then
    local err = result[2]
    if type(err) == 'table' and (err._fibers_error or err._fibers_scope_report or err._fibers_closure_failure) then
      error(err, 0)
    end
    return self:_fail('runtime_error', err, { phase = action, level = 0 })
  end
  return unpack_(result, 2, result.n)
end

function Runtime:step(opts) return driver_call(self, 'step', opts) end
function Runtime:run(opts) return driver_call(self, 'run', opts) end

Runtime._new_interrupt = new_interrupt
return Runtime
