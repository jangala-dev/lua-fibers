-- Machine world layer: selected-world semantics.
--
-- A CandidateWorld gives a closed proof-net selection semantic shape: selected
-- roots, matches, selected evidence, and event-structure-style configuration.

local Kernel = require('et.kernel')
local Protocol = require('et.protocol')
local FrontierLayer = require('et.machine.frontier')

local Status = Kernel.Status
local Util = Kernel.Util
local Phase = Kernel.Phase
local Origin = FrontierLayer.Origin

local Link = Protocol.Link
local View = FrontierLayer.View

local Frontier = FrontierLayer.Frontier
local Frame = FrontierLayer.Frame
local Evidence = FrontierLayer.Evidence

local Configuration, Candidate

-- from machine/configuration.lua
do
  Configuration = {}
  local Methods = {}
  Methods.__index = Methods

  local function copy_occurrence(o)
    if type(o) ~= 'table' then return o end
    local out = {}
    for k, v in pairs(o) do out[k] = v end
    if o.origin and Origin.is(o.origin) then out.origin = Origin.copy(o.origin) end
    if o.lane_path then out.lane_path = Origin.copy_boxes(o.lane_path) end
    if o.decision_prefix then out.decision_prefix = Origin.copy_list(o.decision_prefix) end
    if o.open_claim_origin_ids then out.open_claim_origin_ids = Util.copy_list(o.open_claim_origin_ids) end
    return out
  end

  local function event_id_for(occ, fallback)
    if occ.event_id then return occ.event_id end
    if occ.kind == 'match' then
      local ids = Util.copy_list(occ.open_claim_origin_ids or {})
      table.sort(ids)
      return 'match:' .. tostring(occ.match_kind or 'external') .. ':' .. table.concat(ids, '&')
    end
    return tostring(occ.kind or 'event') .. ':' .. tostring(occ.origin_id or occ.frame_id or fallback)
  end

  local function parse_decision(d)
    d = tostring(d or '')
    local label, branch = d:match('^(.*):([^:]*)$')
    return label or d, branch or ''
  end

  local function add_unique_edge(edges, seen, cause, effect, kind)
    if not cause or not effect or cause == effect then return end
    local key = tostring(cause) .. '=>' .. tostring(effect) .. ':' .. tostring(kind or 'cause')
    if seen[key] then return end
    seen[key] = true
    edges[#edges + 1] = { cause = cause, effect = effect, kind = kind or 'cause' }
  end

  function Configuration.from_selected(selected_occurrences, matches, key)
    local events, by_id, order = {}, {}, {}
    local event_by_origin = {}
    local decision_owner = {}
    local conflicts = {}

    local function add_event(occ, fallback)
      local id = event_id_for(occ, fallback)
      local existing = by_id[id]
      if existing then return existing end
      local ev = {
        id = id,
        kind = occ.kind or 'event',
        origin = occ.origin and Origin.is(occ.origin) and Origin.copy(occ.origin) or occ.origin,
        origin_id = occ.origin_id,
        root_index = occ.root_index,
        occurrence = copy_occurrence(occ),
        decision_prefix = Origin.copy_list(occ.decision_prefix or {}),
        lane_path = Origin.copy_boxes(occ.lane_path or {}),
      }
      events[#events + 1] = ev
      by_id[id] = ev
      if ev.origin_id ~= nil and event_by_origin[ev.origin_id] == nil then event_by_origin[ev.origin_id] = id end
      if occ.open_claim_origin_ids then
        for i = 1, #occ.open_claim_origin_ids do event_by_origin[occ.open_claim_origin_ids[i]] = event_by_origin[occ.open_claim_origin_ids[i]] or id end
      end
      order[#order + 1] = id
      for i = 1, #(ev.decision_prefix or {}) do
        local label, branch = parse_decision(ev.decision_prefix[i])
        if label ~= '' then
          local before = decision_owner[label]
          if before ~= nil and before ~= branch then
            conflicts[#conflicts + 1] = { kind = 'decision_conflict', label = label, left = before, right = branch, event = id }
          else
            decision_owner[label] = branch
          end
        end
      end
      return ev
    end

    local root_event_by_index = {}
    for i = 1, #(selected_occurrences or {}) do
      local occ = selected_occurrences[i]
      local ev = add_event(occ, i)
      if occ.kind == 'root_frame' and occ.root_index ~= nil then root_event_by_index[occ.root_index] = ev.id end
    end

    local causes, cause_seen = {}, {}
    for i = 1, #(events or {}) do
      local ev = events[i]
      local root_id = ev.root_index and root_event_by_index[ev.root_index]
      if root_id and ev.kind ~= 'root_frame' then add_unique_edge(causes, cause_seen, root_id, ev.id, 'root-selects-occurrence') end
      local occ = ev.occurrence or {}
      if occ.parent_obligation then add_unique_edge(causes, cause_seen, 'obligation:' .. tostring(occ.parent_obligation), ev.id, 'parent-obligation') end
    end

    -- Claim completions are interaction events. Each completion depends on all open_claim
    -- occurrence events whose open_claims it closes.
    for i = 1, #(matches or {}) do
      local match = matches[i]
      local occ = { kind = 'match', match_kind = match.kind, open_claim_origin_ids = {} }
      for j = 1, #(match.open_claims or {}) do occ.open_claim_origin_ids[#occ.open_claim_origin_ids + 1] = match.open_claims[j].origin_id end
      local mid = event_id_for(occ, 'match-' .. tostring(i))
      if by_id[mid] then
        for j = 1, #(match.open_claims or {}) do
          local origin_id = match.open_claims[j].origin_id
          local cause = event_by_origin[origin_id]
          if not cause and origin_id then
            local parent = tostring(origin_id):gsub('/open_claim%%:[^/]+/', '/')
            cause = event_by_origin[parent]
          end
          add_unique_edge(causes, cause_seen, cause or origin_id, mid, 'completion-open_claim')
        end
      end
    end

    if #conflicts > 0 then return Status.conflict('selected occurrence configuration is not conflict-free', conflicts) end
    return Status.found(setmetatable({ tag = 'configuration', key = key, events = events, by_id = by_id, order = order, causes = causes, conflicts = conflicts }, Methods))
  end

  function Configuration.is(x)
    return type(x) == 'table' and getmetatable(x) == Methods
  end

  function Configuration.assert(x, where)
    if not Configuration.is(x) then error((where or 'configuration') .. ': expected Configuration', 3) end
    return x
  end

  function Methods:event_count() return #(self.events or {}) end
  function Methods:is_conflict_free() return #(self.conflicts or {}) == 0 end

  function Methods:is_causally_closed()
    for i = 1, #(self.causes or {}) do
      local edge = self.causes[i]
      if tostring(edge.cause):match('^obligation:') then
        -- Linear obligations may be represented by the obligation store rather
        -- than by selected occurrence events in this configuration.
      elseif not self.by_id[edge.cause] then
        return false, edge
      end
      if not self.by_id[edge.effect] then return false, edge end
    end
    return true
  end

  function Methods:copy_event_order() return Util.copy_list(self.order) end
end

-- from machine/candidate.lua
do
  Candidate = {}
  local Methods = {}
  Methods.__index = Methods

  local function copy_assignments(assignments)
    local out = {}
    for k, v in pairs(assignments or {}) do out[k] = v end
    return out
  end

  local function root_values(frame, assignments)
    return frame:evaluate(assignments or {})
  end

  local function open_claim_key(open_claim)
    if not open_claim then return '<nil-open_claim>' end
    local resource = open_claim.resource and (open_claim.resource.id or open_claim.resource.label) or '<nil-resource>'
    return tostring(open_claim.origin_id or open_claim.id) .. '@' .. tostring(resource) .. ':' .. tostring(open_claim.role or open_claim.tag or 'open_claim')
  end

  local function selection_key(selection, matches)
    local parts = {}
    for i = 1, #selection do
      local item = selection[i]
      parts[#parts + 1] = tostring(item.frontier and item.frontier.attempt and item.frontier.attempt.id)
        .. ':' .. tostring(item.frame and (item.frame.origin_id or item.frame.id) or item.frame)
    end
    local match_parts = {}
    for i = 1, #(matches or {}) do
      local match = matches[i]
      local endpoint_parts = {}
      for j = 1, #(match.open_claims or {}) do endpoint_parts[#endpoint_parts + 1] = open_claim_key(match.open_claims[j]) end
      table.sort(endpoint_parts)
      match_parts[#match_parts + 1] = tostring(match.kind or 'external') .. ':' .. table.concat(endpoint_parts, '&')
    end
    table.sort(match_parts)
    if #match_parts > 0 then parts[#parts + 1] = 'matches=' .. table.concat(match_parts, ',') end
    return table.concat(parts, '|')
  end

  local function selected_occurrence_for(item, root_index)
    local frame = item.frame
    return {
      kind = 'root_frame',
      root_index = root_index,
      attempt = item.frontier and item.frontier.attempt,
      origin = frame.origin,
      origin_id = frame.origin_id,
      frame_id = frame.id,
      lane_path = frame.origin and frame.origin.lane_path or {},
      decision_prefix = frame.origin and frame.origin.decision_prefix or {},
    }
  end

  local function match_occurrence(match)
    local ids, origins = {}, {}
    for i = 1, #(match.open_claims or {}) do
      ids[#ids + 1] = match.open_claims[i].origin_id
      origins[#origins + 1] = match.open_claims[i].origin or match.open_claims[i].origin_id
    end
    return {
      kind = 'match',
      match_kind = match.kind,
      event = match.event,
      resource = match.resource,
      open_claim_origins = origins,
      open_claim_origin_ids = ids,
      event_id = match.event_id,
    }
  end

  local function copy_inputs(inputs)
    local out = {}
    for i = 1, #(inputs or {}) do out[i] = inputs[i] end
    return out
  end

  local function selection_view(selection)
    for i = 1, #(selection or {}) do
      local item = selection[i]
      local v = item.view or (item.frontier and item.frontier.view)
      if v ~= nil then return v end
    end
    return nil
  end

  local function merge_selected_delta(acc, evidence, view, token)
    if acc == nil then return Status.found(Evidence.copy(evidence)) end
    return Evidence.coexist(acc, evidence, view, token)
  end

  function Candidate.from_closed_proof(closed, token)
    Phase.require(token, 'search')
    if type(closed) ~= 'table' or closed.tag ~= 'closed_proof' then return Status.fatal('Candidate.from_closed_proof requires closed proof') end
    return Candidate.from_selection(closed.selection, closed.assignments, closed.matches, closed.search_inputs, token)
  end

  function Candidate.from_selection(selection, assignments, matches, inputs, token)
    Phase.require(token, 'search')
    if type(selection) ~= 'table' or #selection == 0 then return Status.fatal('Candidate.from_selection requires non-empty selection') end
    assignments = assignments or {}
    matches = matches or {}
    local view, view_err = selection_view(selection)
    if view == nil then return Status.fatal(view_err or 'Candidate.from_selection requires view') end
    local roots = {}
    local obligations = {}
    local selected_occurrences = {}
    local selected_delta = nil
    for i = 1, #selection do
      local item = selection[i]
      Frontier.assert(item.frontier, 'Candidate.from_selection frontier')
      if not Frame.is(item.frame) then return Status.fatal('Candidate.from_selection requires Frame') end
      if item.frame.is_deferred and item.frame:is_deferred() then
        return Status.fatal('Candidate.from_selection received unresolved deferred bind frame')
      end
      local ok, values = pcall(function() return root_values(item.frame, assignments) end)
      if not ok then return Status.fatal(values) end
      local evidence = Evidence.copy(item.frame.evidence)
      local root = {
        frontier = item.frontier,
        view = item.view or item.frontier.view,
        task = item.task,
        attempt = item.frontier.attempt,
        frame = item.frame,
        evidence = evidence,
        values = Util.pack(Util.unpack(values)),
        post_programs = Util.copy_list(evidence.post_programs),
      }
      roots[#roots + 1] = root
      selected_occurrences[#selected_occurrences + 1] = selected_occurrence_for(item, i)
      for j = 1, #(evidence.selected_occurrences or {}) do
        local occurrence = Evidence.copy_occurrence(evidence.selected_occurrences[j])
        occurrence.root_index = occurrence.root_index or i
        selected_occurrences[#selected_occurrences + 1] = occurrence
      end
      local merged_delta = merge_selected_delta(selected_delta, evidence, view, token)
      if not Status.is_found(merged_delta) then return merged_delta end
      selected_delta = merged_delta.value
      for j = 1, #(evidence.absence_obligations or {}) do
        obligations[#obligations + 1] = { root = root, obligation = evidence.absence_obligations[j] }
      end
    end
    for i = 1, #(matches or {}) do
      local match = matches[i]
      if match.evidence then
        local merged_delta = merge_selected_delta(selected_delta, match.evidence, view, token)
        if not Status.is_found(merged_delta) then return merged_delta end
        selected_delta = merged_delta.value
        for j = 1, #((match.evidence and match.evidence.absence_obligations) or {}) do
          obligations[#obligations + 1] = { match = match, obligation = match.evidence.absence_obligations[j] }
        end
        for j = 1, #((match.evidence and match.evidence.selected_occurrences) or {}) do
          selected_occurrences[#selected_occurrences + 1] = Evidence.copy_occurrence(match.evidence.selected_occurrences[j])
        end
      end
      selected_occurrences[#selected_occurrences + 1] = match_occurrence(match)
    end
    local key = selection_key(selection, matches)
    local configuration = Configuration.from_selected(selected_occurrences, matches, key)
    if not Status.is_found(configuration) then return configuration end
    return Status.found(setmetatable({
      tag = 'candidate_world',
      roots = roots,
      assignments = copy_assignments(assignments),
      matches = Util.copy_list(matches),
      search_inputs = copy_inputs(inputs),
      absence_obligations = obligations,
      configuration = configuration.value,
      selected_occurrences = selected_occurrences,
      selected_events = configuration.value.events,
      causal_edges = configuration.value.causes,
      selected_delta = selected_delta or Evidence.empty(),
      absence_certificates = {},
      selected_frames = Util.copy_list(selection),
      key = key,
    }, Methods))
  end

  function Candidate.from_frame(frontier, frame, token)
    Phase.require(token, 'search')
    Frontier.assert(frontier, 'Candidate.from_frame')
    if not Frame.is(frame) then return Status.fatal('Candidate.from_frame requires Frame') end
    return Candidate.from_selection({ { frontier = frontier, view = frontier.view, frame = frame } }, {}, {}, {
      { frontier = frontier, view = frontier.view, frames = { frame } },
    }, token)
  end

  function Candidate.is(x)
    return type(x) == 'table' and getmetatable(x) == Methods
  end

  function Candidate.assert(x, where)
    if not Candidate.is(x) then error((where or 'candidate') .. ': expected CandidateWorld', 3) end
    return x
  end
end

return {
  Configuration = Configuration,
  Candidate = Candidate,
}
