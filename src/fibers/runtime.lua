-- Fiber scheduler and public execution boundary.

local Op = require('fibers.op')
local Values = require('fibers.internal.values')
local Protected = require('fibers.internal.protected')
local Context = require('fibers.internal.context')
local Engine = require('fibers.internal.engine')
local Label = require('fibers.internal.label')
local Contract = require('fibers.internal.contract')

local function require_optional(module_name, feature)
  local ok, module = pcall(require, module_name)
  if ok then return module end
  error((feature or module_name) .. ' requires optional package module ' .. module_name .. ': ' .. tostring(module), 3)
end

-- Internal perform-boundary interruption token.  Raising is capability-safe:
-- the token exposes state only; committed interrupt Effects own mutation.
local function new_interrupt(name)
  return { name = name or 'interrupt', raised = false, reason = nil, _fibers_interrupt = true }
end

local Runtime = {}
local PERFORM_YIELD = {}
local next_runtime_id = 0

Runtime.__index = Runtime
function Runtime.current()
  return Context.runtime
end
function Runtime.current_scope()
  local rt = Context.runtime
  return rt and rt._current_fiber.scope or nil
end

local unpack_ = table.unpack or unpack
local pack_ = Values.pack
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
  -- Resolve that child back to the owning runtime fiber before enforcing the
  -- perform/driver phase boundary.
  local running = Protected.running(coroutine.running())
  return running == f.co
end

local function phase_error(self, action, message, level)
  return self:_fail('phase_error', message, { action = action, level = level or 0 })
end

function Runtime:_require_perform_allowed(level)
  if self:_is_current_fiber() and self._phase == 'fiber' then return true end
  return phase_error(self, 'perform', 'perform may only be called by the currently resumed runtime fiber', level)
end

function Runtime:_require_spawn_allowed(level)
  if self._phase == 'external' or self._phase == 'fiber' then return true end
  return phase_error(self, 'spawn', 'spawn may not be called from runtime internals', level)
end

function Runtime:_require_driver_call(action, level)
  if not self:_is_current_fiber() and self._phase == 'external' then return true end
  return phase_error(self, action, tostring(action) .. ' may only be called by external driver code', level)
end

local function phase_pcall(self, name, fn, ...)
  local old = self:_set_phase(name)
  local result = pack_(pcall(fn, ...))
  self:_restore_phase(old)
  return result
end

local function phase_result(self, name, kind, fatal, committed, result)
  if result[1] then return unpack_(result, 2, result.n) end
  local err = result[2]
  if type(err) == 'table' and err._fibers_error and fatal ~= true then error(err, 0) end
  if fatal ~= false then return self:_fatal(kind, err, { phase = name, committed = committed, level = 0 }) end
  return self:_fail(kind, err, { phase = name, level = 0 })
end

function Runtime:_set_phase(name)
  local old = self._phase
  self._phase = name
  return old
end
function Runtime:_restore_phase(old) self._phase = old end

function Runtime:_call_in_phase(name, kind, fn, ...)
  return phase_result(self, name, kind or 'callback_error', false, nil, phase_pcall(self, name, fn, ...))
end
function Runtime:_call_fatal_in_phase(name, kind, committed, fn, ...)
  return phase_result(self, name, kind or 'effect_error', true, committed, phase_pcall(self, name, fn, ...))
end

-- Trusted pre-commit authoring failures are fatal, except Fibers-generated
-- structured errors which retain their original classification.
function Runtime:_call_contract_in_phase(name, kind, fn, ...)
  return phase_result(self, name, kind or 'effect_contract_error', nil, false, phase_pcall(self, name, fn, ...))
end

local function instrumentation_option(value, label, level)
  if value ~= true and value ~= false and type(value) ~= 'table' then
    error(label .. ' must be true, false, a table or nil', level or 3)
  end
  return value
end

local RUNTIME_OPTIONS = {
  host = Contract.table,
  instrumentation = instrumentation_option,
  quiet_deadlock = Contract.boolean,
  search_limit = Contract.positive_integer,
  search_total_limit = Contract.positive_integer,
  search_trail_limit = Contract.positive_integer,
  search_depth_limit = Contract.positive_integer,
  cycle_work_limit = Contract.positive_integer,
  cycle_focus_limit = Contract.positive_integer,
  choice_seed = Contract.integer,
}

function Runtime.new(opts)
  opts = Contract.record(opts, RUNTIME_OPTIONS, 'Runtime options', 2)
  local instrumentation
  if opts.instrumentation == true then
    local Instrumentation = require_optional('fibers.diagnostics.search', 'Runtime instrumentation')
    instrumentation = Instrumentation.new(true)
  elseif type(opts.instrumentation) == 'table' then
    if type(opts.instrumentation.inc) == 'function' then
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

function Runtime:_lifetime_root()
  local root = self._root_lifetime
  if root then return root end
  local Lifetime = require('fibers.lifetime')
  root = Lifetime.new({ label = 'runtime-root' })
  root._runtime_root = true
  root:_bind_runtime_committed(self)
  self:_lifetime_store():_bootstrap_root(root)
  self._root_lifetime = root
  return root
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
    _fibers_id = id,
    _fibers_label_subject = subject,
    co = coroutine.create(fn),
    done = false,
    scope = scope,
  })
  if self._ready_tail then self._ready_tail._ready_next = fiber else self._ready_head = fiber end
  self._ready_tail = fiber
  local instrumentation = self.instrumentation
  if instrumentation then
    instrumentation:inc('fibers_spawned')
  end
  return fiber
end

function Runtime:spawn_raw(fn) return self:_spawn_raw(fn) end

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
  token.raised, token.reason = true, reason
  return self.engine:interrupt(token, Runtime.cancelled(reason, token))
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
  return unpack_(packed, 1, packed.n)
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
  fiber.done = true
  -- A completed fiber handle remains useful for identity and diagnostics, but
  -- its coroutine and dynamic scope graph must not be retained by the runtime.
  fiber.co = nil
  fiber.scope = nil
  local instrumentation = self.instrumentation
  if instrumentation then
    instrumentation:inc('fibers_completed')
  end
end

function Runtime:_resume_fiber(fiber, resumed, a, b, c)
  local ok, yielded, yielded_op, yielded_interrupt
  local instrumentation = self.instrumentation
  if instrumentation then
    instrumentation:inc('fiber_resumes')
  end
  local previous_runtime, previous_fiber = Context.runtime, self._current_fiber
  Context.runtime, self._current_fiber = self, fiber
  local old_phase = self:_set_phase('fiber')
  if resumed then
    ok, yielded, yielded_op, yielded_interrupt = coroutine.resume(fiber.co, a, b, c)
  else
    ok, yielded, yielded_op, yielded_interrupt = coroutine.resume(fiber.co)
  end
  self:_restore_phase(old_phase)
  self._current_fiber, Context.runtime = previous_fiber, previous_runtime
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
  if fiber._suspension_forbidden then
    self.engine:resolve_without_suspension(fiber)
  end
end

function Runtime:_has_ready() return self._ready_head ~= nil end

function Runtime:_start_one()
  local fiber = self._ready_head
  if not fiber then return nil end
  self._ready_head = fiber._ready_next
  fiber._ready_next = nil
  if not self._ready_head then self._ready_tail = nil end
  self:_resume_fiber(fiber, false)
  return fiber
end


local DRIVER_OPTIONS = { max_work = Contract.positive_integer }

local function driver_call(self, action, opts)
  opts = Contract.record(opts, DRIVER_OPTIONS, 'Runtime driver options', 3)
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
