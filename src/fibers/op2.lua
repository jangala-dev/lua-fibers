-- fibers/op2.lua
--
-- Restartable synchronisation with transactional publication.
--
-- Notes
--   * commit() is the single publication point.
--   * Records are assumed to be non-yielding (validate/apply/abort/watch).
--   * abort() MUST be safe to call on committed records; the kernel enforces
--     this by marking records as _committed during commit() and skipping them
--     in abort paths.

local runtime = require 'fibers.runtime'
local safe    = require 'coxpcall'

----------------------------------------------------------------------
-- Packed values (preserve nils and arity)
----------------------------------------------------------------------

local function pack(...)
	return { n = select('#', ...), ... }
end

local unpack = table.unpack or _G.unpack
local function id_wrap(...) return ... end

local function bugf(fmt, ...)
	error(string.format(fmt, ...), 0)
end

----------------------------------------------------------------------
-- Suspension (lifted from fibers.op; minimal surface)
----------------------------------------------------------------------

---@class Suspension : Task
---@field state "waiting"|"synchronized"
---@field sched any
---@field fiber any
---@field wrap function|nil
---@field val table|nil
local Suspension = {}
Suspension.__index = Suspension

---@class CompleteTask : Task
---@field suspension Suspension
---@field wrap function
---@field val table
local CompleteTask = {}
CompleteTask.__index = CompleteTask

local function new_suspension(sched, fib)
	return setmetatable({
		state    = 'waiting',
		sched    = sched,
		fiber    = fib,
		cleanups = nil,
		cleaned  = false,
	}, Suspension)
end

function Suspension:waiting()
	return self.state == 'waiting'
end

function Suspension:add_cleanup(f)
	if type(f) ~= 'function' then error('cleanup must be a function', 2) end
	if self.cleaned then
		safe.pcall(f)
		return
	end
	local cs = self.cleanups
	if not cs then
		cs = {}; self.cleanups = cs
	end
	cs[#cs + 1] = f
end

function Suspension:_run_cleanups()
	if self.cleaned then return end
	self.cleaned = true
	local cs = self.cleanups
	self.cleanups = nil
	if not cs then return end
	for i = #cs, 1, -1 do
		safe.pcall(cs[i])
		cs[i] = nil
	end
end

function Suspension:wakeup(task) self.sched:schedule(task) end

function Suspension:at_time(t, task) self.sched:schedule_at_time(t, task) end

function Suspension:after(dt, task) self.sched:schedule_after_sleep(dt, task) end

function Suspension:complete(wrap, ...)
	assert(self:waiting())
	self.state = 'synchronized'
	self.wrap  = wrap
	self.val   = pack(...)
	self:_run_cleanups()
	self.sched:schedule(self)
end

function Suspension:complete_task(wrap, ...)
	return setmetatable({ suspension = self, wrap = wrap, val = pack(...) }, CompleteTask)
end

function Suspension:run()
	assert(not self:waiting())
	return self.fiber:resume(self.wrap, unpack(self.val, 1, self.val.n))
end

function CompleteTask:run()
	if self.suspension:waiting() then
		self.suspension:complete(self.wrap, unpack(self.val, 1, self.val.n))
	end
end

local function new_waker(suspension)
	return {
		wakeup  = function (_, task) suspension:wakeup(task) end,
		at_time = function (_, t, task) suspension:at_time(t, task) end,
		after   = function (_, dt, task) suspension:after(dt, task) end,
	}
end

-- Primitives may register abort cleanups on their state table.
-- The kernel will run them best-effort when that primitive state is abandoned.

local function st_add_cleanup(st, f)
	if type(f) ~= 'function' then error('st_add_cleanup: cleanup must be a function', 2) end
	local cs = st._cleanups
	if not cs then
		cs = {}; st._cleanups = cs
	end
	cs[#cs + 1] = f
end

local function st_run_cleanups(st)
	local cs = st._cleanups
	st._cleanups = nil
	if not cs then return end
	for i = #cs, 1, -1 do
		safe.pcall(cs[i])
		cs[i] = nil
	end
end

----------------------------------------------------------------------
-- Record protocol (Txn stores only records)
----------------------------------------------------------------------

-- Record methods MUST NOT yield.
--
-- validate() -> 'OK' | 'RETRY'
-- apply()    -> 'OK' (or nil)
-- abort()    -> ()              -- best-effort; MUST be safe post-commit
-- watch(task, waker, want) -> token|nil

local function record_key(rec)
	if not rec then return nil end
	local k = rec.key
	if k == nil then return nil end
	if type(k) == 'function' then
		return k(rec)
	end
	return k
end

----------------------------------------------------------------------
-- Txn: base + delta (persistent-ish, correctness-first)
----------------------------------------------------------------------

---@class Txn
---@field base table
---@field delta table
---@field cut integer
---@field _spent boolean|nil
local Txn = {}
Txn.__index = Txn

local function txn_new(base, delta, cut)
	base  = base or {}
	delta = delta or {}
	cut   = cut or 0
	return setmetatable({ base = base, delta = delta, cut = cut, _spent = false }, Txn)
end

function Txn:_materialise()
	local out = {}
	local b, d = self.base, self.delta
	for i = 1, #b do out[#out + 1] = b[i] end
	for i = 1, #d do out[#out + 1] = d[i] end
	return out
end

function Txn:for_each(f)
	local b, d = self.base, self.delta
	for i = 1, #b do f(b[i]) end
	for i = 1, #d do f(d[i]) end
end

function Txn:for_each_rev(f)
	local b, d = self.base, self.delta
	for i = #d, 1, -1 do f(d[i]) end
	for i = #b, 1, -1 do f(b[i]) end
end

function Txn:fork()
	local base = self:_materialise()
	return txn_new(base, {}, #base)
end

function Txn:add(rec)
	if rec == nil then
		return self
	end
	local d  = self.delta
	local nd = {}
	for i = 1, #d do nd[i] = d[i] end
	nd[#nd + 1] = rec
	return txn_new(self.base, nd, self.cut)
end

-- Merge child txns in order while sharing the boundary prefix exactly once.
-- Assumes each child txn is derived (directly or indirectly) from this boundary.
function Txn:merge_in_order(txns)
	local base = self:_materialise()
	local base_len = #base

	local nd = {}
	for i = 1, #txns do
		local child = txns[i]
		local mats  = child:_materialise()

		-- Sanity check: boundary prefix must match by identity and order.
		if #mats < base_len then
			bugf('txn merge: child txn shorter than boundary (child=%d, boundary=%d)', #mats, base_len)
		end
		for j = 1, base_len do
			if mats[j] ~= base[j] then
				bugf('txn merge: child txn does not share boundary prefix at index %d', j)
			end
		end

		for j = base_len + 1, #mats do
			nd[#nd + 1] = mats[j]
		end
	end

	return txn_new(base, nd, 0)
end

local function abort_rec(rec)
	-- Records are marked _committed by commit(); abort must not undo publication.
	if rec and rec.abort and not rec._committed then
		safe.pcall(rec.abort, rec)
	end
end

function Txn:abort_local()
	local b, d = self.base, self.delta
	for i = #d, 1, -1 do abort_rec(d[i]) end
	for i = #b, self.cut + 1, -1 do abort_rec(b[i]) end
end

function Txn:abort_all()
	self._spent = true
	self:for_each_rev(abort_rec)
end

function Txn:arm_watches(task, waker, suspension, want, seen)
	self:for_each(function (rec)
		if rec and rec.watch then
			seen = seen or {}
			if not seen[rec] then
				seen[rec] = true
				local tok = rec.watch(rec, task, waker, want)
				if tok and tok.unlink and suspension:waiting() then
					suspension:add_cleanup(function ()
						safe.pcall(tok.unlink, tok)
					end)
				end
			end
		end
	end)
end

-- commit() returns:
--   'OK'    : published
--   'RETRY' : abandoned attempt (revoked/contended)
-- Any other condition is a bug (raises after best-effort abort).
function Txn:commit()
	local function do_commit()
		-- phase 0: key conflict scan (bug on duplicates)
		local seen = nil
		self:for_each(function (rec)
			local k = record_key(rec)
			if k ~= nil then
				seen = seen or {}
				if seen[k] then
					bugf('txn commit: duplicate record key: %s', tostring(k))
				end
				seen[k] = true
			end
		end)

		-- phase 1: validate
		local verdict = 'OK'
		self:for_each(function (rec)
			if verdict ~= 'OK' then return end
			if rec and rec.validate then
				local tag, err = rec.validate(rec)
				if tag == nil or tag == 'OK' then
					return
				elseif tag == 'RETRY' then
					verdict = 'RETRY'
					return
				else
					bugf('txn commit: validate returned invalid tag: %s (%s)',
						tostring(tag), tostring(err))
				end
			end
		end)

		if verdict == 'RETRY' then
			return 'RETRY'
		end

		-- phase 2: apply (publication point)
		self:for_each(function (rec)
			if rec and rec.apply then
				local tag, err = rec.apply(rec)
				if tag ~= nil and tag ~= 'OK' then
					bugf('txn commit: apply returned non-OK tag: %s (%s)',
						tostring(tag), tostring(err))
				end
			end
			-- Mark as committed irrespective of apply presence.
			if rec and type(rec) == 'table' then
				rec._committed = true
			end
		end)

		return 'OK'
	end

	local ok, tag_or_err = pcall(do_commit)

	if not ok then
		self:abort_all()
		error(tag_or_err, 0)
	end

	if tag_or_err == 'RETRY' then
		self:abort_all()
		return 'RETRY'
	end

	return 'OK'
end

----------------------------------------------------------------------
-- Bounded pools (shared by seq and all)
----------------------------------------------------------------------

-- Pool representation: t[head..#t] are live entries.
-- This keeps changes small and avoids shifting costs.
local function pool_new(max)
	return { t = {}, head = 1, max = max or 16 }
end

local function pool_len(p)
	local n = #p.t - p.head + 1
	return (n > 0) and n or 0
end

local function pool_get(p, i)
	local idx = p.head + i - 1
	return p.t[idx]
end

local function pool_compact(p)
	local t, h = p.t, p.head
	if h <= 1 then return end
	local out = {}
	for i = h, #t do
		out[#out + 1] = t[i]
		t[i] = nil
	end
	p.t = out
	p.head = 1
end

local function pool_push(p, v, drop_fn)
	local t = p.t
	t[#t + 1] = v

	-- Evict oldest if above cap.
	if pool_len(p) > p.max then
		local old = t[p.head]
		t[p.head] = nil
		p.head = p.head + 1
		if drop_fn and old ~= nil then drop_fn(old) end
	end

	-- Best-effort compaction when the head drifts.
	if p.head > 32 and p.head > (#t / 2) then
		pool_compact(p)
	end
end

-- Filter out entries matching pred anywhere in the pool.
local function pool_filter(p, pred, drop_fn)
	local t, h = p.t, p.head
	local out = {}
	for i = h, #t do
		local v = t[i]
		if v ~= nil and pred(v) then
			if drop_fn then drop_fn(v) end
		elseif v ~= nil then
			out[#out + 1] = v
		end
		t[i] = nil
	end
	p.t = out
	p.head = 1
end

----------------------------------------------------------------------
-- Frontier subscriptions: what must be armed to sleep safely
----------------------------------------------------------------------

---@class Subscription
---@field arm fun(task:table, waker:table, suspension:Suspension, seen:any): table|nil
-- arm(...) may return a token with .unlink(); if so, the kernel will unlink on wake/abort.

---@class Meta
---@field subs Subscription[]
local function meta_new()
	return { subs = {} }
end

local function meta_add(meta, sub)
	local s = meta.subs
	s[#s + 1] = sub
end

local function meta_merge(dst, src)
	if not src then return dst end
	if not dst then return src end
	local ds, ss = dst.subs, src.subs
	for i = 1, #ss do ds[#ds + 1] = ss[i] end
	return dst
end

-- Subscription constructors
local function sub_prim(prim, st, want)
	return {
		arm = function (task, waker, _suspension, _seen)
			return prim.block(prim, st, task, waker, want)
		end,
	}
end

local function sub_txn_watches(txn, want)
	return {
		arm = function (task, waker, suspension, seen)
			-- Txn:arm_watches already attaches unlink cleanups to the suspension.
			txn:arm_watches(task, waker, suspension, want, seen)
			return nil
		end,
	}
end

----------------------------------------------------------------------
-- Candidate accumulator
----------------------------------------------------------------------

-- acc.ready : { { txn=Txn, out=packed } ... }
-- acc.meta  : Meta|nil
local function acc_new()
	return { ready = {}, meta = nil, _seen_sub = nil }
end

local function acc_emit(acc, txn, out)
	acc.ready[#acc.ready + 1] = { txn = txn, out = out }
end

-- Dedup subscriptions per collect pass (so we do not re-arm the same interest repeatedly).
-- Keys are three-level to keep it cheap and flexible.
local function acc_subscribe(acc, k1, k2, k3, sub)
	acc.meta = acc.meta or meta_new()
	local seen = acc._seen_sub
	if not seen then
		seen = {}; acc._seen_sub = seen
	end

	k1 = k1 or false
	k2 = k2 or false
	k3 = k3 or false

	seen[k1] = seen[k1] or {}
	seen[k1][k2] = seen[k1][k2] or {}

	if seen[k1][k2][k3] then
		return
	end
	seen[k1][k2][k3] = true

	meta_add(acc.meta, sub)
end

local function acc_merge_meta(acc, m)
	acc.meta = meta_merge(acc.meta, m)
end

----------------------------------------------------------------------
-- Op nodes
----------------------------------------------------------------------

---@class Op
---@field kind '"prim"'|'"choice"'|'"seq"'|'"all"'
---@field poll fun(self:Op, txn:Txn, st:table): string, any...
---@field block fun(self:Op, st:table, task:table, waker:table, want:any): table|nil
---@field ops Op[]|nil
---@field left Op|nil
---@field k fun(...): Op|nil
local Op = {}
Op.__index = Op

local function prim(poll, block)
	if type(poll) ~= 'function' then error('op2.prim: poll must be a function', 2) end
	if type(block) ~= 'function' then error('op2.prim: block must be a function', 2) end
	return setmetatable({ kind = 'prim', poll = poll, block = block }, Op)
end

local function choice(...)
	local ops = { ... }
	return setmetatable({ kind = 'choice', ops = ops }, Op)
end

local function seq(a, k)
	return setmetatable({ kind = 'seq', left = a, k = k }, Op)
end

local function all(...)
	local ops = { ... }
	return setmetatable({ kind = 'all', ops = ops }, Op)
end

----------------------------------------------------------------------
-- Kernel dispatch
----------------------------------------------------------------------

local K = {}

local function collect(node, txn, st, acc, ctx)
	return K[node.kind].collect(node, txn, st, acc, ctx)
end

local function abort(node, txn, st)
	return K[node.kind].abort(node, txn, st)
end

----------------------------------------------------------------------
-- Primitive node
----------------------------------------------------------------------

-- poll(txn, st) -> 'READY', record_or_nil, ...preview
--               |  'WAIT', want?
--               |  'RETRY'
K.prim = {}

function K.prim.collect(op, txn, st, acc, _ctx)
	local r = pack(op.poll(op, txn, st))
	local tag = r[1]

	if tag == 'WAIT' then
		local want = r[2] or st.want or 'state'
		st.want = want

		-- 1) Primitive readiness registration (revocable).
		-- Dedup key: prim identity + st identity + want.
		acc_subscribe(acc, op, st, want, sub_prim(op, st, want))

		-- 2) Record-level watches for records already held in txn (revocation/state-change).
		-- Dedup key: 'txn' + txn identity + want.
		acc_subscribe(acc, 'txn', txn, want, sub_txn_watches(txn, want))

		return
	end

	if tag == 'RETRY' then
		return
	end

	if tag ~= 'READY' then
		bugf('invalid poll tag: %s', tostring(tag))
	end

	local rec = r[2]
	local out = { n = r.n - 2 }
	for i = 1, out.n do
		out[i] = r[2 + i]
	end

	-- Best-effort: pin preview onto record for debugging/auditing.
	if type(rec) == 'table' and rec._preview == nil then
		rec._preview = out
	end

	acc_emit(acc, txn:add(rec), out)
end

function K.prim.abort(_op, _txn, st)
	st.want = nil
	st_run_cleanups(st)
end

----------------------------------------------------------------------
-- seq (and_then): TE-style backtracking (bounded)
----------------------------------------------------------------------

K.seq = {}

local SEQ_CAND_LIMIT = 16

local function drop_seq_cand(c)
	if not c or c.dead then return end
	-- Abort child op state first, then discharge speculative records.
	-- Both are best-effort and idempotent under our invariants.
	if c.rop and c.rst and c.txn then
		safe.pcall(function () abort(c.rop, c.txn, c.rst) end)
	end
	if c.txn then
		safe.pcall(function () c.txn:abort_all() end)
	end
	c.dead = true
end

-- st:
--   left_st     : table
--   cands       : pool of { txn=Txn, rop=Op, rst=table, dead=bool }
--   left_epoch  : integer|nil   -- de-dup left candidate ingestion within an epoch
function K.seq.collect(op, boundary_txn, st, acc, ctx)
	st.left_st    = st.left_st or {}
	st.cands      = st.cands or pool_new(SEQ_CAND_LIMIT)
	st.left_epoch = st.left_epoch

	-- Prune spent/dead candidates.
	pool_filter(st.cands, function (c)
		return (not c) or c.dead or (c.txn and c.txn._spent)
	end, drop_seq_cand)

	-- 1) Advance right side for existing left-candidates.
	for i = 1, pool_len(st.cands) do
		local c = pool_get(st.cands, i)
		if c and not c.dead then
			local sub = acc_new()
			collect(c.rop, c.txn, c.rst, sub, ctx)
			acc_merge_meta(acc, sub.meta)
			for j = 1, #sub.ready do
				local cand = sub.ready[j]
				acc_emit(acc, cand.txn, cand.out)
			end
		end
	end

	-- 2) Ingest new left candidates at most once per wake epoch.
	-- This prevents unbounded duplication when the left side is persistently READY
	-- and perform() re-collects without sleeping.
	if st.left_epoch ~= ctx.epoch then
		st.left_epoch = ctx.epoch

		local left_acc = acc_new()
		collect(op.left, boundary_txn, st.left_st, left_acc, ctx)
		acc_merge_meta(acc, left_acc.meta)

		for i = 1, #left_acc.ready do
			local lc  = left_acc.ready[i]
			local rop = op.k(unpack(lc.out, 1, lc.out.n))

			-- Defensive: allow k() to return nil to mean “dead end”.
			if rop ~= nil then
				pool_push(st.cands, { txn = lc.txn, rop = rop, rst = {}, dead = false }, drop_seq_cand)
			end
		end
	end
end

function K.seq.abort(op, boundary_txn, st)
	if st.left_st then
		abort(op.left, boundary_txn, st.left_st)
	end

	if st.cands then
		-- Discharge all candidates and drop references.
		for i = 1, pool_len(st.cands) do
			local c = pool_get(st.cands, i)
			drop_seq_cand(c)
		end
	end

	st.left_st, st.cands, st.left_epoch = {}, pool_new(SEQ_CAND_LIMIT), nil
end

----------------------------------------------------------------------
-- Helpers for choice/all arms
----------------------------------------------------------------------

local function new_arm(boundary_txn, extra)
	local a = { st = {}, txn = boundary_txn:fork(), dead = false }
	if extra then
		for k, v in pairs(extra) do a[k] = v end
	end
	return a
end

local function init_arms(boundary_txn, ops, mk_extra)
	local arms = {}
	for i = 1, #ops do
		arms[i] = new_arm(boundary_txn, mk_extra and mk_extra(i) or nil)
	end
	return arms
end

----------------------------------------------------------------------
-- choice: TE-style (non-greedy)
----------------------------------------------------------------------

K.choice = {}

-- st:
--   rr   : integer  -- fairness cursor (candidate emission order)
--   arms : { { st={}, txn=Txn, dead=bool } ... }
function K.choice.collect(op, boundary_txn, st, acc, ctx)
	st.rr   = st.rr or 1
	st.arms = st.arms or init_arms(boundary_txn, op.ops)

	local n = #op.ops
	for k = 0, n - 1 do
		local i     = ((st.rr + k - 1) % n) + 1
		local arm_s = st.arms[i]
		local child = op.ops[i]

		if arm_s and not arm_s.dead then
			local sub = acc_new()
			collect(child, arm_s.txn, arm_s.st, sub, ctx)
			acc_merge_meta(acc, sub.meta)

			for j = 1, #sub.ready do
				local cand = sub.ready[j]
				acc_emit(acc, cand.txn, cand.out)
			end
		end
	end

	-- Rotate the fairness cursor each collection pass.
	st.rr = (st.rr % n) + 1
end

function K.choice.abort(op, _txn, st)
	if not st.arms then return end
	for i = 1, #op.ops do
		local arm_s = st.arms[i]
		if arm_s and not arm_s.dead then
			abort(op.ops[i], arm_s.txn, arm_s.st)
			arm_s.txn:abort_all()
			arm_s.dead = true
		end
		st.arms[i] = nil
	end
	st.arms, st.rr = nil, nil
end

----------------------------------------------------------------------
-- all: non-greedy join (bounded per-arm candidate pools)
----------------------------------------------------------------------

K.all = {}

local ALL_ARM_POOL_LIMIT   = 16
local ALL_EMIT_PER_COLLECT = 1

local function drop_all_cand(c)
	if not c then return end
	if c.txn then
		safe.pcall(function () c.txn:abort_all() end)
	end
end

local function arm_pool_len(arm)
	return arm and arm.pool and pool_len(arm.pool) or 0
end

-- Advance an odometer vector across per-arm pool lengths.
-- Returns true if advanced, false if wrapped fully.
local function odometer_advance(vec, lens, start_rr)
	local n = #lens
	local start = start_rr or 1

	for step = 0, n - 1 do
		local d = ((start + step - 1) % n) + 1
		local nextv = (vec[d] or 1) + 1
		if nextv <= lens[d] then
			vec[d] = nextv
			return true, (d % n) + 1
		end
		vec[d] = 1
	end

	return false, ((start % n) + 1)
end

function K.all.collect(op, boundary_txn, st, acc, ctx)
	st.rr   = st.rr or 1
	st.vec  = st.vec or nil
	st.arms = st.arms or init_arms(boundary_txn, op.ops, function ()
		return { pool = pool_new(ALL_ARM_POOL_LIMIT) }
	end)

	local n = #op.ops

	-- 1) Harvest candidates from each arm and prune spent ones.
	for i = 1, n do
		local a = st.arms[i]
		if a and not a.dead then
			-- Remove any spent candidates (anywhere in the pool).
			pool_filter(a.pool, function (c)
				return (not c) or (c.txn and c.txn._spent)
			end, drop_all_cand)

			-- Collect this arm’s op to obtain new candidates and meta frontier.
			local sub = acc_new()
			collect(op.ops[i], a.txn, a.st, sub, ctx)
			acc_merge_meta(acc, sub.meta)

			-- Admit all candidates into the bounded pool (evicting oldest).
			for j = 1, #sub.ready do
				local cand = sub.ready[j]
				pool_push(a.pool, { txn = cand.txn, out = cand.out }, drop_all_cand)
			end
		end
	end

	-- 2) Always watch existing candidates for revocation/state changes whilst waiting.
	for i = 1, n do
		local a = st.arms[i]
		if a and not a.dead then
			for j = 1, pool_len(a.pool) do
				local c = pool_get(a.pool, j)
				if c and c.txn then
					acc_subscribe(acc, 'txn', c.txn, 'any', sub_txn_watches(c.txn, 'any'))
				end
			end
		end
	end

	-- 3) If any arm lacks candidates, we cannot emit a joined candidate.
	local lens = {}
	for i = 1, n do
		local a = st.arms[i]
		lens[i] = arm_pool_len(a)
		if lens[i] == 0 then
			return
		end
	end

	-- 4) Initialise (or repair) the odometer vector.
	local vec = st.vec
	if not vec then
		vec = {}
		for i = 1, n do vec[i] = 1 end
		st.vec = vec
	else
		for i = 1, n do
			if vec[i] == nil or vec[i] < 1 or vec[i] > lens[i] then
				vec[i] = 1
			end
		end
	end

	-- 5) Emit at most ALL_EMIT_PER_COLLECT joined candidates per pass.
	for _ = 1, ALL_EMIT_PER_COLLECT do
		local txns = {}
		local outs = {}

		for i = 1, n do
			local a = st.arms[i]
			local c = pool_get(a.pool, vec[i])
			if not c then
				-- Pool changed unexpectedly; restart from a safe vector next time.
				for k = 1, n do vec[k] = 1 end
				return
			end
			txns[i] = c.txn
			outs[i] = c.out
		end

		local merged = boundary_txn:merge_in_order(txns)
		acc_emit(acc, merged, pack(outs))

		local advanced, next_rr = odometer_advance(vec, lens, st.rr)
		st.rr = next_rr or st.rr
		if not advanced then
			-- Wrapped: next pass will re-emit from (1..1). That is acceptable;
			-- bounded pools + commit/RETRY provide the interference discipline.
			break
		end
	end
end

function K.all.abort(op, boundary_txn, st)
	if not st.arms then return end

	for i = 1, #op.ops do
		local a = st.arms[i]
		if a and not a.dead then
			abort(op.ops[i], a.txn, a.st)

			-- Discharge pooled candidates (eviction-style).
			if a.pool then
				for j = 1, pool_len(a.pool) do
					local c = pool_get(a.pool, j)
					drop_all_cand(c)
				end
			end

			a.txn:abort_all()
			a.dead = true
		end
		st.arms[i] = nil
	end

	st.arms, st.rr, st.vec = nil, nil, nil
end

----------------------------------------------------------------------
-- Sleep on frontier (restartable, lost-wakeup safe)
----------------------------------------------------------------------

local function sleep_on_frontier(meta, ev, boundary_txn, root_st, ctx)
	runtime.suspend(function (sched, fib)
		local suspension = new_suspension(sched, fib)
		local waker      = new_waker(suspension)

		-- Used to de-dup record.watch per suspension.
		local seen_records = {}

		local task = {
			run = function ()
				if suspension:waiting() then
					suspension:complete(id_wrap) -- wake outer loop to re-collect
				end
			end,
		}

		local subs = meta and meta.subs or nil
		if subs and #subs > 0 then
			for i = 1, #subs do
				local sub = subs[i]
				if sub and sub.arm then
					local tok = sub.arm(task, waker, suspension, seen_records)
					if tok and tok.unlink and suspension:waiting() then
						suspension:add_cleanup(function ()
							safe.pcall(tok.unlink, tok)
						end)
					end
				end
				if not suspension:waiting() then return end
			end
		else
			-- Defensive: no frontier; avoid deadlock.
			waker:wakeup(task)
		end

		-- Lost-wakeup avoidance: re-collect after arming.
		local acc2 = acc_new()
		collect(ev, boundary_txn, root_st, acc2, ctx)
		if #acc2.ready > 0 and suspension:waiting() then
			suspension:complete(id_wrap)
		end
	end)
end

----------------------------------------------------------------------
-- perform loop (restartable + backtracking)
----------------------------------------------------------------------

local function perform(ev)
	if not runtime.current_fiber() then
		error('op2.perform must run inside a fibre', 2)
	end

	local boundary_txn = txn_new({}, {}, 0)
	local root_st      = {}
	local ctx          = { epoch = 0 }

	-- Ensure speculative state is discharged on any exit path.
	local function cleanup()
		safe.pcall(function ()
			abort(ev, boundary_txn, root_st)
		end)
	end

	local ok, out_or_err = safe.xpcall(function ()
		while true do
			local acc = acc_new()
			collect(ev, boundary_txn, root_st, acc, ctx)

			-- Try candidates (simple policy: in emission order).
			for i = 1, #acc.ready do
				local c = acc.ready[i]
				local verdict = c.txn:commit()
				if verdict == 'OK' then
					-- Discharge remaining speculative state; committed records are protected.
					abort(ev, boundary_txn, root_st)
					return c.out
				end
				-- 'RETRY': try the next candidate; outer loop will re-collect if needed.
			end

			-- None committed: sleep until the frontier says “state may have changed”.
			sleep_on_frontier(acc.meta, ev, boundary_txn, root_st, ctx)
			ctx.epoch = ctx.epoch + 1
		end
	end, function (e, _tb)
		return e
	end)

	-- On success, state was already discharged; this is idempotent.
	cleanup()

	if not ok then
		error(out_or_err, 0)
	end

	local out = out_or_err
	return unpack(out, 1, out.n)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
	pack    = pack,
	prim    = prim,
	choice  = choice,
	seq     = seq,
	all     = all,
	perform = perform,

	add_cleanup = st_add_cleanup,

	-- Expose Op for type checks if you want them elsewhere.
	Op  = Op,
	Txn = Txn,
}
