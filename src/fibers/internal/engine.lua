-- Transaction engine. Owns pending operations, retained searchs and arbitration.

local Search = require('fibers.internal.kernel.search')

local Proof = require('fibers.internal.proof')
local Interest = require('fibers.embed.external').Interest
local Operation = require('fibers.internal.operation')
local Activation = require('fibers.internal.kernel.activation')
local Label = require('fibers.internal.label')

local Engine = {}
local native_table_clear = table.clear

local function clear(values)
  if not values then return values end
  if native_table_clear then native_table_clear(values) else for key in pairs(values) do values[key] = nil end end
  return values
end

local function scratch(engine, field)
  local value = engine[field]
  if value then clear(value) else value = {}; engine[field] = value end
  return value
end

function Engine.new(scheduler, opts)
  local search_limit = opts.search_limit or 1000000
  local choice_seed = opts.choice_seed or 1
  return setmetatable({
    runtime = scheduler,
    instrumentation = scheduler.instrumentation,
    pending = {},
    next_request_order = 0,
    quiet_deadlock = opts.quiet_deadlock == true,
    search_limit = search_limit,
    search_total_limit = opts.search_total_limit,
    search_trail_limit = opts.search_trail_limit,
    search_depth_limit = opts.search_depth_limit,
    cycle_work_limit = opts.cycle_work_limit,
    cycle_focus_limit = opts.cycle_focus_limit,
    choice_seed = choice_seed,
    explicit_search_limit = opts.search_limit ~= nil,
    pending_generation = 0,
    epoch = 0,
  }, { __index = Engine })
end

local function begin_call(engine)
  if engine.cycle_work_limit or engine.cycle_focus_limit then
    engine._cycle_budget = {
      work = engine.cycle_work_limit, focus = engine.cycle_focus_limit,
      work_used = 0, focus_used = 0,
    }
  end
end
local function end_call(engine) engine._cycle_budget = nil end

function Engine:charge(kind, amount)
  local budget = self._cycle_budget
  local remaining = budget and budget[kind]
  if remaining == nil then return true end
  amount = amount or 1
  if remaining < amount then
    budget.reason = 'cycle_' .. kind .. '_limit'
    self._last_search_unknown_reason = budget.reason
    return false
  end
  budget[kind] = remaining - amount
  budget[kind .. '_used'] = budget[kind .. '_used'] + amount
  return true
end

local function clear_request(request)
  request.pending = nil
  request.order = nil
  request.op = nil
  request.interrupt = nil
  request.metadata = nil
  request._proof = nil
  request._potential_memberships = nil
  request.activation_root = nil
  return request
end

function Engine.admit(engine, fiber, op, interrupt)
  engine.next_request_order = engine.next_request_order + 1
  fiber.order = engine.next_request_order
  fiber.pending = true
  fiber.activation_root = Activation.new_request(fiber.order)
  fiber.op = op
  fiber.interrupt = interrupt
  engine.pending[#engine.pending + 1] = fiber
  if engine.proof_graph then
    Proof.add_request(engine, fiber)
  end
  engine.pending_generation = engine.pending_generation + 1
  local instrumentation = engine.instrumentation
  if instrumentation then
    instrumentation:inc('perform_yields')
    instrumentation:max('pending_requests', #engine.pending)
  end
  return fiber
end

function Engine.resume(engine, request, outcome, cancelled)
  local packed, wrap = outcome and outcome.pack or nil, outcome and outcome.wrap or nil
  clear_request(request)
  engine.runtime:_resume_fiber(request, cancelled, packed, wrap)
end

function Engine.interrupt(engine, token, cancelled)
  local requests = {}
  for i = 1, #engine.pending do
    local request = engine.pending[i]
    if request.interrupt == token then requests[#requests + 1] = request end
  end
  if #requests > 0 then Engine.remove(engine, requests) end
  for i = 1, #requests do Engine.resume(engine, requests[i], nil, cancelled) end
  return true
end

local function take_search(request)
  local search = request and request._retained_search
  if search then request._retained_search = nil end
  return search
end

local function discard_search(engine, request, reason)
  local search = take_search(request)
  if not search then return end
  search:discard(reason or 'invalidated')
  if engine.instrumentation then engine.instrumentation:inc('retained_search_invalidations') end
end

local function retain_search(engine, request, search)
  request._retained_search = search
  if engine.instrumentation then engine.instrumentation:inc('retained_search_stores') end
end

local function remove_selected(engine, count, request1, request2, requests)
  local remove
  if requests and count > 4 then
    remove = scratch(engine, '_remove_pending_scratch')
    for i = 1, count do remove[requests[i]] = true end
  end
  local function selected(request)
    if not requests then return request == request1 or (count == 2 and request == request2) end
    if remove then return remove[request] == true end
    for i = 1, count do if requests[i] == request then return true end end
    return false
  end

  local write, total = 1, #engine.pending
  for read = 1, total do
    local request = engine.pending[read]
    if selected(request) then
      request.pending = nil
      if engine.proof_graph then Proof.remove_request(engine, request) end
      discard_search(engine, request, 'removed')
    else
      if write ~= read then engine.pending[write] = request end
      write = write + 1
    end
  end
  for i = write, total do engine.pending[i] = nil end
  if #engine.pending == 0 then engine.proof_graph = nil end
  engine.pending_generation = engine.pending_generation + 1
  if engine.instrumentation then engine.instrumentation:inc('pending_removed', count) end
end

function Engine:remove_small(count, request1, request2)
  return remove_selected(self, count, request1, request2)
end

function Engine:remove(requests)
  return remove_selected(self, #requests, nil, nil, requests)
end

local function component_requests(engine, focus, provisional_admission)
  local active = engine.proof_graph ~= nil
  if not provisional_admission and #engine.pending > 1 then
    Proof.ensure(engine)
    active = true
  end
  if active then return Proof.component(engine, focus) end
  local requests = {}
  for i = 1, #engine.pending do requests[engine.pending[i]] = true end
  return requests, nil
end

local function find_candidate_impl(engine, focus, search_limit, requests, component, provisional_admission)
  if not engine:charge('focus') then return nil, nil, true end
  if not focus or not focus.pending then return nil end
  if not requests then requests, component = component_requests(engine, focus, provisional_admission) end

  local instrumentation = engine.instrumentation
  if engine.proof_graph then
    local retry = Proof.retry(engine, focus)
    if retry then
      return nil, retry, false
    end
  end

    local retained = focus and focus._retained_search
  if retained then
    local valid = Proof.valid(engine, retained.frontier_snapshot)
    if valid then
      if instrumentation then instrumentation:inc('retained_search_resumes') end
      local hit, certificate, unknown = retained:advance(search_limit or engine.search_limit)
      if unknown and retained.hard_limit then
        engine._last_search_unknown_reason = retained.unknown_reason or 'search_quantum'
        take_search(focus)
        retained:discard(engine._last_search_unknown_reason)
      elseif unknown then
        engine._last_search_unknown_reason = retained.unknown_reason or 'search_quantum'
      else
        take_search(focus)
        if hit == nil then retained:discard('completed-retry') end
      end
      return hit, certificate, unknown
    end
    discard_search(engine, focus, 'invalidated')
  end

  local hit, certificate, unknown, search = Search.search(
    engine, requests, focus, search_limit, component, provisional_admission
  )
  if unknown and search then
    engine._last_search_unknown_reason = search.unknown_reason or 'search_quantum'
    if search.hard_limit then
      search:discard(engine._last_search_unknown_reason)
    elseif search.frontier_snapshot then
      retain_search(engine, focus, search)
    else
      search:discard('unretained')
    end
  elseif hit == nil and search then
    search:discard('completed-retry')
  end
  return hit, certificate, unknown
end

local function find_candidate(engine, focus, search_limit, requests, component, provisional_admission)
  return engine.runtime:_call_in_phase(
    'search', 'search_error', find_candidate_impl,
    engine, focus, search_limit, requests, component, provisional_admission
  )
end

local function suspension_error(engine, fiber, contract, reason)
  local op_label = Operation.diagnostic_label(fiber.op)
  local fiber_label = Label.describe(fiber._fibers_label_subject or fiber, fiber._fibers_id)
  local message = 'suspension prohibited in this region'
  if op_label then
    message = message .. ': operation "' .. op_label .. '" would suspend'
  end
  return engine.runtime:_make_error('suspension_error', reason or 'operation would suspend', {
    action = 'perform',
    message = message,
    operation = fiber.op,
    operation_label = op_label,
    fiber = fiber,
    fiber_label = fiber_label,
    region = contract,
    reason = reason or 'operation would suspend',
  })
end

local function candidate_can_resume_first(candidate, fiber, members)
  if not candidate or candidate:participant(1) ~= fiber then return false end
  if candidate:is_fallback() and candidate:membership_sensitive() then
    return candidate:covers(members)
  end
  return true
end

local function strict_component(engine, fiber)
  local provisional_admission = engine.runtime._ready_head <= engine.runtime._ready_tail
  local requests, component = component_requests(engine, fiber, provisional_admission)
  local members = {}
  for i = 1, #engine.pending do
    local request = engine.pending[i]
    if request.pending and requests[request] then members[#members + 1] = request end
  end
  return requests, component, members, provisional_admission
end

local function resolve_without_suspension_impl(engine, fiber)
  local runtime = engine.runtime
  local contract = runtime:_suspension_contract(fiber)
  local attempts = 0
  while fiber.pending do
    attempts = attempts + 1
    local requests, component, members, provisional_admission = strict_component(engine, fiber)
    local candidate, _, unknown = find_candidate(
      engine, fiber, nil, requests, component, provisional_admission
    )

    if candidate then
      if candidate_can_resume_first(candidate, fiber, members) then
        local committed = candidate:settle(engine)
        if committed then return true end
      end
      candidate:discard('suspension-prohibited')
      if attempts < 2 then
        -- Match the ordinary driver path, which retries once after a stale or
        -- preparation-refused candidate before concluding that progress cannot
        -- be made in this turn.
      else
        unknown = false
        break
      end
    elseif unknown then
      -- Incomplete bounded search would return control to the scheduler or host.
      -- The contract is an assertion, not permission to override that budget.
      break
    else
      break
    end
  end

  if fiber.pending then
    local reason = engine._last_search_unknown_reason or 'operation_not_immediately_committable'
    engine:remove_small(1, fiber)
    Engine.resume(engine, fiber, nil, suspension_error(engine, fiber, contract, reason))
  end
  return false
end

function Engine:resolve_without_suspension(fiber)
  return resolve_without_suspension_impl(self, fiber)
end

local function pending_status(engine, refs, unknown)
  local waits = Interest.summarise(Interest.merge(Proof.collect_interests(refs)))
  clear(refs)
  if unknown then
    return {
      tag = 'pending', kind = 'budget',
      reason = engine._last_search_unknown_reason or 'search_quantum',
      interests_incomplete = true, interests = waits,
    }
  end
  if #waits > 0 then return { tag = 'pending', kind = 'wakeup', interests = waits } end
  return {
    tag = 'quiescent',
    reason = engine.quiet_deadlock and 'quiet-deadlock' or 'retry without actionable interest',
  }
end

local function search_admitted(engine, fiber, search_limit)
  local request = engine.pending[#engine.pending]
  if request ~= fiber then return nil end
  local provisional_admission = engine.runtime._ready_head <= engine.runtime._ready_tail
  local candidate, ref, unknown = find_candidate(engine, request, search_limit, nil, nil, provisional_admission)
  return request, candidate, ref, unknown
end

local function delay_candidate(values, candidate, focus, index)
  local offset = #values
  values[offset + 1], values[offset + 2], values[offset + 3] = candidate, focus, index
end

local function discard_candidates(values, keep)
  for i = 1, #(values or {}), 3 do
    local candidate = values[i]
    values[i], values[i + 1], values[i + 2] = nil, nil, nil
    if candidate and candidate ~= keep then candidate:discard('superseded') end
  end
end

local function scan_components(engine, pending, start, search_limit, refs)
  local processed = scratch(engine, '_driver_component_processed')
  local positions = scratch(engine, '_driver_component_positions')
  local members = scratch(engine, '_driver_component_members')
  local fallbacks = scratch(engine, '_driver_fallback_candidates')
  local any_unknown = false

  for offset = 0, #pending - 1 do
    local component_index = ((start + offset - 1) % #pending) + 1
    local component_focus = pending[component_index]
    if component_focus.pending and not processed[component_focus] then
      local requests, component = component_requests(engine, component_focus)
      clear(members); clear(positions)
      for member_offset = 0, #pending - 1 do
        local member_index = ((start + member_offset - 1) % #pending) + 1
        local request = pending[member_index]
        if request.pending and requests[request] then
          members[#members + 1] = request
          positions[request] = member_index
          processed[request] = true
        end
      end

      local suspended = false
      for i = 1, #members do
        local focus = members[i]
        local member_index = positions[focus]
        local candidate, ref, unknown = find_candidate(engine, focus, search_limit, requests, component)
        refs[#refs + 1] = ref
        if unknown then any_unknown, suspended = true, true; break end

        if candidate and candidate:is_fallback() then
          if candidate:covers(members) and candidate:settle(engine) then
            discard_candidates(fallbacks)
            return member_index, any_unknown
          end
          delay_candidate(fallbacks, candidate, focus, member_index)
        elseif candidate then
          local committed = candidate:settle(engine)
          if not committed and focus.pending then
            candidate, ref, unknown = find_candidate(engine, focus, search_limit)
            refs[#refs + 1] = ref
            if unknown then any_unknown, suspended = true, true; break end
            if candidate and candidate:is_fallback() then
              delay_candidate(fallbacks, candidate, focus, member_index)
            elseif candidate then
              committed = candidate:settle(engine)
            end
          end
          if committed then discard_candidates(fallbacks); return member_index, any_unknown end
        end
      end

      if not suspended then
        for i = 1, #fallbacks, 3 do
          local candidate, focus, member_index = fallbacks[i], fallbacks[i + 1], fallbacks[i + 2]
          if focus.pending then
            local committed = candidate:settle(engine)
            if not committed and focus.pending then
                local ref, unknown
              candidate, ref, unknown = find_candidate(engine, focus, search_limit)
              refs[#refs + 1] = ref
              if unknown then any_unknown, suspended = true, true; break end
              committed = candidate and candidate:settle(engine) or false
            end
            if committed then
              discard_candidates(fallbacks, candidate)
              return member_index, any_unknown
            end
          end
        end
      end
      discard_candidates(fallbacks)
    end
  end
  return nil, any_unknown
end

local function scan_pending(engine, cursor, search_limit)
  local count, pending = #engine.pending, engine.pending
  local start = ((cursor or 0) % count) + 1
  local refs = scratch(engine, '_driver_refs')
  local committed, unknown = scan_components(engine, pending, start, search_limit, refs)
  return committed, unknown, refs, start
end

local function step(engine, opts)
  engine._last_search_unknown_reason = nil
  local search_limit = opts.max_work

  local fiber = engine.runtime:_start_one()
  if fiber and search_limit and search_limit <= 1 then
    return { tag = 'pending', kind = 'started', interests_incomplete = true }
  end
  if fiber then
    local request, candidate, ref, unknown = search_admitted(engine, fiber, search_limit)
    if not request then return { tag = 'pending', kind = 'started' } end
    if candidate and not candidate:is_fallback() and candidate:settle(engine) then
      return { tag = 'found', kind = 'commit', value = true }
    end
    local refs = scratch(engine, '_driver_refs')
    refs[1] = ref
    return pending_status(engine, refs, unknown)
  end

  if #engine.pending == 0 then
    if engine.runtime._live_fibers > 0 then return { tag = 'pending', kind = 'no-ready-work' } end
    return { tag = 'idle', value = true }
  end

  local committed, unknown, refs, start = scan_pending(engine, engine._step_cursor, search_limit)
  if committed then
    engine._step_cursor = committed
    return { tag = 'found', kind = 'commit', value = true }
  end
  engine._step_cursor = start
  return pending_status(engine, refs, unknown)
end

local function run(engine, opts)
  engine._last_search_unknown_reason = nil
  if opts.max_work then return step(engine, opts) end
  local committed, last_refs, last_unknown = false, {}, false

  while true do
    local fiber = engine.runtime:_start_one()
    if not fiber then break end
    if engine.pending[#engine.pending] == fiber and #engine.pending == 1 then
      local request, candidate = search_admitted(engine, fiber)
      if candidate
        and (not candidate:is_fallback() or not candidate:membership_sensitive())
        and candidate:is_single(request)
        and candidate:settle(engine)
      then
        committed = true
      end
    end
  end

  while #engine.pending > 0 do
    local progressed = false
    local index, unknown, refs = scan_pending(engine, engine._run_cursor)
    if index then
      committed, progressed, engine._run_cursor = true, true, index
    end
    last_refs, last_unknown = refs, unknown
    while engine.runtime:_start_one() do progressed = true end
    if not progressed then break end
  end

  if committed then return { tag = 'found', value = true } end
  if #engine.pending == 0 then return { tag = 'idle', value = true } end
  return pending_status(engine, last_refs, last_unknown)
end


function Engine:advance(mode, opts)
  begin_call(self)
  local result
  if mode == 'step' then result = step(self, opts)
  elseif mode == 'run' then result = run(self, opts)
  else error('unknown engine advance mode ' .. tostring(mode), 2) end
  end_call(self)
  return result
end

-- Narrow internal testing boundary. Candidate interpretation remains private.
function Engine:find_candidate(...) return find_candidate(self, ...) end

return Engine
