local Resource = require('et.resources.protocol')
local Candidate = require('et.algebra.candidate')
local ConsequenceSet = require('et.consequence.set')
local World = require('et.solver.world')

local Plan = {}
local PLAN_TOKEN = {}

local function append_unique(dst, src)
  if not src or #src == 0 then return dst end
  dst = dst or {}
  for i = 1, #src do
    local x, seen = src[i], false
    for j = 1, #dst do if dst[j] == x then seen = true; break end end
    if not seen then dst[#dst + 1] = x end
  end
  return dst
end

local function same_waiting(cursor, rt)
  if not cursor then return true end
  if cursor.rt ~= rt or cursor.epoch ~= (rt._epoch or 0) then return false end
  local waiting = rt:_waiting()
  if #waiting ~= #cursor.waiting then return false end
  for i = 1, #waiting do
    if waiting[i] ~= cursor.waiting[i] then return false end
    if waiting[i].waiting ~= cursor.requests[i] then return false end
  end
  return true
end

local function add_resume(plan, i, n, c)
  local vals = Candidate.resolve_pack(c.vals, c.subst)
  local post = c.post
  if n == 1 then
    plan.fiber = c.fiber
    plan.vals = vals
    plan.post = post
  else
    local fibres = plan.fibres
    if not fibres then
      fibres = {}; plan.fibres = fibres; plan.vals_list = {}; plan.post_list = {}
    end
    fibres[i] = c.fiber
    plan.vals_list[i] = vals
    plan.post_list[i] = post
  end
end

local function fill_from_combo(plan, combo)
  local n = #combo
  for i = 1, n do
    local c = combo[i]
    plan.selected_nacks = append_unique(plan.selected_nacks, c.selected_nacks)
    plan.lost_nacks = append_unique(plan.lost_nacks, c.lost_nacks)
    add_resume(plan, i, n, c)
  end
  return plan
end

local function merge_resource_derived(set, derived)
  if not derived then return set end
  set = set or ConsequenceSet.empty()
  local ok, err = set:merge(derived)
  if not ok then return nil, err end
  return set
end

function Plan.is_plan(x)
  return x and x._token == PLAN_TOKEN and x.tag == 'commit-plan'
end

function Plan.try_from_world(rt, world, cursor)
  if not World.is_committable(world) then return nil, 'world-not-certified' end
  if not same_waiting(cursor, rt) then return nil, 'stale-cursor' end

  local combo = world.combo
  local prepared_resources, reason, derived_consequences = Resource.prepare_combo(combo, Candidate.raw_resolved, Candidate.resolve)
  if reason then return nil, reason or 'resource-not-fresh' end

  local consequence_set, cerr = Candidate.merge_consequence_combo(combo)
  if cerr then return nil, cerr end
  consequence_set, cerr = merge_resource_derived(consequence_set, derived_consequences)
  if cerr then return nil, cerr end

  local prepared_consequences
  if consequence_set and not consequence_set:is_empty() then
    prepared_consequences, reason = consequence_set:prepare(rt)
    if reason then return nil, reason end
  end

  return fill_from_combo({
    _token = PLAN_TOKEN,
    tag = 'commit-plan',
    prepared_resources = prepared_resources,
    prepared_consequences = prepared_consequences,
  }, combo)
end

function Plan.always(fiber)
  return {
    _token = PLAN_TOKEN,
    tag = 'commit-plan',
    fiber = fiber,
    vals = fiber.waiting.op.vals,
  }
end

return Plan
