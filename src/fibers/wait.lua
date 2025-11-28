---
-- Wait module.
--
-- Internal helper utilities for building blocking primitives:
--
--   * Waitset: keyed sets of waiting tasks with unlink tokens.
--   * waitable(register, step, wrap_fn?): build an op from
--       a step function and a registration function.
--
-- This module is intended for backend / primitive implementations
-- (pollers, in-memory pipes, streams, timers). Normal library users
-- should not need to depend on it directly.
--
-- Design notes:
--   - This module is exception-neutral. It does not interpret Lua
--     errors as part of op semantics.
--   - step() and register(...) are assumed to be non-blocking and
--     non-yielding. If they raise, this is treated as a bug and the
--     surrounding scope/fiber machinery will surface the failure.
---@module 'fibers.wait'

local op = require 'fibers.op'

local unpack = rawget(table, "unpack") or _G.unpack
local pack   = rawget(table, "pack") or function(...)
    return { n = select("#", ...), ... }
end

local function id_wrap(...)
    return ...
end

----------------------------------------------------------------------
-- Waitset: keyed lists of tasks with unlink tokens
----------------------------------------------------------------------

--- Keyed set of scheduler tasks grouped by an arbitrary key.
---@class Waitset
---@field buckets table<any, Task[]>  # key -> list of scheduler tasks
local Waitset = {}
Waitset.__index = Waitset

--- Token returned from Waitset:add.
--- unlink() removes the task from the waitset; it is idempotent.
---@class WaitToken
---@field _waitset Waitset
---@field key any
---@field task Task
---@field unlink fun(self: WaitToken): boolean  # true if bucket emptied

--- Create a new Waitset instance.
---@return Waitset
local function new_waitset()
    return setmetatable({ buckets = {} }, Waitset)
end

--- Remove element at index i by swapping with the tail.
---@param t Task[]
---@param i integer
local function remove_at(t, i)
    local n = #t
    t[i] = t[n]
    t[n] = nil
end

--- Add a task under a given key.
--
-- @param key   Arbitrary key (fd, object, tag, etc.).
-- @param task  Scheduler task object (must have :run()).
--
-- @return token  Table with token:unlink() -> bucket_empty:boolean.
---@param key any
---@param task Task
---@return WaitToken
function Waitset:add(key, task)
    local buckets = self.buckets
    local list = buckets[key]
    if not list then
        list = {}
        buckets[key] = list
    end

    list[#list + 1] = task
    local idx      = #list
    local unlinked = false

    ---@class WaitToken
    local token = {
        _waitset = self,
        key      = key,
        task     = task,
    }

    --- Unlink this task from the waitset.
    --- Best-effort: falls back to a reverse scan if the stored index
    --- has been invalidated by earlier removals.
    ---@param tok WaitToken
    ---@return boolean bucket_empty
    function token.unlink(tok)
        if unlinked then
            return false
        end
        unlinked = true

        local bs = tok._waitset.buckets
        local l  = bs[tok.key]
        if not l or #l == 0 then
            return false
        end

        -- Best-effort removal; index may be stale.
        if idx <= #l and l[idx] == tok.task then
            remove_at(l, idx)
        else
            for i = #l, 1, -1 do
                if l[i] == tok.task then
                    remove_at(l, i)
                    break
                end
            end
        end

        if #l == 0 then
            bs[tok.key] = nil
            return true
        end
        return false
    end

    return token
end

--- Take and remove all waiters for a key.
---
--- Returns the list (which the caller may iterate and discard), or nil.
---@param key any
---@return Task[]|nil
function Waitset:take_all(key)
    local list = self.buckets[key]
    if not list then
        return nil
    end
    self.buckets[key] = nil
    return list
end

--- Take and remove a single waiter (LIFO) for a key.
---
--- Returns the task or nil.
---@param key any
---@return Task|nil
function Waitset:take_one(key)
    local list = self.buckets[key]
    if not list or #list == 0 then
        return nil
    end
    local idx  = #list
    local task = list[idx]
    list[idx] = nil
    if #list == 0 then
        self.buckets[key] = nil
    end
    return task
end

--- Return whether there are no waiters for this key.
---@param key any
---@return boolean
function Waitset:is_empty(key)
    local list = self.buckets[key]
    return not list or #list == 0
end

--- Return the number of waiters for this key.
---@param key any
---@return integer
function Waitset:size(key)
    local list = self.buckets[key]
    return list and #list or 0
end

--- Remove all waiters for a single key without notifying them.
---@param key any
function Waitset:clear_key(key)
    self.buckets[key] = nil
end

--- Remove all waiters for all keys without notifying them.
function Waitset:clear_all()
    self.buckets = {}
end

--- Notify and schedule all waiters for a key.
---@param key any
---@param scheduler Scheduler
function Waitset:notify_all(key, scheduler)
    local list = self:take_all(key)
    if not list then return end
    for i = 1, #list do
        scheduler:schedule(list[i])
        list[i] = nil
    end
end

--- Notify and schedule a single waiter (LIFO) for a key.
---@param key any
---@param scheduler Scheduler
function Waitset:notify_one(key, scheduler)
    local task = self:take_one(key)
    if not task then return end
    scheduler:schedule(task)
end

----------------------------------------------------------------------
-- waitable: (register, step, wrap_fn?) -> Op
----------------------------------------------------------------------

--- Build a waitable Op from a register function and step function.
--
--   step() -> done:boolean, ...
--
--     * done == true  : the operation is ready to commit now;
--                       remaining values are the result.
--     * done == false : not ready; the register() function must
--                       arrange a future call to task:run().
--
--   register(task, suspension, leaf_wrap) -> token
--
--     * Must arrange for task:run() to be invoked when progress may
--       have been made (fd readable, space available, timer expired).
--     * Returns a token table which may define token:unlink() to
--       cancel any outstanding registration for this synchronisation.
--
--   wrap_fn (optional) is used as the primitive wrap for the Op.
--
-- Requirements on step and register:
--   - Both must be non-blocking and must not yield.
--   - Errors raised by step/register are not caught here; they are
--     treated as bugs and surfaced by the surrounding scope/fiber.
--
-- The op participates fully in choice/with_nack/on_abort; if it loses
-- a choice, any outstanding registration is cancelled via token:unlink().
---@param register fun(task: Task, suspension: Suspension, leaf_wrap: WrapFn): WaitToken
---@param step fun(): boolean, ...
---@param wrap_fn? WrapFn
---@return Op
local function waitable(register, step, wrap_fn)
    assert(type(register) == "function", "waitable: register must be a function")
    assert(type(step)     == "function", "waitable: step must be a function")

    wrap_fn = wrap_fn or id_wrap

    return op.guard(function()
        -- Token for this synchronisation (one per compiled leaf).
        local token

        -- Fast path: single non-blocking attempt.
        -- step() must not yield; if it raises, this fiber fails.
        local function try()
            return step()
        end

        --- Blocking path: register a task that will re-run step
        --- after the external condition changes.
        ---
        --- The same task is re-used across wake-ups; token is updated
        --- to track the latest registration.
        ---@param suspension Suspension
        ---@param leaf_wrap WrapFn
        local function block(suspension, leaf_wrap)
            ---@class WaitTask : Task
            local task

            task = {
                run = function()
                    if not suspension:waiting() then
                        return
                    end

                    -- Re-check readiness.
                    local res  = pack(step())
                    local done = res[1]
                    if done then
                        -- Complete with the leaf's final wrap.
                        return suspension:complete(
                            leaf_wrap,
                            unpack(res, 2, res.n)
                        )
                    end

                    -- Not done yet; re-register for another wake-up.
                    if token and token.unlink then
                        token:unlink()
                    end

                    token = register(task, suspension, leaf_wrap)
                end,
            }

            -- Initial registration for this synchronisation.
            token = register(task, suspension, leaf_wrap)
        end

        local prim = op.new_primitive(wrap_fn, try, block)

        -- If this op participates in a choice and loses, ensure any
        -- extant registration is cancelled once for this synchronisation.
        return prim:on_abort(function()
            if token and token.unlink then
                token:unlink()
            end
        end)
    end)
end

return {
    new_waitset = new_waitset,
    waitable    = waitable,
}
