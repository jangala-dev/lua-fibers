-- Machine proof-net layer: search for closed, cut-compatible proofs.

local Kernel = require('et.machine.kernel')
local Protocol = require('et.protocol')
local FrontierLayer = require('et.machine.frontier')

local Status = Kernel.Status
local Util = Kernel.Util
local Phase = Kernel.Phase

local Link = Protocol.Link
local View = FrontierLayer.View
local Frontier = FrontierLayer.Frontier
local Frame = FrontierLayer.Frame
local ProofSearch, ClosedProof

-- Closed proof-net structure.  World gives this semantic shape.
do
  ClosedProof = {}
  local Methods = {}
  Methods.__index = Methods

  local function copy_assignments(assignments)
    local out = {}
    for k, v in pairs(assignments or {}) do out[k] = v end
    return out
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

  function ClosedProof.from_selection(selection, assignments, matches, inputs)
    return setmetatable({
      tag = 'closed_proof',
      selection = Util.copy_list(selection or {}),
      assignments = copy_assignments(assignments),
      matches = Util.copy_list(matches or {}),
      search_inputs = Util.copy_list(inputs or {}),
      key = selection_key(selection or {}, matches or {}),
    }, Methods)
  end

  function ClosedProof.is(x) return type(x) == 'table' and getmetatable(x) == Methods end
  function ClosedProof.assert(x, where) if not ClosedProof.is(x) then error((where or 'closed proof') .. ': expected ClosedProof', 3) end; return x end
end

-- from machine/proofsearch.lua
do
  ProofSearch = {}
  local candidate_builder

  function ProofSearch.set_candidate_builder(fn)
    if fn ~= nil and type(fn) ~= 'function' then error('ProofSearch.set_candidate_builder: expected function or nil', 2) end
    candidate_builder = fn
  end

  local function copy_assignments(assignments)
    local out = {}
    for k, v in pairs(assignments or {}) do out[k] = v end
    return out
  end

  local function copy_matches(matches)
    local out = {}
    for i = 1, #(matches or {}) do out[i] = matches[i] end
    return out
  end

  local function put_assignment(assignments, id, row)
    local existing = assignments[id]
    if existing == nil then
      assignments[id] = row
      return true
    end
    if existing == row then return true end
    if (existing.n or #existing) ~= (row.n or #row) then return false end
    for i = 1, existing.n or #existing do
      if existing[i] ~= row[i] then return false end
    end
    return true
  end

  local function separating_box_for_same_root(a, b)
    local ap = a.box_path or {}
    local bp = b.box_path or {}
    local n = math.min(#ap, #bp)
    for i = 1, n do
      if ap[i].box ~= bp[i].box then return nil end
      if ap[i].lane ~= bp[i].lane then return ap[i] end
    end
    return nil
  end

  local function legal_pair(a_entry, b_entry)
    if a_entry.root ~= b_entry.root then return true end
    local sep = separating_box_for_same_root(a_entry.open_claim, b_entry.open_claim)
    if not sep then return false end
    return sep.allow_internal == true or sep.kind == 'tensor'
  end

  local function legal_match(entries_by_id, match)
    local open_claims = match.open_claims or {}
    for i = 1, #open_claims do
      local ai = entries_by_id[open_claims[i].id]
      if not ai then return false end
      for j = i + 1, #open_claims do
        local bj = entries_by_id[open_claims[j].id]
        if not bj then return false end
        if not legal_pair(ai, bj) then return false end
      end
    end
    return true
  end

  local function match_kind(entries_by_id, match)
    local root
    for i = 1, #(match.open_claims or {}) do
      local entry = entries_by_id[match.open_claims[i].id]
      if not entry then return 'external' end
      if root == nil then root = entry.root elseif root ~= entry.root then return 'external' end
    end
    return 'internal'
  end

  local function copy_match(match, entries_by_id)
    local out = {}
    for k, v in pairs(match or {}) do out[k] = v end
    out.kind = out.kind or match_kind(entries_by_id, match)
    out.legality = out.kind == 'internal' and 'box_path' or 'external'
    return out
  end

  local function enumerate_assignments(selection, base_assignments, base_matches, token, visit)
    local open_claims = {}
    local entries_by_id = {}
    local view
    for i = 1, #selection do
      view = view or selection[i].view
      local frame = selection[i].frame
      for j = 1, #(frame.open_claims or {}) do
        local entry = { root = i, open_claim = frame.open_claims[j], view = selection[i].view }
        open_claims[#open_claims + 1] = entry
        entries_by_id[entry.open_claim.id] = entry
      end
    end
    if not view then return Status.absent('selection has no view') end

    local used = {}
    local assignments = copy_assignments(base_assignments)
    local matches = copy_matches(base_matches)

    local function deferred_ready()
      local has_deferred = false
      for si = 1, #selection do
        local frame = selection[si].frame
        if frame.has_deferred and frame:has_deferred() then
          has_deferred = true
          for pj = 1, #(frame.open_claims or {}) do
            if assignments[frame.open_claims[pj].id] == nil then return false end
          end
        end
      end
      return has_deferred
    end

    for i = 1, #open_claims do
      if assignments[open_claims[i].open_claim.id] ~= nil then used[i] = true end
    end

    local function first_unmatched()
      for i = 1, #open_claims do if not used[i] then return i end end
      return nil
    end

    local function candidate_matches_for(first)
      local first_open_claim = open_claims[first].open_claim
      local same_resource = {}
      for i = 1, #open_claims do
        if not used[i] and open_claims[i].open_claim.resource == first_open_claim.resource then
          same_resource[#same_resource + 1] = open_claims[i].open_claim
        end
      end
      return Link.merge(view, first_open_claim.resource, { kind = 'complete', open_claims = same_resource }, token)
    end

    -- Attach stable indices after the helper has been created.
    for i = 1, #open_claims do open_claims[i].index = i; entries_by_id[open_claims[i].open_claim.id] = open_claims[i] end

    local function mark_match(match, flag)
      for i = 1, #(match.open_claims or {}) do
        local entry = entries_by_id[match.open_claims[i].id]
        if entry then used[entry.index] = flag end
      end
    end

    local function undo_assignments(before)
      if not before then return end
      for i = 1, #(before.keys or {}) do
        local id = before.keys[i]
        assignments[id] = before.values[id]
      end
    end

    local function go()
      if deferred_ready() then return visit(assignments, matches) end
      local first = first_unmatched()
      if not first then return visit(assignments, matches) end

      local listed = candidate_matches_for(first)
      if listed.tag == 'stale' or listed.tag == 'fatal' or listed.tag == 'budget' then return listed end
      if not Status.is_found(listed) then return Status.absent('selection open_claims are not closed') end

      local any = false
      for i = 1, #listed.value do
        local match = listed.value[i]
        local includes_first = false
        for j = 1, #(match.open_claims or {}) do if match.open_claims[j].id == open_claims[first].open_claim.id then includes_first = true; break end end
        if includes_first and legal_match(entries_by_id, match) then
          local before = { keys = {}, values = {} }
          local ok = true
          for j = 1, #(match.open_claims or {}) do
            local open_claim = match.open_claims[j]
            local row = match.assignments and match.assignments[open_claim.id]
            if row == nil then ok = false; break end
            before.keys[#before.keys + 1] = open_claim.id
            before.values[open_claim.id] = assignments[open_claim.id]
            if not put_assignment(assignments, open_claim.id, row) then ok = false; break end
          end
          if ok then
            any = true
            mark_match(match, true)
            matches[#matches + 1] = copy_match(match, entries_by_id)
            local r = go()
            if r and not (r.tag == 'absent' or r.tag == 'conflict' or r.tag == 'continue') then return r end
            matches[#matches] = nil
            mark_match(match, false)
          end
          undo_assignments(before)
        end
      end
      if not any then return Status.absent('selection open_claims are not closed') end
      return Status.absent('selection open_claims are not closed')
    end

    return go()
  end

  local function probe_input(input, token)
    Frontier.assert(input.frontier, 'ProofSearch input frontier')
    View.assert(input.view, 'ProofSearch input view')
    local probed = input.frontier:probe(input.view, token)
    if not Status.is_found(probed) then return probed end
    return Status.found({ task = input.task, frontier = input.frontier, view = input.view, frames = probed.value })
  end

  local function gather_inputs(inputs, token)
    local out = {}
    local pending
    for i = 1, #inputs do
      local p = probe_input(inputs[i], token)
      if p.tag == 'stale' or p.tag == 'fatal' or p.tag == 'budget' then return p end
      if p.tag == 'pending' then
        pending = pending or p
      elseif Status.is_found(p) and #p.value.frames > 0 then
        out[#out + 1] = p.value
      end
    end
    if #out == 0 then
      if pending then return pending end
      return Status.absent('no fresh frames')
    end
    return Status.found(out)
  end

  local function selection_has_deferred(selection)
    for i = 1, #selection do
      local frame = selection[i].frame
      if frame.has_deferred and frame:has_deferred() then return true end
    end
    return false
  end

  local function expand_deferred_selection(selection, assignments, token)
    local lists = {}
    for i = 1, #selection do
      local item = selection[i]
      local frame = item.frame
      if frame.has_deferred and frame:has_deferred() then
        local continued = Frontier.continue_after_match(frame, assignments, token, item.view)
        if not Status.is_found(continued) then return continued end
        if #continued.value == 0 then return Status.absent('deferred bind continuation produced no frames') end
        local alternatives = {}
        for j = 1, #continued.value do
          alternatives[#alternatives + 1] = { task = item.task, frontier = item.frontier, view = item.view, frame = continued.value[j] }
        end
        lists[i] = alternatives
      else
        lists[i] = { item }
      end
    end
    return Status.found(lists)
  end

  local function cross_product(lists, i, acc, visit)
    if i > #lists then return visit(Util.copy_list(acc)) end
    for j = 1, #lists[i] do
      acc[i] = lists[i][j]
      local r = cross_product(lists, i + 1, acc, visit)
      if r and not (r.tag == 'absent' or r.tag == 'conflict' or r.tag == 'continue') then return r end
    end
    acc[i] = nil
    return Status.absent('no deferred continuation alternative closed')
  end

  local function selection_has_pending(selection)
    for i = 1, #(selection or {}) do
      local frame = selection[i].frame
      if frame and frame.is_pending and frame:is_pending() then return true end
    end
    return false
  end

  local function enumerate_candidates(selection, inputs, token, opts, visit, depth, base_assignments, base_matches)
    opts = opts or {}
    depth = depth or 0
    if selection_has_pending(selection) then return Status.pending('selection contains pending external wait') end
    if depth > (opts.max_deferred_depth or 32) then return Status.budget('deferred bind continuation depth exceeded') end

    return enumerate_assignments(selection, base_assignments, base_matches, token, function(assignments, matches)
      if selection_has_deferred(selection) then
        local expanded = expand_deferred_selection(selection, assignments, token)
        if not Status.is_found(expanded) then return expanded end
        return cross_product(expanded.value, 1, {}, function(next_selection)
          return enumerate_candidates(next_selection, inputs, token, opts, visit, depth + 1, assignments, matches)
        end)
      end

      local closed = ClosedProof.from_selection(selection, assignments, matches, inputs)
      local candidate = Status.found(closed)
      if candidate_builder then
        candidate = candidate_builder(closed, token)
      end
      if not Status.is_found(candidate) then return candidate end
      local r = visit(candidate.value)
      if r == nil then return { tag = 'continue' } end
      return r
    end)
  end

  function ProofSearch.each_primary_candidate(root, frame, inputs, token, visit)
    Phase.require(token, 'search')
    if type(visit) ~= 'function' then return Status.fatal('each_primary_candidate requires visitor') end
    local root_item = { task = root.task, frontier = root.frontier, view = root.view, frame = frame }
    local others = {}
    for i = 1, #inputs do if inputs[i].frontier ~= root.frontier then others[#others + 1] = inputs[i] end end
    local saw_closed = false
    local function choose(start, selection)
      local attempt = enumerate_candidates(selection, inputs, token, {}, function(candidate)
        saw_closed = true
        local v = visit(candidate)
        if v and v.tag == 'continue' then return { tag = 'continue' } end
        if v ~= nil then return v end
        return { tag = 'continue' }
      end)
      if attempt and not (attempt.tag == 'absent' or attempt.tag == 'conflict' or attempt.tag == 'continue') then return attempt end
      for i = start, #others do
        for j = 1, #others[i].frames do
          selection[#selection + 1] = { task = others[i].task, frontier = others[i].frontier, view = others[i].view, frame = others[i].frames[j] }
          local r = choose(i + 1, selection)
          if r and not (r.tag == 'absent' or r.tag == 'conflict') then return r end
          selection[#selection] = nil
        end
      end
      return Status.absent('preferred branch has no more closed worlds')
    end
    local r = choose(1, { root_item })
    if r and (r.tag == 'stale' or r.tag == 'fatal' or r.tag == 'budget' or Status.is_found(r) or r.tag == 'reject_candidate') then return r end
    if saw_closed then return Status.found(false) end
    return Status.absent('preferred branch has no closed world')
  end

  function ProofSearch.primary_committable(root, frame, inputs, token)
    local found = false
    local r = ProofSearch.each_primary_candidate(root, frame, inputs, token, function(_)
      found = true
      return Status.found(true)
    end)
    if Status.is_found(r) then return Status.found(found or r.value == true) end
    if r.tag == 'stale' or r.tag == 'fatal' or r.tag == 'budget' then return r end
    return Status.found(false)
  end

  local function rejected_contains(rejected, candidate)
    if not rejected then return false end
    return rejected[candidate.key] == true
  end

  local function search_multi(inputs, token, opts)
    opts = opts or {}
    local n = #inputs
    local function choose(start, selection)
      if #selection > 0 then
        local r = enumerate_candidates(selection, inputs, token, opts, function(candidate)
          if rejected_contains(opts.rejected, candidate) then return { tag = 'continue' } end
          return Status.found(candidate)
        end)
        if Status.is_found(r) or r.tag == 'stale' or r.tag == 'fatal' or r.tag == 'budget' then return r end
      end
      for i = start, n do
        for j = 1, #inputs[i].frames do
          selection[#selection + 1] = { task = inputs[i].task, frontier = inputs[i].frontier, view = inputs[i].view, frame = inputs[i].frames[j] }
          local r = choose(i + 1, selection)
          if Status.is_found(r) or r.tag == 'stale' or r.tag == 'fatal' or r.tag == 'budget' then return r end
          selection[#selection] = nil
        end
      end
      return Status.absent('no closed proof-net configuration')
    end
    return choose(1, {})
  end

  function ProofSearch.find(frontiers_or_frontier, view, token, opts)
    Phase.require(token, 'search')
    if Frontier.is(frontiers_or_frontier) then
      local input = { { frontier = frontiers_or_frontier, view = view } }
      local gathered = gather_inputs(input, token)
      if not Status.is_found(gathered) then return gathered end
      return search_multi(gathered.value, token, opts)
    end
    local inputs = frontiers_or_frontier or {}
    local gathered = gather_inputs(inputs, token)
    if not Status.is_found(gathered) then return gathered end
    return search_multi(gathered.value, token, opts)
  end
end

ProofSearch.ClosedProof = ClosedProof

return ProofSearch
