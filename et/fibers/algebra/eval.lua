local Op = require('fibers.op')
local Summary = require('fibers.algebra.summary')
local Result = require('fibers.algebra.result')
local Candidate = require('fibers.algebra.candidate')
local Rendezvous = require('fibers.solver.rendezvous')

local Eval = {}
local unpack_ = table.unpack or unpack
local pack_ = Op._pack
local next_nack = 0
local EMPTY_PREF = {}

local list_append = Candidate.list_append
local list_copy = Candidate.list_copy
local unique_append = Candidate.unique_append
local raw_resolved = Candidate.raw_resolved
local resolve_pack = Candidate.resolve_pack
local candidate = Candidate.new
local empty_candidate = Candidate.empty
local ctx_with_overlay = Candidate.ctx_with_overlay
local combine_seq = Candidate.combine_seq
local combine_parallel = Candidate.combine_parallel

local eval_op -- forward

local function child_ctx(ctx, _seg)
  -- Residual identities are node/fibre/count based, so ordinary child
  -- evaluation can share the same context table.  Candidate-specific overlays
  -- are still introduced explicitly via ctx_with_overlay.
  return ctx
end

local function residual_id(ctx, node)
  local counts = ctx.residual_counts
  if not counts then
    counts = {}
    ctx.residual_counts = counts
  end
  local base = tostring(ctx.fiber_id or '?') .. ':' .. tostring(node._id or node)
  local n = (counts[base] or 0) + 1
  counts[base] = n
  return base .. ':' .. tostring(n)
end

local function residual_is_open(ctx, id)
  local open = ctx.residual_open
  return open and open[id]
end

local function call_callback(ctx, phase, kind, fn, ...)
  local rt = ctx and ctx.rt
  if rt and rt._call_in_phase then
    return rt:_call_in_phase(phase, kind or 'callback_error', fn, ...)
  end
  return fn(...)
end


local function compose_post(old_post, fn)
  return function(vals)
    if old_post then vals = old_post(vals) end
    return pack_(fn(unpack_(vals, 1, vals.n)))
  end
end

local function product_post(lane_posts)
  local any = false
  for i = 1, #lane_posts do
    if lane_posts[i] then any = true; break end
  end
  if not any then return nil end
  return function(vals)
    local rows = vals[1] or {}
    local out_rows = {}
    for i = 1, #rows do
      local row = rows[i]
      local post = lane_posts[i]
      if post then row = post(row) end
      out_rows[i] = row
    end
    return pack_(out_rows)
  end
end

local function process_one_deferred(c, ctx)
  if #c.deferred == 0 then return nil end
  local d = c.deferred[1]
  if not raw_resolved(c.vals, c.subst) then return nil end
  table.remove(c.deferred, 1)
  local tail = list_copy(c.deferred)
  c.deferred = {}
  local vals = resolve_pack(c.vals, c.subst)
  local dctx = d.ctx or ctx
  if d.kind == 'map' then
    if c.post then error('map cannot consume a post-commit wrapped value', 2) end
    c.vals = pack_(call_callback(dctx, 'map', 'callback_error', d.fn, unpack_(vals, 1, vals.n)))
    c.deferred = tail
    return Result.cands({ c })
  elseif d.kind == 'bind' then
    if c.post then error('and_then cannot consume a post-commit wrapped value', 2) end
    local op2 = call_callback(dctx, 'bind', 'callback_error', d.fn, unpack_(vals, 1, vals.n))
    local r = eval_op(op2, ctx_with_overlay(dctx, c))
    local out = {}
    for i = 1, #r.cands do
      out[#out + 1] = combine_seq(c, r.cands[i], tail)
    end
    local rr = Result.cands(out)
    rr = Result.add_waits(rr, r.waits)
    rr = Result.add_protected(rr, r.protected_nacks)
    rr = Result.add_residuals(rr, r.residuals)
    if not Result._empty(r.waits) then rr = Result.add_protected(rr, c.protected_nacks) end
    return rr
  else
    error('unknown deferred kind ' .. tostring(d.kind))
  end
end

local function normalise_result(r, ctx)
  r = Result.from(r)
  local cands = r.cands

  -- Hot path: most candidates have no immediately runnable deferred work.
  -- Return the existing result object unchanged and avoid allocating an output
  -- candidate list or empty wait/protected tables.
  local runnable = false
  for i = 1, #cands do
    if #(cands[i].deferred or EMPTY_PREF) > 0 and raw_resolved(cands[i].vals, cands[i].subst) then
      runnable = true
      break
    end
  end
  if not runnable then return r end

  local waits = Result._empty(r.waits) and nil or list_copy(r.waits)
  local protected = Result._empty(r.protected_nacks) and nil or list_copy(r.protected_nacks)
  local residuals = Result._empty(r.residuals) and nil or list_copy(r.residuals)
  local changed = true
  while changed do
    changed = false
    local out = {}
    for i = 1, #cands do
      local branches = process_one_deferred(cands[i], ctx)
      if branches then
        changed = true
        list_append(out, branches.cands)
        waits = Result._unique_append(waits, branches.waits)
        protected = Result._unique_append(protected, branches.protected_nacks)
        residuals = Result._unique_append(residuals, branches.residuals)
      else
        out[#out + 1] = cands[i]
      end
    end
    cands = out
  end
  return Result.new(cands, waits, protected, residuals)
end


local function lost_from_result(r)
  local xs = {}
  if r then unique_append(xs, r.protected_nacks) end
  for i = 1, #(r and r.cands or {}) do unique_append(xs, r.cands[i].protected_nacks) end
  return xs
end

local function eval_product(node, ctx, allow_internal)
  local lane_lists = {}
  local waits, protected, residuals = nil, nil, nil
  for i = 1, #node.lanes do
    local subctx = {}
    for k, v in pairs(ctx) do subctx[k] = v end
    subctx.origin = i
    local r = normalise_result(eval_op(node.lanes[i], subctx), subctx)
    waits = Result._unique_append(waits, r.waits)
    protected = Result._unique_append(protected, r.protected_nacks)
    residuals = Result._unique_append(residuals, r.residuals)
    if #r.cands == 0 then return Result.new(nil, waits, protected, residuals) end
    lane_lists[i] = r.cands
  end
  local out = {}
  local function rec(i, acc, rows)
    if i > #lane_lists then
      acc.vals = pack_(rows)
      if acc._lane_posts then
        acc.post = product_post(acc._lane_posts)
        acc._lane_posts = nil
      end
      if allow_internal then
        Rendezvous.internal_close(acc)
        local r = normalise_result(Result.cands({ acc }), ctx)
        waits = Result._unique_append(waits, r.waits)
        protected = Result._unique_append(protected, r.protected_nacks)
        residuals = Result._unique_append(residuals, r.residuals)
        for j = 1, #r.cands do
          Rendezvous.internal_close(r.cands[j])
          out[#out + 1] = r.cands[j]
        end
      else
        out[#out + 1] = acc
      end
      return
    end
    for j = 1, #lane_lists[i] do
      local lane = lane_lists[i][j]
      local merged = combine_parallel(acc, lane)
      if merged then
        local nr = list_copy(rows)
        nr[i] = lane.vals
        if acc._lane_posts or lane.post then
          local lane_posts = list_copy(acc._lane_posts)
          lane_posts[i] = lane.post
          merged._lane_posts = lane_posts
        end
        rec(i + 1, merged, nr)
      end
    end
  end
  rec(1, empty_candidate(), {})
  return Result.new(out, waits, protected, residuals)
end

local function lost_from(cands)
  return lost_from_result(Result.cands(cands))
end

function eval_op(node, ctx)
  local k = node.kind
  if k == 'always' then
    return Result.cands({ candidate(node.vals) })
  elseif k == 'never' then
    return Result.none()
  elseif k == 'emit' then
    local c = candidate(pack_(true))
    local ok, err = Candidate.add_consequence(c, node.consequence)
    if not ok then return Result.none() end
    return Result.cands({ c })
  elseif k == 'prim' then
    local p = node.prim
    if p == 'resource' then
      local kind = node.resource_kind
      local eval = kind and kind.eval
      if not eval then error('resource primitive requires kind.eval', 2) end
      return eval(node.resource, node.payload, ctx)
    else
      error('unknown primitive ' .. tostring(p))
    end
  elseif k == 'map' then
    local subctx = child_ctx(ctx, 'map')
    local r = normalise_result(eval_op(node.p, subctx), subctx)
    for i = 1, #r.cands do
      if r.cands[i].post then error('map cannot be applied after wrap', 2) end
      if raw_resolved(r.cands[i].vals, r.cands[i].subst) then
        local vals = resolve_pack(r.cands[i].vals, r.cands[i].subst)
        r.cands[i].vals = pack_(call_callback(subctx, 'map', 'callback_error', node.fn, unpack_(vals, 1, vals.n)))
      else
        r.cands[i].deferred[#r.cands[i].deferred + 1] = { kind = 'map', fn = node.fn }
      end
    end
    return r
  elseif k == 'bind' then
    local left_ctx = child_ctx(ctx, 'bind:p')
    local r = normalise_result(eval_op(node.p, left_ctx), left_ctx)
    local out = {}
    for i = 1, #r.cands do
      local c = r.cands[i]
      if c.post then error('and_then cannot be applied after wrap', 2) end
      if raw_resolved(c.vals, c.subst) then
        local vals = resolve_pack(c.vals, c.subst)
        local p2 = call_callback(left_ctx, 'bind', 'callback_error', node.fn, unpack_(vals, 1, vals.n))
        local subctx = ctx_with_overlay(child_ctx(ctx, 'bind:q'), c)
        local rr = normalise_result(eval_op(p2, subctx), subctx)
        for j = 1, #rr.cands do out[#out + 1] = combine_seq(c, rr.cands[j]) end
        r = Result.add_waits(r, rr.waits)
        r = Result.add_protected(r, rr.protected_nacks)
        r = Result.add_residuals(r, rr.residuals)
        if not Result._empty(rr.waits) then r = Result.add_protected(r, c.protected_nacks) end
      else
        c.deferred[#c.deferred + 1] = { kind = 'bind', fn = node.fn, ctx = child_ctx(ctx, 'bind:q') }
        out[#out + 1] = c
      end
    end
    return Result.new(out, r.waits, r.protected_nacks, r.residuals)
  elseif k == 'choice' then
    if #node.choices > 0 and (node.choices[1].kind == 'always' or node.choices[1].kind == 'emit') and Summary.decisive_without_resources(node.choices[1]) then
      local needs_losers = false
      for i = 2, #node.choices do if Summary.may_nack(node.choices[i]) then needs_losers = true; break end end
      if not needs_losers then return eval_op(node.choices[1], ctx) end
    end
    local branches = {}
    local all_lost = {}
    local waits, protected, residuals = nil, nil, nil
    for i = 1, #node.choices do
      local branch_ctx = child_ctx(ctx, 'choice:' .. tostring(i))
      branches[i] = normalise_result(eval_op(node.choices[i], branch_ctx), branch_ctx)
      all_lost[i] = lost_from_result(branches[i])
      waits = Result._unique_append(waits, branches[i].waits)
      protected = Result._unique_append(protected, branches[i].protected_nacks)
      residuals = Result._unique_append(residuals, branches[i].residuals)
    end
    local out = {}
    for i = 1, #branches do
      for j = 1, #branches[i].cands do
        local c = branches[i].cands[j]
        for b = 1, #branches do if b ~= i then unique_append(c.lost_nacks, all_lost[b]) end end
        out[#out + 1] = c
      end
    end
    return Result.new(out, waits, protected, residuals)
  elseif k == 'or_else' then
    local id = residual_id(ctx, node)
    if residual_is_open(ctx, id) then
      local right_ctx = child_ctx(ctx, 'orR')
      return normalise_result(eval_op(node.q, right_ctx), right_ctx)
    end

    local left_ctx = child_ctx(ctx, 'orL')
    local pr = normalise_result(eval_op(node.p, left_ctx), left_ctx)

    -- Local absence: the left branch has no current candidates, so there is no
    -- global world that can pass through it.  Enter the fallback immediately,
    -- discarding left waits, nacks and speculative structure.
    if #pr.cands == 0 then
      local right_ctx = child_ctx(ctx, 'orR')
      return normalise_result(eval_op(node.q, right_ctx), right_ctx)
    end

    -- The left has current candidates, so the solver must first give them the
    -- full global search.  The right branch is not evaluated unless a later
    -- residual environment opens this occurrence after proving absence-now.
    return Result.add_residual(pr, { id = id, order = ctx.residual_order or 0 })
  elseif k == 'guard' then
    local a = ctx.attempt
    if not a.guard_cache[node] then a.guard_cache[node] = call_callback(ctx, 'guard', 'callback_error', node.fn, ctx) end
    return eval_op(a.guard_cache[node], child_ctx(ctx, 'guard'))
  elseif k == 'with_nack' then
    local a = ctx.attempt
    local entry = a.nack_cache[node]
    if not entry then
      next_nack = next_nack + 1
      local ref = { _nack_ref = true, id = next_nack, state = 'pending' }
      local built = call_callback(ctx, 'with_nack', 'callback_error', node.fn, { obligation = ref })
      entry = { ref = ref, op = built }
      a.nack_cache[node] = entry
    end
    local nack_ctx = child_ctx(ctx, 'nack')
    local r = normalise_result(eval_op(entry.op, nack_ctx), nack_ctx)
    for i = 1, #r.cands do
      unique_append(r.cands[i].selected_nacks, { entry.ref })
      unique_append(r.cands[i].protected_nacks, { entry.ref })
    end
    if #r.cands == 0 then r = Result.add_protected(r, { entry.ref }) end
    return r
  elseif k == 'nack' then
    if node.ref and node.ref.state == 'lost' then return Result.cands({ candidate(pack_(true)) }) end
    return Result.none()
  elseif k == 'wrap' then
    local wrap_ctx = child_ctx(ctx, 'wrap')
    local r = normalise_result(eval_op(node.p, wrap_ctx), wrap_ctx)
    for i = 1, #r.cands do r.cands[i].post = compose_post(r.cands[i].post, node.fn) end
    return r
  elseif k == 'all' then
    return eval_product(node, ctx, false)
  elseif k == 'tensor' then
    return eval_product(node, ctx, true)
  else
    error('unknown op kind ' .. tostring(k))
  end
end


Eval.eval_op = eval_op
Eval.normalise_result = normalise_result
Eval.process_one_deferred = process_one_deferred
Eval.lost_from_result = lost_from_result
Eval.lost_from = lost_from
Eval.eval_product = eval_product

return Eval
