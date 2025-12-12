-- fibers.lua
-- Top-level facade for the fibers library.
--
-- Provides a small, convenient surface over the lower-level modules:
--   - runtime    (scheduler and fibers),
--   - op         (CML engine),
--   - scope      (structured concurrency),
--   - primitives (sleep, channel, etc.).
--
---@module 'fibers'

local Op        = require 'fibers.op'
local Runtime   = require 'fibers.runtime'
local Scope     = require 'fibers.scope'
local Performer = require 'fibers.performer'

local unpack = rawget(table, "unpack") or _G.unpack
local pack   = rawget(table, "pack")   or function(...)
    return { n = select("#", ...), ... }
end

----------------------------------------------------------------------
-- Core entry points
----------------------------------------------------------------------

--- Run a main function under the scheduler's root scope.
---
--- main_fn is called as main_fn(scope, ...).
---
--- On success:
---   returns ...results... from main_fn directly.
---
--- On failure or cancellation:
---   raises the primary error / cancellation reason.
---
---@param main_fn fun(s: Scope, ...): any
---@param ... any
---@return any ...  -- only results from main_fn on success
local function run(main_fn, ...)
  assert(not Runtime.current_fiber(),
    "fibers.run must not be called from inside a fiber")

  local root = Scope.root()
  local args = pack(...)

  -- Outcome container populated by the child fiber.
  local outcome = {
    status  = nil,  -- "ok" | "failed" | "cancelled"
    err     = nil,  -- primary error / reason
    results = nil,  -- packed results from main_fn on success
  }

  root:spawn(function()
    -- Scope.run creates a child scope and runs main_fn(body_scope, ...),
    -- returning (status, err, ...results...).
    local packed        = pack(Scope.run(main_fn, unpack(args, 1, args.n)))
    outcome.status      = packed[1]
    outcome.err         = packed[2]

    if packed.n > 3 and outcome.status == "ok" then
      local out = { n = packed.n - 3 }
      local j   = 1
      for i = 4, packed.n do
        out[j] = packed[i]
        j = j + 1
      end
      outcome.results = out
    end

    -- Stop the scheduler so Runtime.main() returns.
    Runtime.stop()
  end)

  -- Drive the scheduler until the main scope decides to stop it.
  Runtime.main()

  -- Interpret the outcome.
  local status, err, results = outcome.status, outcome.err, outcome.results

  if status ~= "ok" then
    -- Re-raise the primary error / cancellation reason.
    -- This may be any Lua value (string, table, etc.).
    error(err or status)
  end

  if results then
    return unpack(results, 1, results.n)
  end
  -- No results from main_fn: return nothing.
end

----------------------------------------------------------------------
-- Spawn
----------------------------------------------------------------------

--- Spawn a fiber under the current scope.
---
--- fn is called as fn(...).
---@param fn fun(...): any
---@param ... any
local function spawn(fn, ...)
  local s    = Scope.current()
  local args = { ... }

  -- Wrapper that discards the scope parameter injected by Scope:spawn.
  local function shim(_, ...)
    return fn(...)
  end

  return s:spawn(shim, unpack(args))
end

return {
    spawn = spawn,
    run   = run,

    perform = Performer.perform,

    now = Runtime.now,

    choice     = Op.choice,
    guard      = Op.guard,
    with_nack  = Op.with_nack,
    always     = Op.always,
    never      = Op.never,
    bracket    = Op.bracket,

    -- Higher-level choice helpers
    race           = Op.race,
    first_ready    = Op.first_ready,
    named_choice   = Op.named_choice,
    boolean_choice = Op.boolean_choice,

    -- Scope utilities re-exported
    run_scope                  = Scope.run,
    with_scope_op              = Scope.with_op,
    set_unscoped_error_handler = Scope.set_unscoped_error_handler,
    current_scope              = Scope.current
}
