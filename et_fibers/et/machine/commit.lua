-- Machine commit layer: certification, resource preparation, consequences, and commit application.

local Kernel = require('et.machine.kernel')
local Protocol = require('et.protocol')
local FrontierLayer = require('et.machine.frontier')
local World = require('et.machine.world')
local ProofSearch = require('et.machine.proofnet')

local Status = Kernel.Status
local Util = Kernel.Util
local Phase = Kernel.Phase

local Candidate = World.Candidate
ProofSearch.set_candidate_builder(Candidate.from_closed_proof)

local Link = Protocol.Link
local Consequence = FrontierLayer.Consequence
local Obligation = FrontierLayer.Obligation

local Evidence = FrontierLayer.Evidence
local Frontier = FrontierLayer.Frontier
local Absence = FrontierLayer.Absence

local CommitCertificate

-- from machine/certificate.lua
do
  CommitCertificate = {}
  local Methods = {}
  Methods.__index = Methods

  local function append_dirty(dst, xs)
    for i = 1, #(xs or {}) do dst[#dst + 1] = xs[i] end
  end

  local try_build


  local function probe_candidate(candidate, opts)
    opts = opts or {}
    opts.probe = true
    opts.seen = opts.seen or {}
    local key = tostring(candidate.key)
    if opts.seen[key] then
      return Status.budget('recursive commit-certification probe for ' .. key)
    end
    opts.seen[key] = true
    local r = try_build(candidate, opts)
    opts.seen[key] = nil
    if Status.is_found(r) then return Status.found({ tag = 'certifiable', certificate = r.value }) end
    return r
  end

  local function discharge_absences(candidate, opts)
    opts = opts or {}
    return Phase.with('search', function(token)
      local certs = {}
      for i = 1, #(candidate.absence_obligations or {}) do
        local entry = candidate.absence_obligations[i]
        local ob = entry.obligation
        local root = entry.root
        local expanded = Frontier.expand_op(ob.op, root.view, Evidence.copy(ob.evidence), token, ob.origin, root.attempt)
        if expanded.tag == 'stale' or expanded.tag == 'fatal' or expanded.tag == 'budget' then return expanded end
        if Status.is_found(expanded) then
          for j = 1, #expanded.value do
            local scan = ProofSearch.each_primary_candidate(root, expanded.value[j], candidate.search_inputs or {}, token, function(primary_candidate)
              local probe = probe_candidate(primary_candidate, {
                probe = true,
                seen = opts.seen or {},
              })
              if Status.is_found(probe) then
                return Status.reject_candidate('fallback absence obligation not discharged; preferred branch is certifiable', {
                  kind = 'absence_failed',
                  candidate_key = candidate.key,
                  witness_key = primary_candidate.key,
                })
              end
              if probe.tag == 'stale' or probe.tag == 'fatal' or probe.tag == 'budget' then return probe end
              -- absent/conflict/reject_candidate means this primary proof-net world cannot become real.
              return { tag = 'continue' }
            end)
            if scan.tag == 'stale' or scan.tag == 'fatal' or scan.tag == 'budget' then return scan end
            if Status.is_reject_candidate(scan) then return scan end
          end
        elseif expanded.tag ~= 'absent' then
          return expanded
        end
        certs[#certs + 1] = Absence.certificate(ob, root, candidate.key)
      end
      return Status.found(certs)
    end)
  end


  local function list_selected_obligations(evidence)
    local out, seen = {}, {}
    for i = 1, #(evidence.selected_obligations or {}) do
      local ref = evidence.selected_obligations[i]
      if ref and ref.id and not seen[ref.id] then
        seen[ref.id] = true
        out[#out + 1] = ref
      end
    end
    return out, seen
  end

  local function list_published_for_roots(candidate)
    local out, seen = {}, {}
    for i = 1, #(candidate.roots or {}) do
      local attempt = candidate.roots[i].attempt
      -- Use the whole live-attempt publication history, not just the
      -- current frontier.  Frontier refresh replays the attempt and must not
      -- orphan obligations that were already published by earlier frontiers.
      local pubs = attempt and (attempt.all_obligations or attempt.published_obligations) or {}
      for j = 1, #pubs do
        local ref = pubs[j]
        if ref and ref.id and not seen[ref.id] then
          seen[ref.id] = true
          out[#out + 1] = ref
        end
      end
    end
    return out, seen
  end

  local function prepare_obligations(evidence, candidate, token)
    local prepared = {}
    local consequences = Consequence.empty()
    local selected, selected_seen = list_selected_obligations(evidence)
    local published = list_published_for_roots(candidate)
    local scheduled = {}

    local function schedule(ref, state)
      if scheduled[ref.id] then return Status.found(true) end
      scheduled[ref.id] = state
      local store = ref.store or Obligation.default_store()
      local ps = store:prepare_transition(ref, state, token)
      if not Status.is_found(ps) then
        if ps.tag == 'conflict' then
          return Status.reject_candidate(ps.reason, {
            kind = 'candidate_conflict',
            candidate_key = candidate.key,
            source = ps,
          })
        end
        return ps
      end
      prepared[#prepared + 1] = ps.value
      consequences = Consequence.append(consequences, ps.value.consequences or Consequence.empty())
      return Status.found(true)
    end

    for i = 1, #selected do
      local r = schedule(selected[i], 'selected')
      if not Status.is_found(r) then return r end
    end

    for i = 1, #published do
      local ref = published[i]
      if not selected_seen[ref.id] then
        local target = 'lost'
        local parent = ref.origin and ref.origin.parent_obligation
        if parent and (ref.store or Obligation.default_store()):state(parent) == 'withdrawn' then target = 'withdrawn' end
        local r = schedule(ref, target)
        if not Status.is_found(r) then return r end
      end
    end

    return Status.found({ prepared = prepared, consequences = consequences })
  end

  local function prepare_resources(evidence, token, candidate)
    local prepared = {}
    local prepared_by_resource = {}
    local dirty = {}
    local consequences = Consequence.copy(evidence.consequences)

    for i = 1, #(evidence.resources and evidence.resources.order or {}) do
      local resource = evidence.resources.order[i]
      local fragment = evidence.resources.by_resource[resource]
      local prepared_status = Link.prepare(resource, fragment, token)
      if not Status.is_found(prepared_status) then
        if prepared_status.tag == 'conflict' then
          return Status.reject_candidate(prepared_status.reason, {
            kind = 'candidate_conflict',
            candidate_key = candidate.key,
            source = prepared_status,
          })
        end
        return prepared_status
      end
      local prepared_commit = prepared_status.value
      prepared[#prepared + 1] = prepared_commit
      if prepared_commit.resource ~= nil then prepared_by_resource[prepared_commit.resource] = prepared_commit end
      consequences = Consequence.append(consequences, prepared_commit.consequences or Consequence.empty())
      append_dirty(dirty, prepared_commit.dirty)
    end

    return Status.found({
      prepared = prepared,
      prepared_by_resource = prepared_by_resource,
      dirty = dirty,
      consequences = consequences,
    })
  end

  local function resolve_resumptions(candidate, _prepared_by_resource)
    local resumptions = {}
    for i = 1, #(candidate.roots or {}) do
      resumptions[#resumptions + 1] = {
        attempt = candidate.roots[i].attempt,
        frontier = candidate.roots[i].frontier,
        values = Util.copy_row(candidate.roots[i].values),
        post_programs = Util.copy_list(candidate.roots[i].post_programs),
      }
    end
    return Status.found(resumptions)
  end

  try_build = function(candidate, opts)
    Candidate.assert(candidate, 'CommitCertificate.try_build')
    opts = opts or {}
    opts.seen = opts.seen or {}

    local absences = discharge_absences(candidate, opts)
    if not Status.is_found(absences) then return absences end

    return Phase.with('prepare', function(token)
      local evidence = Evidence.copy(candidate.selected_delta)

      local prepared_resources = prepare_resources(evidence, token, candidate)
      if not Status.is_found(prepared_resources) then return prepared_resources end
      local prep = prepared_resources.value

      local prepared_obligations = prepare_obligations(evidence, candidate, token)
      if not Status.is_found(prepared_obligations) then return prepared_obligations end
      local obligation_prep = prepared_obligations.value

      local all_consequences = Consequence.append(prep.consequences, obligation_prep.consequences)
      local normalised = Consequence.normalise(all_consequences)
      if not Status.is_found(normalised) then
        if normalised.tag == 'conflict' then
          return Status.reject_candidate(normalised.reason, {
            kind = 'candidate_conflict',
            candidate_key = candidate.key,
            source = normalised,
          })
        end
        return normalised
      end

      local resumptions = resolve_resumptions(candidate, prep.prepared_by_resource)
      if not Status.is_found(resumptions) then
        if resumptions.tag == 'conflict' then
          return Status.reject_candidate(resumptions.reason, {
            kind = 'candidate_conflict',
            candidate_key = candidate.key,
            source = resumptions,
          })
        end
        return resumptions
      end

      return Status.found(setmetatable({
        tag = 'commit_certificate',
        state = 'prepared',
        candidate = candidate,
        roots = candidate.roots,
        resumptions = resumptions.value,
        prepared_resources = prep.prepared,
        prepared_obligations = obligation_prep.prepared,
        prepared_by_resource = prep.prepared_by_resource,
        consequences = normalised.value,
        dirty = prep.dirty,
        matches = candidate.matches,
        absence_certificates = absences.value,
      }, Methods))
    end)
  end

  function CommitCertificate.try_build(candidate, opts)
    return try_build(candidate, opts)
  end

  function CommitCertificate.probe(candidate, opts)
    Candidate.assert(candidate, 'CommitCertificate.probe')
    return probe_candidate(candidate, opts or {})
  end

  function CommitCertificate.is(x)
    return type(x) == 'table' and getmetatable(x) == Methods
  end

  function CommitCertificate.assert(x, where)
    if not CommitCertificate.is(x) then error((where or 'commit certificate') .. ': expected CommitCertificate', 3) end
    return x
  end

  function Methods:apply()
    CommitCertificate.assert(self, 'CommitCertificate.apply')
    if self.state ~= 'prepared' then
      return Status.fatal('commit certificate already consumed')
    end

    self.state = 'applying'
    local ok, result = pcall(function()
      return Phase.with('commit', function(token)
        for i = 1, #self.prepared_resources do
          local r = Link.commit(self.prepared_resources[i], token)
          if not Status.is_found(r) then return r end
        end
        for i = 1, #(self.prepared_obligations or {}) do
          self.prepared_obligations[i].apply(token)
        end
        return Status.found(true)
      end)
    end)

    if not ok then
      self.state = 'poisoned'
      return Status.fatal('prepared resource commit raised during apply', result)
    end

    if not Status.is_found(result) then
      self.state = 'poisoned'
      return Status.fatal('commit application failed after certificate consumption', result)
    end

    self.state = 'applied'
    return result
  end
end

return {
  Certificate = CommitCertificate,
}
