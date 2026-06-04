package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('et.op')
local Runtime = require('et.runtime')
local Link = require('et.protocol').Link
local Result = require('et.machine.kernel').Status
local Phase = require('et.machine.kernel').Phase
local Util = require('et.machine.kernel').Util
local Consequence = require('et.machine.frontier').Consequence

local function assert_eq(actual, expected, msg)
  if actual ~= expected then error((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2) end
end

local function assert_status(x, tag, msg)
  if not x or x.tag ~= tag then error((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(x and x.tag), 2) end end

local function final_merge_value(self, snap, request, ctx)
  local fragments = request.fragments or {}
  if request.kind == 'project' then
    local base, full = request.base, fragments[1]
    if base.base_version ~= snap.version or full.base_version ~= snap.version then return ctx:stale({ self }, 'final stale') end
    if full.written and full.value ~= base.value then return { base_version = snap.version, value = full.value, written = true } end
    return nil
  elseif request.kind == 'extend' then
    local prefix = request.base
    for i=1,#fragments do
      local delta = fragments[i]
      if prefix.base_version ~= snap.version or delta.base_version ~= snap.version then return ctx:stale({ self }, 'final stale') end
      if delta.written then prefix = { base_version = snap.version, value = delta.value, written = true } end
    end
    return prefix
  end
  local acc = nil
  for i=1,#fragments do
    local f = fragments[i]
    if acc == nil then acc = f
    else
      if acc.base_version ~= snap.version or f.base_version ~= snap.version then return ctx:stale({ self }, 'final stale') end
      if acc.written and f.written and acc.value ~= f.value then return ctx:conflict('conflicting final writes') end
      if f.written then acc = f end
    end
  end
  return acc
end

local Final = Link.resource {
  name = 'final',
  construct = function(self, label)
    self.id = label or 'final'; self.version = 0; self.value = 0
  end,
  snapshot = function(self) return { resource = self, version = self.version, value = self.value } end,
  initial = function(_self, snap) return { base_version = snap.version, value = snap.value, written = false } end,
  claim = function(self, snap, fragment, claim, ctx)
    if fragment.base_version ~= snap.version then return ctx:stale({ self }, 'final stale') end
    local request = claim.request or claim.payload or claim
    return ctx:accept({ base_version = snap.version, value = request.value, written = true }, request.value)
  end,
  merge = final_merge_value,
  prepare = function(self, fragment, ctx)
    if fragment.base_version ~= self.version then return ctx:stale({ self }, 'final prepare stale') end
    local res, target, written = self, fragment.value, fragment.written
    return ctx:prepared({
      resource = res,
      dirty = written and { res } or {},
      consequences = { transaction = {}, resource = written and { { kind = 'publish', key = res.id, value = target } } or {}, obligation = {} },
      apply = function(commit_token)
        Phase.require(commit_token, 'commit')
        if written then res.value = target; res.version = res.version + 1 end
      end,
    })
  end,
}
function Final:set_op(OpModule, value) return OpModule.access(self, { tag = 'set', value = value }) end

local function touched_merge(self, snap, request, ctx)
  local fragments = request.fragments or {}
  if request.kind == 'project' then
    local full = fragments[1]
    return full and full.touched and full or nil
  end
  local acc = request.base
  for i=1,#fragments do
    local f = fragments[i]
    if acc == nil or (f and f.touched) then acc = f end
  end
  return acc
end

local WakeDup = Link.resource {
  name = 'wake-dup',
  construct = function(self, label) self.id = label or 'wake-dup'; self.version = 0 end,
  snapshot = function(self) return { resource = self, version = self.version } end,
  initial = function(_self, snap) return { base_version = snap.version, touched = false } end,
  claim = function(self, snap, fragment, _claim, ctx)
    if fragment.base_version ~= snap.version then return ctx:stale({ self }, 'wake stale') end
    return ctx:accept({ base_version = snap.version, touched = true }, true)
  end,
  merge = touched_merge,
  prepare = function(self, fragment, ctx)
    local res = self
    return ctx:prepared({
      resource = res,
      dirty = fragment.touched and { res } or {},
      consequences = { transaction = {}, resource = { { kind = 'wake', key = res.id }, { kind = 'wake', key = res.id } }, obligation = {} },
      apply = function(commit_token) Phase.require(commit_token, 'commit'); res.version = res.version + 1 end,
    })
  end,
}
function WakeDup:touch_op(OpModule) return OpModule.access(self, { tag = 'touch' }) end

local BadKind = Link.resource {
  name = 'bad-kind',
  construct = function(self, label) self.id = label or 'bad-kind'; self.version = 0 end,
  snapshot = function(self) return { resource = self, version = self.version } end,
  initial = function(_self, snap) return { base_version = snap.version, touched = false } end,
  claim = function(self, snap, fragment, _claim, ctx)
    if fragment.base_version ~= snap.version then return ctx:stale({ self }, 'bad-kind stale') end
    return ctx:accept({ base_version = snap.version, touched = true }, true)
  end,
  merge = touched_merge,
  prepare = function(self, fragment, ctx)
    local res = self
    return ctx:prepared({
      resource = res,
      dirty = fragment.touched and { res } or {},
      consequences = { transaction = {}, resource = { { kind = 'unknown-resource-kind', key = res.id } }, obligation = {} },
      apply = function(commit_token) Phase.require(commit_token, 'commit'); res.version = res.version + 1 end,
    })
  end,
}
function BadKind:touch_op(OpModule) return OpModule.access(self, { tag = 'touch' }) end

local function test_losing_branch_consequences_absent()
  local rt = Runtime.new()
  local result
  rt:spawn(function()
    result = rt:perform(Op.choice(Op.emit({ tag = 'winner' }):and_then(function() return Op.always('winner') end), Op.emit({ tag = 'loser' }):and_then(function() return Op.always('loser') end)))
  end, 'm8-losing')
  assert_status(rt:run(), 'found')
  assert_eq(result, 'winner')
  assert_eq(#rt.published_consequences, 1)
  assert_eq(rt.published_consequences[1].transaction[1].tag, 'winner')
  assert_eq(rt.published_consequences[1].transaction[2], nil, 'losing branch consequence absent')
end

local function test_explicit_transaction_consequences_ordered()
  local rt = Runtime.new()
  rt:spawn(function()
    rt:perform(Op.emit({ tag = 'first' }):and_then(function() return Op.emit({ tag = 'second' }) end))
  end, 'm8-order')
  assert_status(rt:run(), 'found')
  local log = rt.published_consequences[1]
  assert_eq(log.transaction[1].tag, 'first')
  assert_eq(log.transaction[2].tag, 'second')
end

local function test_resource_consequence_derived_from_final_commit()
  local rt = Runtime.new()
  local r = Final.new('m8-final')
  rt:spawn(function()
    rt:perform(r:set_op(Op, 1):and_then(function() return r:set_op(Op, 2) end))
  end, 'm8-final-root')
  assert_status(rt:run(), 'found')
  assert_eq(r.value, 2)
  local rc = rt.published_consequences[1].resource[1]
  assert_eq(rc.kind, 'publish')
  assert_eq(rc.value, 2, 'resource consequence reflects final prepared fragment')
end

local function test_duplicate_wake_collapses()
  local rt = Runtime.new()
  local r = WakeDup.new('m8-wake')
  rt:spawn(function() rt:perform(r:touch_op(Op)) end, 'm8-wake-root')
  assert_status(rt:run(), 'found')
  local log = rt.published_consequences[1]
  assert_eq(#log.resource, 1, 'duplicate wake consequences are collapsed')
  assert_eq(log.resource[1].kind, 'wake')
end



local function test_incompatible_duplicate_wake_conflicts()
  local st = Consequence.normalise({
    transaction = {},
    resource = {
      { kind = 'wake', key = 'wait-1', reason = 'a' },
      { kind = 'wake', key = 'wait-1', reason = 'b' },
    },
    obligation = {},
  })
  assert_eq(st.tag, 'conflict', 'idempotent consequences with same key but incompatible payload conflict')
end

local function test_resource_consequence_normalisation_failure_rejects_before_commit()
  local rt = Runtime.new({ quiet_deadlock = true })
  local r = BadKind.new('m8-bad-kind')
  local got
  rt:spawn(function() got = rt:perform(r:touch_op(Op)) end, 'm8-bad-kind-root')
  local st = rt:run()
  assert_eq(st.tag, 'absent', 'candidate with unknown resource consequence is rejected, not committed')
  assert_eq(r.version, 0, 'resource was not committed after consequence normalisation failure')
  assert_eq(got, nil, 'participant was not resumed')
end

local function test_consequence_observer_cannot_mutate_published_log()
  local rt = Runtime.new({
    on_consequence = function(log)
      log.transaction[1].tag = 'mutated'
      log.resource[1] = { kind = 'publish', key = 'evil', value = 'mutated' }
    end,
  })
  local r = Final.new('m8-observer-copy')
  rt:spawn(function()
    rt:perform(Op.emit({ tag = 'stable' }):and_then(function() return r:set_op(Op, 9) end))
  end, 'm8-observer-copy-root')
  assert_status(rt:run(), 'found')
  assert_eq(rt.published_consequences[1].transaction[1].tag, 'stable', 'stored transaction log is immutable from observer mutation')
  assert_eq(rt.published_consequences[1].resource[1].key, r.id, 'stored resource log is immutable from observer mutation')
end

local function test_duplicate_settlement_conflicts_by_key()
  local st = Consequence.normalise({
    transaction = {},
    resource = {},
    obligation = {
      { kind = 'settlement', id = 'ob-1', reason = 'a' },
      { kind = 'settlement', id = 'ob-1', reason = 'a' },
    },
  })
  assert_eq(st.tag, 'conflict', 'duplicate settlement conflicts by obligation id')
end

return function()
  test_losing_branch_consequences_absent()
  test_explicit_transaction_consequences_ordered()
  test_resource_consequence_derived_from_final_commit()
  test_duplicate_wake_collapses()
  test_incompatible_duplicate_wake_conflicts()
  test_resource_consequence_normalisation_failure_rejects_before_commit()
  test_consequence_observer_cannot_mutate_published_log()
  test_duplicate_settlement_conflicts_by_key()
  print('milestone 8 normalised consequence tests: ok')
end
