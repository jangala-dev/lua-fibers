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

local unpack = rawget(table, 'unpack') or _G.unpack
local pack   = rawget(table, 'pack') or function (...)
	return { n = select('#', ...), ... }
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
	local idx       = #list
	local unlinked  = false

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
	list[idx]  = nil
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
-- waitable2: (register, probe_step, run_step, wrap_fn?) -> Op
----------------------------------------------------------------------

-- Normalise "want" without restricting it to rd/wr/any.
--   * nil/false -> nil
--   * 'any' is treated specially by register_with_want
--   * everything else is passed through to register(...)
local function normalise_want(want)
	if want == nil or want == false then
		return nil
	end
	return want
end

--- Build a waitable Op from a register function and two step functions.
--
--   probe_step() -> done:boolean, ...
--     * Must be non-blocking and must not yield.
--     * Should be side-effect neutral when returning done==false.
--     * May return (false, want) where want is any token understood by register().
--
--   run_step() -> done:boolean, ...
--     * Must be non-blocking and must not yield.
--     * May perform stateful progress (e.g. fill buffers, advance state machines).
--
--   register(task, suspension, leaf_wrap, want) -> token
--     * Must arrange for task:run() when progress may be possible.
--     * want is passed through (except 'any', see below).
--     * token:unlink() (if present) is called on abort to cancel registration.
--
-- Special want:
--   * want == 'any' registers both ('rd' and 'wr') and unlinks both on abort.
--
---@param register fun(task: Task, suspension: Suspension, leaf_wrap: WrapFn, want: any): WaitToken
---@param probe_step fun(): boolean, ...
---@param run_step fun(): boolean, ...
---@param wrap_fn? WrapFn
---@return Op
local function waitable2(register, probe_step, run_step, wrap_fn)
	assert(type(register) == 'function', 'waitable2: register must be a function')
	assert(type(probe_step) == 'function', 'waitable2: probe_step must be a function')
	assert(type(run_step) == 'function', 'waitable2: run_step must be a function')

	wrap_fn = wrap_fn or id_wrap

	return op.guard(function ()
		local token
		local last_want

		local function unlink_token()
			if token and token.unlink then
				token:unlink()
			end
			token = nil
		end

		local function set_want_from_probe()
			local pres = pack(probe_step())
			if not pres[1] then
				last_want = normalise_want(pres[2])
			else
				last_want = nil
			end
		end

		local function try()
			local res = pack(probe_step())
			if not res[1] then
				last_want = normalise_want(res[2])
			else
				last_want = nil
			end
			return unpack(res, 1, res.n)
		end

		local function block(suspension, leaf_wrap)
			---@class WaitTask : Task
			local task

			local function register_with_want(want)
				unlink_token()

				if want == 'any' then
					local t1 = register(task, suspension, leaf_wrap, 'rd')
					local t2 = register(task, suspension, leaf_wrap, 'wr')
					token = {
						unlink = function ()
							if t1 and t1.unlink then t1:unlink() end
							if t2 and t2.unlink then t2:unlink() end
						end,
					}
				else
					token = register(task, suspension, leaf_wrap, want)
				end
			end

			task = {
				run = function ()
					if not suspension:waiting() then
						return
					end

					local res  = pack(run_step())
					local done = res[1]
					if done then
						unlink_token()
						return suspension:complete(leaf_wrap, unpack(res, 2, res.n))
					end

					-- If run_step did not specify a want, derive it from probe_step.
					-- This avoids stalling after partial progress when the primitive
					-- is still not complete.
					local w = normalise_want(res[2])
					if w == nil then
						set_want_from_probe()
					else
						last_want = w
					end

					register_with_want(last_want)
				end,
			}

			-- Register based on last_want as computed by the most recent try().
			register_with_want(last_want)
		end

		local prim = op.new_primitive(wrap_fn, try, block)

		return prim:on_abort(function ()
			unlink_token()
		end)
	end)
end

--- Backwards-compatible wrapper: a single step is used for both probe and run.
---@param register fun(task: Task, suspension: Suspension, leaf_wrap: WrapFn, want: any): WaitToken
---@param step fun(): boolean, ...
---@param wrap_fn? WrapFn
---@return Op
local function waitable(register, step, wrap_fn)
	return waitable2(register, step, step, wrap_fn)
end

return {
	new_waitset = new_waitset,
	waitable    = waitable,
	waitable2    = waitable2,
}
