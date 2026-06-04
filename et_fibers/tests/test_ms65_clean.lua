package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Result = require('et.machine.kernel').Status
local Phase = require('et.machine.kernel').Phase
local Op = require('et.op')
local Runtime = require('et.runtime')
local Channel = require('et.resources.channel')
local Link = require('et.protocol').Link
local Util = require('et.machine.kernel').Util
local View = require('et.machine.frontier').View
local Frontier = require('et.machine.frontier').Frontier
local ProofSearch = require('et.machine.proofnet')
local CommitCertificate = require('et.machine.commit').Certificate
local Consequence = require('et.machine.frontier').Consequence

local function assert_eq(actual, expected, msg)
  if actual ~= expected then error((msg or 'assert_eq') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2) end
end

local function assert_status(x, tag, msg)
  if not x or x.tag ~= tag then error((msg or 'status') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(x and x.tag), 2) end
  return x.value
end

local next_log_id = 0

local function copy_frag(f)
  local out={ base_version=f.base_version, appends={} }
  for i=1,#(f.appends or {}) do out.appends[i]=f.appends[i] end
  return out
end

local function fragment_projection(snap, base, full, ctx)
  if base.base_version ~= snap.version or full.base_version ~= snap.version then return ctx:stale({snap.resource}, 'log fragment stale') end
  local out={ base_version=snap.version, appends={} }
  for i=#base.appends+1,#full.appends do out.appends[#out.appends+1]=full.appends[i] end
  if #out.appends == 0 then return nil end
  return out
end

local function fragment_extend(snap, prefix, delta, ctx)
  if prefix.base_version ~= snap.version or delta.base_version ~= snap.version then return ctx:stale({snap.resource}, 'log fragment stale') end
  local out=copy_frag(prefix)
  for i=1,#delta.appends do out.appends[#out.appends+1]=delta.appends[i] end
  return out
end

local function fragment_coexist(snap, left, right, ctx)
  if left == nil then return copy_frag(right) end
  if right == nil then return copy_frag(left) end
  if left.base_version ~= snap.version or right.base_version ~= snap.version then return ctx:stale({snap.resource}, 'log fragment stale') end
  local out=copy_frag(left)
  for i=1,#right.appends do out.appends[#out.appends+1]=right.appends[i] end
  return out
end

local Log = Link.resource {
  name = 'test-log',
  construct = function(self, label)
    next_log_id = next_log_id + 1
    self.id='log-'..next_log_id
    self.label=label or ('log-'..next_log_id)
    self.version=0
    self.records={}
  end,
  snapshot = function(self) return { resource=self, version=self.version, count=#self.records } end,
  initial = function(_self, snap) return { base_version=snap.version, appends={} } end,
  claim = function(_self, snap, fragment, claim, ctx)
    if fragment.base_version ~= snap.version then return ctx:stale({snap.resource}, 'log fragment stale') end
    local req = claim.request or claim.payload or claim
    if req.tag ~= 'append' then return ctx:fatal('unknown log request '..tostring(req.tag)) end
    local out=copy_frag(fragment)
    out.appends[#out.appends+1]=req.value
    return ctx:accept(out, true)
  end,
  merge = function(_self, snap, request, ctx)
    local kind = request.kind or 'coexist'
    local base = request.base
    local fragments = request.fragments or {}
    if kind == 'project' then
      return fragment_projection(snap, base, fragments[1], ctx)
    elseif kind == 'extend' then
      local acc = base
      for i=1,#fragments do
        local r = fragment_extend(snap, acc, fragments[i], ctx)
        if r and r.tag then return r end
        acc = r
      end
      return acc
    end
    local acc = nil
    for i=1,#fragments do
      acc = fragment_coexist(snap, acc, fragments[i], ctx)
      if acc and acc.tag then return acc end
    end
    return acc
  end,
  prepare = function(self, fragment, ctx)
    if fragment.base_version ~= self.version then return ctx:stale({self}, 'log fragment stale') end
    local log=self; local appends={}
    for i=1,#fragment.appends do appends[i]=fragment.appends[i] end
    return ctx:prepared({
      resource=log, fragment=fragment, dirty=#appends>0 and {log} or {}, consequences={transaction={},resource={},obligation={}},
      apply=function(commit_token)
        Phase.require(commit_token,'commit')
        for i=1,#appends do log.records[#log.records+1]=appends[i] end
        if #appends>0 then log.version=log.version+1 end
      end,
    })
  end,
}
function Log:append_op(value) return Op.access(self, { tag='append', value=value }) end

local function test_product_base_delta_law()
  local log=Log.new('product-base')
  local rt=Runtime.new()
  rt:spawn(function()
    rt:perform(log:append_op('base'):and_then(function()
      return Op.tensor({ log:append_op('lane'), Op.always('ok') })
    end))
  end, 'product-base')
  assert_status(rt:run(), 'found')
  assert_eq(#log.records, 2, 'product base is committed once')
  assert_eq(log.records[1], 'base')
  assert_eq(log.records[2], 'lane')
end

local function test_box_path_and_occurrence_lane_path_are_canonical()
  local ch=Channel.new('paths')
  local op=Op.tensor({ Op.all({ ch:put_op(Op,'x') }), Op.all({ ch:get_op(Op) }) })
  local view=View.open('paths-view')
  local frontier=assert_status(Frontier.expand_in_search(op,{id='paths-attempt'},view),'found')
  local frame=frontier.frames[1]
  assert_eq(#frame.open_claims,2)
  for i=1,#frame.open_claims do
    local p=frame.open_claims[i]
    assert_eq(#p.box_path, #p.origin.lane_path, 'open-claim box path and occurrence lane path length agree')
    for j=1,#p.box_path do
      assert_eq(p.box_path[j].box, p.origin.lane_path[j].box, 'box id order agrees')
      assert_eq(p.box_path[j].lane, p.origin.lane_path[j].lane, 'lane order agrees')
    end
    assert_eq(p.box_path[1].kind, 'tensor', 'outermost box is first')
    assert_eq(p.box_path[2].kind, 'all', 'innermost box is second')
  end
end

local function test_candidate_has_selected_operation_occurrences()
  local ch=Channel.new('selected-ops')
  local op=Op.tensor({ ch:put_op(Op,'x'), ch:get_op(Op), Op.emit({tag='publish', key='e1'}) })
  local view=View.open('selected-view')
  local frontier=assert_status(Frontier.expand_in_search(op,{id='selected-attempt'},view),'found')
  local cand=assert_status(Phase.with('search', function(token) return ProofSearch.find(frontier, view, token) end), 'found')
  local kinds={}
  for i=1,#cand.selected_occurrences do kinds[cand.selected_occurrences[i].kind]=true end
  assert(kinds.open_claim, 'selected open-claim occurrence present')
  assert(kinds.emit, 'selected emit occurrence present')
  assert(kinds.match, 'selected match occurrence present')
end


local function test_commit_certificate_consumes_candidate_selected_delta()
  local events={}
  local op=Op.emit({tag='selected-delta-event'}):and_then(function() return Op.always('ok') end)
  local view=View.open('selected-delta-view')
  local frontier=assert_status(Frontier.expand_in_search(op,{id='selected-delta-attempt'},view),'found')
  local cand=assert_status(Phase.with('search', function(token) return ProofSearch.find(frontier, view, token) end), 'found')
  assert(cand.selected_delta and cand.selected_delta.consequences, 'candidate exposes selected_delta')
  -- Scrub root-local evidence to prove certification consumes CandidateWorld.selected_delta,
  -- not recollected per-root evidence.
  for i=1,#cand.roots do cand.roots[i].evidence.consequences = Consequence.empty() end
  local cert=assert_status(CommitCertificate.try_build(cand),'found')
  for i=1,#cert.consequences.transaction do events[#events+1]=cert.consequences.transaction[i].tag end
  assert_eq(events[1], 'selected-delta-event', 'certificate consumes selected_delta consequences')
end

local function test_absence_certificate_is_explicit()
  local op=Op.never():or_else(Op.always('fallback'))
  local view=View.open('absence-cert-view')
  local frontier=assert_status(Frontier.expand_in_search(op,{id='absence-cert-attempt'},view),'found')
  local cand=assert_status(Phase.with('search', function(token) return ProofSearch.find(frontier, view, token) end), 'found')
  local cert=assert_status(CommitCertificate.try_build(cand),'found')
  assert_eq(#cert.absence_certificates, 1, 'fallback carries an absence certificate')
  assert_eq(cert.absence_certificates[1].tag, 'absence_certificate')
  assert(cert.absence_certificates[1].obligation_id, 'absence certificate names obligation')
end

local function test_no_observation_compatibility_module()
  package.loaded['et.observation']=nil
  local ok = pcall(require, 'et.observation')
  assert_eq(ok, false, 'Observation compatibility module has been removed')
end

return function()
  test_product_base_delta_law()
  test_box_path_and_occurrence_lane_path_are_canonical()
  test_candidate_has_selected_operation_occurrences()
  test_commit_certificate_consumes_candidate_selected_delta()
  test_absence_certificate_is_explicit()
  test_no_observation_compatibility_module()
  print('ms6.5 clean algebra tests: ok')
end
