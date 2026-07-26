-- Ephemeral perform-local view supplied while an Op.guard builder elaborates.
--
-- A guard activation is not an enduring ambient context. It is valid only for
-- the dynamic extent of one guard callback. Values taken from it must be
-- embedded into the explicit residual Op returned by that callback.
--
-- The public surface is deliberately narrow: one stable activation-time
-- monotonic observation and the performing Scope. Runtime authority
-- remains private to the evaluator.

local GuardActivation = {}
local Methods = {}
Methods.__index = Methods
Methods.__metatable = 'fibers guard activation'

local states = setmetatable({}, { __mode = 'k' })

local function require_open(self, level)
  local state = states[self]
  if not state then
    error('guard activation is no longer available after its builder returns', (level or 1) + 1)
  end
  return state
end

function GuardActivation.new(runtime, scope)
  local activation = setmetatable({}, Methods)
  states[activation] = {
    runtime = runtime,
    scope = scope,
  }
  return activation
end

-- One activation-time monotonic observation. Every call in one guard
-- activation returns the same instant; a later semantic activation samples
-- afresh.
function Methods:now()
  local state = require_open(self, 1)
  if state.now == nil then
    state.now = state.runtime:now()
  end
  return state.now
end

function Methods:scope()
  return require_open(self, 1).scope
end

function GuardActivation.close(activation)
  states[activation] = nil
end

return GuardActivation
