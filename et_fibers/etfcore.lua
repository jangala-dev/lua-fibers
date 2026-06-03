-- etfcore.lua
--
-- Core proof-net/Eventful Transactions runtime used by the tests and demos.
--
-- It is not the full library.  It is the smallest useful physical model:
--
--   * an Op algebra
--   * parked roots expand into proof frontiers
--   * PartialProof / SpecPort / Cut are explicit runtime objects
--   * wait frames are open ports
--   * bind/map frames carry explicit continuation links, reduced only by proof search
--   * channel rendezvous is a cut between dual ports
--   * tensor/all are boxes with internal cut policy
--   * transactional bind/map continuations, tensor/all joins, and wrap boundaries are explicit links/frames
--   * resources contribute mergeable fragments
--   * a closed candidate becomes a World
--   * World commit validates fragments, checks committability, emits commit events, installs state,
--     then resumes participating fibres


local unpack_ = rawget(table, 'unpack') or _G.unpack

local M = {}

local function pack(...)
  return { n = select('#', ...), ... }
end

local function unpack_pack(p)
  return unpack_(p, 1, p.n or #p)
end

local function list_append(dst, src)
  if src then
    for i = 1, #src do dst[#dst + 1] = src[i] end
  end
end

local function shallow_copy(t)
  local u = {}
  if t then for k, v in pairs(t) do u[k] = v end end
  return u
end

local function list_copy(xs)
  local ys = {}
  if xs then for i = 1, #xs do ys[i] = xs[i] end end
  return ys
end

local function apply_wrappers(values, wrappers)
  local out = values or pack()
  for i = 1, #(wrappers or {}) do
    out = pack(wrappers[i](unpack_pack(out)))
  end
  return out
end

-- A structured post-commit value program.  Proof search and joins see raw
-- values; this program runs only after the world has committed, inside the
-- resumed fibre.
local PostProgram = {}

function PostProgram.identity()
  return { tag = 'identity' }
end

function PostProgram.apply(wrappers)
  wrappers = list_copy(wrappers or {})
  if #wrappers == 0 then return PostProgram.identity() end
  return { tag = 'apply', wrappers = wrappers }
end

function PostProgram.compose(first, second)
  first = first or PostProgram.identity()
  second = second or PostProgram.identity()
  if first.tag == 'identity' then return second end
  if second.tag == 'identity' then return first end
  return { tag = 'compose', first = first, second = second }
end

function PostProgram.product(lanes)
  local any = false
  local out = {}
  for i = 1, #(lanes or {}) do
    out[i] = lanes[i] or PostProgram.identity()
    if out[i].tag ~= 'identity' then any = true end
  end
  if not any then return PostProgram.identity() end
  return { tag = 'product', lanes = out }
end

function PostProgram.is_identity(program)
  return program == nil or program.tag == 'identity'
end

function PostProgram.run(program, values)
  program = program or PostProgram.identity()
  values = values or pack()

  if program.tag == 'identity' then
    return values

  elseif program.tag == 'apply' then
    return apply_wrappers(values, program.wrappers)

  elseif program.tag == 'compose' then
    return PostProgram.run(program.second, PostProgram.run(program.first, values))

  elseif program.tag == 'product' then
    local raw_results = values[1] or {}
    local results = {}
    for i = 1, #(program.lanes or {}) do
      local lane_values = raw_results[i] or pack()
      results[i] = PostProgram.run(program.lanes[i], lane_values)
    end
    -- Preserve lanes that had no explicit post program if the result table is
    -- longer than the product program list.
    for i = #(program.lanes or {}) + 1, #raw_results do
      results[i] = raw_results[i]
    end
    return pack(results)
  end

  error('unknown post-commit program tag: ' .. tostring(program.tag), 2)
end

-- Phase-indexed world evidence.  Frames carry local EvidenceDelta values while proof
-- search is speculative.  Closed worlds merge those values into a commit
-- certificate; commit interprets that certificate exactly once.
local EvidenceDelta = {}
EvidenceDelta.__index = EvidenceDelta

function EvidenceDelta.empty()
  return setmetatable({
    base = nil,

    resources = {
      fragments = {},
      fragment_order = {},
    },

    pre_commit = {
      obligations = {},
    },

    commit = {
      descriptors = {},
      selected_settlements = {},
      selected_settlement_order = {},
    },

    post = {
      program = PostProgram.identity(),
    },

    decisions = {},
    decision_path = {},
  }, EvidenceDelta)
end

function EvidenceDelta.delta(base)
  local e = EvidenceDelta.empty()
  e.base = base
  return e
end

function EvidenceDelta:clone_local()
  local e = EvidenceDelta.empty()
  e.base = self and self.base or nil

  if self then
    for _, resource in ipairs(self.resources.fragment_order or {}) do
      e.resources.fragment_order[#e.resources.fragment_order + 1] = resource
      e.resources.fragments[resource] = self.resources.fragments[resource]
    end

    list_append(e.pre_commit.obligations, self.pre_commit.obligations)
    list_append(e.commit.descriptors, self.commit.descriptors)
    list_append(e.commit.selected_settlement_order, self.commit.selected_settlement_order)
    for k, v in pairs(self.commit.selected_settlements or {}) do
      e.commit.selected_settlements[k] = v
    end

    e.post.program = self.post.program or PostProgram.identity()

    for k, v in pairs(self.decisions or {}) do e.decisions[k] = v end
    list_append(e.decision_path, self.decision_path)
  end

  return e
end

function EvidenceDelta:add_fragment(resource, fragment)
  if self.resources.fragments[resource] == nil then
    self.resources.fragment_order[#self.resources.fragment_order + 1] = resource
  end
  self.resources.fragments[resource] = fragment
  return self
end

function EvidenceDelta:merge_fragment(resource, fragment)
  local current = self.resources.fragments[resource]
  if current == nil then
    self:add_fragment(resource, fragment)
    return true
  end
  local ok, merged_or_reason = resource:merge_fragments(current, fragment)
  if not ok then return false, merged_or_reason end
  self.resources.fragments[resource] = merged_or_reason
  return true
end

function EvidenceDelta:local_fragment(resource)
  if self and self.resources and self.resources.fragments[resource] ~= nil then
    return self.resources.fragments[resource]
  end
  return resource:empty_fragment()
end

function EvidenceDelta:_base_fragment_view(resource)
  local base_view
  if self and self.base then
    base_view = self.base:_base_fragment_view(resource)
  end

  local local_fragment = self and self.resources and self.resources.fragments[resource] or nil
  if base_view ~= nil and local_fragment ~= nil then
    local ok, merged_or_reason = resource:merge_fragments(base_view, local_fragment)
    if not ok then return nil, merged_or_reason end
    return merged_or_reason
  elseif base_view ~= nil then
    return base_view
  elseif local_fragment ~= nil then
    return local_fragment
  else
    return nil
  end
end

function EvidenceDelta:fragment_view(resource)
  local view, reason = self:_base_fragment_view(resource)
  if view == nil and reason ~= nil then return nil, reason end
  if view == nil then return resource:empty_fragment() end
  return view
end

function EvidenceDelta:materialize()
  local out = EvidenceDelta.empty()
  local ok, reason = out:merge_local_from(self, true)
  if not ok then error(reason or 'could not materialize evidence', 2) end
  return out
end

function EvidenceDelta:decision_path_view()
  local out = {}
  if self and self.base then list_append(out, self.base:decision_path_view()) end
  list_append(out, self and self.decision_path)
  return out
end

function EvidenceDelta:add_pre_commit_obligation(obligation)
  self.pre_commit.obligations[#self.pre_commit.obligations + 1] = obligation
  return self
end

function EvidenceDelta:add_commit_descriptor(descriptor)
  self.commit.descriptors[#self.commit.descriptors + 1] = descriptor
  return self
end

function EvidenceDelta:add_selected_settlement(ref)
  local key = ref and ref.key or tostring(ref)
  if self.commit.selected_settlements[key] == nil then
    self.commit.selected_settlement_order[#self.commit.selected_settlement_order + 1] = key
  end
  self.commit.selected_settlements[key] = ref
  return self
end

function EvidenceDelta:compose_post_program(program)
  self.post.program = PostProgram.compose(self.post.program, program or PostProgram.identity())
  return self
end

function EvidenceDelta:merge_response(response)
  response = response or {}

  if response.fragments then
    for resource, fragment in pairs(response.fragments) do
      local ok, reason = self:merge_fragment(resource, fragment)
      if not ok then return nil, reason end
    end
  end

  if response.descriptors then
    for i = 1, #response.descriptors do
      self:add_commit_descriptor(response.descriptors[i])
    end
  end

  return self
end

function EvidenceDelta:_merge_from(other, include_base, include_post)
  if not other then return true end

  if include_base and other.base then
    local ok, reason = self:_merge_from(other.base, true, include_post)
    if not ok then return false, reason end
  end

  for _, resource in ipairs(other.resources.fragment_order or {}) do
    local ok, reason = self:merge_fragment(resource, other.resources.fragments[resource])
    if not ok then return false, reason end
  end

  list_append(self.pre_commit.obligations, other.pre_commit.obligations)
  list_append(self.commit.descriptors, other.commit.descriptors)

  for _, key in ipairs(other.commit.selected_settlement_order or {}) do
    self:add_selected_settlement(other.commit.selected_settlements[key])
  end

  if include_post then
    self.post.program = PostProgram.compose(self.post.program, other.post.program or PostProgram.identity())
  end

  list_append(self.decision_path, other.decision_path)

  for k, v in pairs(other.decisions or {}) do
    local old = self.decisions[k]
    if old ~= nil and old ~= v then
      return false, 'conflicting decision for ' .. tostring(k)
    end
    self.decisions[k] = v
  end

  return true
end

-- Local/frame evidence merge includes post programs.  This is used for
-- materializing product bases and other local proof evidence.
function EvidenceDelta:merge_local_from(other, include_base)
  return self:_merge_from(other, include_base, true)
end

-- World certificate merge excludes post programs.  Post-commit value programs
-- are per-root resumptions, not a scalar property of the global world.
function EvidenceDelta:merge_certificate_from(other, include_base)
  return self:_merge_from(other, include_base, false)
end

function EvidenceDelta:validate_resources()
  for _, resource in ipairs(self.resources.fragment_order) do
    local ok, validate_reason = resource:validate_fragment(self.resources.fragments[resource])
    if not ok then return nil, validate_reason end
  end
  return true
end

local WorldEvidence = {}
WorldEvidence.__index = WorldEvidence

function WorldEvidence.from_delta(delta)
  return setmetatable({
    resources = delta.resources,
    pre_commit = delta.pre_commit,
    commit = delta.commit,
    decisions = delta.decisions,
    decision_path = delta.decision_path,
  }, WorldEvidence)
end

function WorldEvidence:validate_resources()
  for _, resource in ipairs(self.resources.fragment_order) do
    local ok, validate_reason = resource:validate_fragment(self.resources.fragments[resource])
    if not ok then return nil, validate_reason end
  end
  return true
end

local ResumptionEvidence = {}
ResumptionEvidence.__index = ResumptionEvidence

function ResumptionEvidence.new(attempt, task, values, post_program)
  return setmetatable({
    attempt = attempt or (task and task.attempt) or nil,
    task = task,
    values = values or pack(),
    post_program = post_program or PostProgram.identity(),
  }, ResumptionEvidence)
end

-- Test-facing constructor kept as the clean way to make empty proof evidence.
local function empty_evidence()
  return EvidenceDelta.empty()
end


local function response_values(response)
  response = response or {}
  if response.values then return response.values end
  if response.value ~= nil then return pack(response.value) end
  return pack()
end

-- Explicit post-commit continuation frame.  World.commit sends this frame back
-- through the suspended Op.perform.  The frame is interpreted inside the
-- resumed fibre coroutine, so post-commit callbacks may perform fresh transactions.
local PostCommitFrame = {}
PostCommitFrame.__index = PostCommitFrame

function PostCommitFrame.new(values, post_program)
  return setmetatable({
    tag = 'post_commit_frame',
    values = values or pack(),
    post_program = post_program or PostProgram.identity(),
  }, PostCommitFrame)
end

function PostCommitFrame.is(x)
  return type(x) == 'table' and getmetatable(x) == PostCommitFrame
end

function PostCommitFrame:run()
  return PostProgram.run(self.post_program, self.values)
end

-- --------------------------------------------------------------------------
-- Proof-net physical objects: Box / SpecPort / Cut.
--
-- A Box is a topological region.  Tensor boxes allow sibling cuts; All boxes
-- forbid them.  A SpecPort is an open speculative resource obligation.  A Cut records a
-- successful closure between two ports.
-- --------------------------------------------------------------------------

local next_proof_id = 0
local function fresh_id(prefix)
  next_proof_id = next_proof_id + 1
  return (prefix or 'id') .. '-' .. tostring(next_proof_id)
end

local RootAttempt = {}
RootAttempt.__index = RootAttempt

function RootAttempt.new(task, op, generation, ordinal)
  local id = fresh_id('attempt')
  local label = 'task-' .. tostring(task and task.id or '?') .. '/attempt-' .. tostring(ordinal or id)
  return setmetatable({
    id = id,
    ordinal = ordinal,
    label = label,
    task = task,
    op = op,
    generation = generation,
    state = 'parked',
    published_settlements = {},
    settlement_memo = {},
    guard_memo = {},
    external_waits = {},
  }, RootAttempt)
end

function RootAttempt:validate_live(runtime)
  if self.state ~= 'parked' then
    return nil, 'attempt is not parked: ' .. tostring(self.id)
  end
  if not self.task then
    return nil, 'attempt has no owning task: ' .. tostring(self.id)
  end
  if self.task.attempt ~= self then
    return nil, 'attempt is stale for task: ' .. tostring(self.id)
  end
  if self.task.attempt_id ~= self.id then
    return nil, 'attempt id is stale for task: ' .. tostring(self.id)
  end
  if self.task.parked ~= true then
    return nil, 'attempt task is not parked: ' .. tostring(self.id)
  end
  if runtime and runtime.waiting_set and not runtime.waiting_set[self.task] then
    return nil, 'attempt task is not waiting: ' .. tostring(self.id)
  end
  if runtime and self.generation and self.generation > runtime.generation then
    return nil, 'attempt generation is from the future: ' .. tostring(self.id)
  end
  return true
end

-- --------------------------------------------------------------------------
-- Stable derivation addresses and expansion context.
--
-- Allocation ids are useful for debugging physical objects, but semantic site
-- identity must be derived from how the proof expander reached a node.  These
-- addresses are stable across replay under the same root/forced decisions.
-- --------------------------------------------------------------------------

local Address = {}
Address.__index = Address

function Address.root(label)
  return setmetatable({ parts = { tostring(label or 'root') } }, Address)
end

function Address:child(...)
  local parts = list_copy(self.parts)
  local n = select('#', ...)
  for i = 1, n do parts[#parts + 1] = tostring(select(i, ...)) end
  return setmetatable({ parts = parts }, Address)
end

function Address:key()
  return table.concat(self.parts, '/')
end

local ExpansionContext = {}
ExpansionContext.__index = ExpansionContext

function ExpansionContext.root(root_label, task, forced_decisions, attempt, settlement_parent)
  attempt = attempt or (task and task.attempt) or nil
  return setmetatable({
    root = root_label,
    task = task,
    attempt = attempt,
    addr = Address.root(root_label),
    box = nil,
    lane = nil,
    forced_decisions = forced_decisions or {},
    settlement_parent = settlement_parent,
  }, ExpansionContext)
end

function ExpansionContext:child(...)
  return setmetatable({
    root = self.root,
    task = self.task,
    attempt = self.attempt,
    addr = self.addr:child(...),
    box = self.box,
    lane = self.lane,
    forced_decisions = self.forced_decisions,
    settlement_parent = self.settlement_parent,
  }, ExpansionContext)
end

function ExpansionContext:in_box(box, lane)
  return setmetatable({
    root = self.root,
    task = self.task,
    attempt = self.attempt,
    addr = self.addr,
    box = box,
    lane = lane,
    forced_decisions = self.forced_decisions,
    settlement_parent = self.settlement_parent,
  }, ExpansionContext)
end

function ExpansionContext:with_settlement_parent(parent)
  return setmetatable({
    root = self.root,
    task = self.task,
    attempt = self.attempt,
    addr = self.addr,
    box = self.box,
    lane = self.lane,
    forced_decisions = self.forced_decisions,
    settlement_parent = parent,
  }, ExpansionContext)
end

function ExpansionContext:key()
  return self.addr:key()
end

local function decision_path_key(prefix)
  local parts = {}
  for i = 1, #(prefix or {}) do
    local d = prefix[i]
    parts[#parts + 1] = tostring(d.site) .. '=' .. tostring(d.branch)
  end
  return table.concat(parts, ',')
end

local OccurrenceRef = {}
OccurrenceRef.__index = OccurrenceRef

function OccurrenceRef.new(kind, ctx, evidence, parent)
  local prefix = evidence and evidence:decision_path_view() or {}
  local task = ctx and ctx.task or nil
  local attempt = ctx and ctx.attempt or (task and task.attempt) or nil
  local site = ctx and ctx:key() or tostring(kind or 'occurrence')
  local parent_key = parent and parent.key or nil
  local attempt_id = attempt and attempt.id or (task and task.attempt_id) or nil
  local root = ctx and ctx.root or (attempt and attempt.label) or nil
  local key = table.concat({
    tostring(kind or 'occurrence'),
    tostring(root),
    tostring(attempt_id),
    tostring(site),
    decision_path_key(prefix),
    tostring(parent_key),
  }, '|')
  return setmetatable({
    kind = kind or 'occurrence',
    root = root,
    task = task,
    attempt = attempt,
    attempt_id = attempt_id,
    site = site,
    prefix = prefix,
    parent_key = parent_key,
    key = key,
  }, OccurrenceRef)
end

local SettlementRef = {}
SettlementRef.__index = SettlementRef

function SettlementRef.new(kind, ctx, evidence, parent)
  local occurrence = OccurrenceRef.new(kind or 'settlement', ctx, evidence, parent)
  return setmetatable({
    occurrence = occurrence,
    key = occurrence.key,
    root = occurrence.root,
    task = occurrence.task,
    attempt = occurrence.attempt,
    attempt_id = occurrence.attempt_id,
    site = occurrence.site,
    prefix = occurrence.prefix,
    parent_key = occurrence.parent_key,
  }, SettlementRef)
end

local SettlementCell = {}
SettlementCell.__index = SettlementCell

function SettlementCell.new(ref)
  return setmetatable({
    ref = ref,
    key = ref.key,
    state = 'pending',
    published = false,
    waiters = {},
  }, SettlementCell)
end

function SettlementCell:settle(state)
  if self.state == state then return true end
  if self.state ~= 'pending' then
    return nil, 'settlement ' .. tostring(self.key) .. ' already settled as ' .. tostring(self.state)
  end
  if state ~= 'selected' and state ~= 'lost' and state ~= 'withdrawn' then
    return nil, 'invalid settlement state: ' .. tostring(state)
  end
  self.state = state
  return true
end

local Box = {}
Box.__index = Box

function Box.new(tag, policy, ctx)
  return setmetatable({
    id = fresh_id('box'),
    tag = tag,
    policy = policy or 'external_only',
    addr = ctx and ctx:key() or nil,
  }, Box)
end

function Box.tensor(ctx)
  return Box.new('tensor', 'allow_internal', ctx)
end

function Box.all(ctx)
  return Box.new('all', 'forbid_internal', ctx)
end

local SpecPort = {}
SpecPort.__index = SpecPort

function SpecPort.new(resource, request, ctx)
  return setmetatable({
    id = fresh_id('port'),
    resource = resource,
    request = request,
    addr = ctx and ctx:key() or nil,
    root = ctx and ctx.root or nil,
    box = ctx and ctx.box or nil,
    lane = ctx and ctx.lane or nil,
  }, SpecPort)
end

local Cut = {}
Cut.__index = Cut

function Cut.new(entry_a, entry_b, response_a, response_b)
  return setmetatable({
    id = fresh_id('cut'),
    port_a = entry_a.frame.port,
    port_b = entry_b.frame.port,
    task_a = entry_a.task,
    task_b = entry_b.task,
    box_a = entry_a.group and entry_a.group.box or nil,
    box_b = entry_b.group and entry_b.group.box or nil,
    response_a = response_a,
    response_b = response_b,
  }, Cut)
end

local BoundaryLink = {}
BoundaryLink.__index = BoundaryLink

function BoundaryLink.new(post_program, ctx)
  return setmetatable({
    id = fresh_id('boundary'),
    addr = ctx and ctx:key() or nil,
    post_program = post_program or PostProgram.identity(),
  }, BoundaryLink)
end

local JoinLink = {}
JoinLink.__index = JoinLink

function JoinLink.new(kind, ctx)
  return setmetatable({
    id = fresh_id('join'),
    addr = ctx and ctx:key() or nil,
    kind = kind,
  }, JoinLink)
end

local BindLink = {}
BindLink.__index = BindLink

function BindLink.new(k, ctx)
  return setmetatable({
    kind = 'bind',
    id = fresh_id('bind'),
    addr = ctx and ctx:key() or nil,
    k = k,
    ctx = ctx,
  }, BindLink)
end

local MapLink = {}
MapLink.__index = MapLink

function MapLink.new(f, ctx)
  return setmetatable({
    kind = 'map',
    id = fresh_id('map'),
    addr = ctx and ctx:key() or nil,
    f = f,
    ctx = ctx,
  }, MapLink)
end

local PreferLink = {}
PreferLink.__index = PreferLink

function PreferLink.new(ctx)
  return setmetatable({
    id = fresh_id('prefer'),
    addr = ctx and ctx:key() or nil,
  }, PreferLink)
end

-- --------------------------------------------------------------------------
-- Op algebra
-- --------------------------------------------------------------------------

local Op = {}
local OpMethods = {}
OpMethods.__index = OpMethods
local BoundaryMethods = {}
BoundaryMethods.__index = BoundaryMethods

local function new_op(tag, fields)
  fields = fields or {}
  fields.tag = tag
  fields.sort = 'tx'
  return setmetatable(fields, OpMethods)
end

local function new_boundary(tag, fields)
  fields = fields or {}
  fields.tag = tag
  fields.sort = 'boundary'
  return setmetatable(fields, BoundaryMethods)
end

local function is_boundary(x)
  return type(x) == 'table' and getmetatable(x) == BoundaryMethods
end

function Op.always(...)
  return new_op('always', { values = pack(...) })
end

function Op.never()
  return new_op('never')
end

function Op.guard(thunk)
  if type(thunk) ~= 'function' then
    error('Op.guard expects a function', 2)
  end
  return new_op('guard', { thunk = thunk })
end

function Op.with_nack(thunk)
  if type(thunk) ~= 'function' then
    error('Op.with_nack expects a function', 2)
  end
  return new_op('with_nack', { thunk = thunk })
end

local function nack_op(ref)
  return new_op('nack', { settlement = ref })
end

function Op.choice(...)
  local n = select('#', ...)
  if n == 0 then return Op.never() end
  local op = select(1, ...)
  for i = 2, n do op = op:choice(select(i, ...)) end
  return op
end

function Op.tensor(children)
  return new_op('product', { kind = 'tensor', children = children or {} })
end

function Op.all(children)
  return new_op('product', { kind = 'all', children = children or {} })
end

function Op.request(resource, request)
  return new_op('request', { resource = resource, request = request })
end

function Op.access(resource, request)
  return new_op('access', { resource = resource, request = request })
end

function Op.await(resource, request)
  return new_op('await', { resource = resource, request = request })
end

function Op.emit(event)
  return new_op('emit', { event = event })
end

local CURRENT_TASK = nil
local PHASE = 'idle'

local function in_proof_construction_phase()
  return PHASE == 'search'
end

local function in_search_phase()
  return in_proof_construction_phase()
end

local function run_in_phase(phase, fn, ...)
  local old = PHASE
  PHASE = phase
  local result = pack(pcall(fn, ...))
  PHASE = old
  if not result[1] then error(result[2], 0) end
  return unpack_(result, 2, result.n)
end

local function with_current_task(task, fn, ...)
  local old = CURRENT_TASK
  CURRENT_TASK = task
  local result = pack(pcall(fn, ...))
  CURRENT_TASK = old
  if not result[1] then error(result[2], 0) end
  return unpack_(result, 2, result.n)
end


function Op.perform(op)
  if in_search_phase() then
    error('cannot perform during proof search expansion', 2)
  end

  local values = pack(coroutine.yield(op))
  if values.n == 1 and PostCommitFrame.is(values[1]) then
    -- The frame was created by World.commit and is deliberately interpreted
    -- here, after the proof has committed but inside the resumed fibre.
    local task = CURRENT_TASK
    local old_phase = task and task.phase or nil
    if task then task.phase = 'post_commit' end
    values = values[1]:run()
    if task then task.phase = old_phase end
  end
  return unpack_pack(values)
end

function OpMethods:and_then(k)
  return new_op('bind', { op = self, k = k })
end

function OpMethods:map(f)
  return new_op('map', { op = self, f = f })
end

function OpMethods:choice(other)
  if is_boundary(other) then
    return new_boundary('choice', { left = self, right = other })
  end
  return new_op('choice', { left = self, right = other })
end

function OpMethods:or_else(fallback)
  if is_boundary(fallback) then
    return new_boundary('prefer', { primary = self, fallback = fallback })
  end
  return new_op('prefer', { primary = self, fallback = fallback })
end

function OpMethods:wrap(f)
  return new_boundary('wrap', { inner = self, post_program = PostProgram.apply({ f }) })
end

function BoundaryMethods:choice(other)
  return new_boundary('choice', { left = self, right = other })
end

function BoundaryMethods:or_else(fallback)
  return new_boundary('prefer', { primary = self, fallback = fallback })
end

function BoundaryMethods:wrap(f)
  return new_boundary('wrap', { inner = self, post_program = PostProgram.apply({ f }) })
end

function BoundaryMethods:and_then(_)
  error('cannot transactionally sequence after wrap boundary', 2)
end

function BoundaryMethods:map(_)
  error('cannot transactionally map after wrap boundary', 2)
end

-- --------------------------------------------------------------------------
-- Proof expansion frames: the tiny proof frontier.
--
-- done frame: a closed raw proof fragment.
-- wait frame: an open resource port; must be cut with a compatible port.
-- group frame: a product box.
-- bind/map frames: explicit transactional continuation frames that wrap a
--                  source frame and reduce only when that source is raw-done.
-- --------------------------------------------------------------------------

local function frame_done(values, evidence, after_post_program)
  return {
    kind = 'done',
    values = values or pack(),
    evidence = evidence,
    after_post_program = after_post_program or PostProgram.identity(),
  }
end

local function frame_wait(resource, request, evidence, ctx, after_post_program)
  return {
    kind = 'wait',
    resource = resource,
    request = request,
    port = SpecPort.new(resource, request, ctx),
    evidence = evidence,
    after_post_program = after_post_program or PostProgram.identity(),
    addr = ctx and ctx:key() or nil,
  }
end

local function frame_nack(ref, evidence, ctx, after_post_program)
  return {
    kind = 'nack',
    settlement = ref,
    evidence = evidence,
    after_post_program = after_post_program or PostProgram.identity(),
    addr = ctx and ctx:key() or nil,
  }
end

local function frame_await(resource, request, evidence, ctx, after_post_program)
  return {
    kind = 'await',
    resource = resource,
    request = request,
    evidence = evidence,
    after_post_program = after_post_program or PostProgram.identity(),
    addr = ctx and ctx:key() or nil,
  }
end

local function is_continuation_frame(frame)
  return frame and (frame.kind == 'bind' or frame.kind == 'map')
end

local function frame_bind(source, link, after_post_program)
  return {
    kind = 'bind',
    source = source,
    link = link,
    after_post_program = after_post_program or PostProgram.identity(),
  }
end

local function frame_map(source, link, after_post_program)
  return {
    kind = 'map',
    source = source,
    link = link,
    after_post_program = after_post_program or PostProgram.identity(),
  }
end

local function frame_with_source(frame, source)
  if frame.kind == 'bind' then
    return frame_bind(source, frame.link, frame.after_post_program)
  elseif frame.kind == 'map' then
    return frame_map(source, frame.link, frame.after_post_program)
  else
    error('frame_with_source expected continuation frame, got ' .. tostring(frame and frame.kind), 2)
  end
end

local function frame_current_post_program(frame)
  if not frame then return PostProgram.identity() end
  if frame.kind == 'group' then return frame.post_program or PostProgram.identity() end
  if is_continuation_frame(frame) then return frame_current_post_program(frame.source) end
  return (frame.evidence and frame.evidence.post.program) or PostProgram.identity()
end

local function frame_after_post_program(frame)
  return (frame and frame.after_post_program) or PostProgram.identity()
end

local function frame_post_program(frame)
  return PostProgram.compose(frame_current_post_program(frame), frame_after_post_program(frame))
end

local function frame_boundary_tainted(frame)
  return not PostProgram.is_identity(frame_post_program(frame))
end

local function frame_pre_link_boundary_tainted(frame)
  return not PostProgram.is_identity(frame_current_post_program(frame))
end

local function frame_compose_after_post(frame, program)
  program = program or PostProgram.identity()
  if PostProgram.is_identity(program) then return frame end
  frame.after_post_program = PostProgram.compose(frame_after_post_program(frame), program)
  return frame
end

local function frame_attach_continuation(frame, link)
  if frame_boundary_tainted(frame) then
    if frame and frame.kind == 'group' then
      error('cannot attach transactional continuation after product containing boundary lane', 2)
    end
    error('cannot attach transactional continuation after boundary-tainted value', 2)
  end
  if link.kind == 'bind' then
    return frame_bind(frame, link)
  elseif link.kind == 'map' then
    return frame_map(frame, link)
  else
    error('unknown continuation link kind: ' .. tostring(link and link.kind), 2)
  end
end

local function attach_continuation_to_frames(frames, link)
  local out = {}
  for i = 1, #frames do
    out[#out + 1] = frame_attach_continuation(frames[i], link)
  end
  return out
end

local function frame_product(kind, lanes, ctx, box, base_evidence)
  box = box or ((kind == 'tensor') and Box.tensor(ctx) or Box.all(ctx))
  local join = JoinLink.new(kind, ctx and ctx:child('join'))

  local lane_programs = {}
  local tainted = false
  for i = 1, #(lanes or {}) do
    lane_programs[i] = frame_post_program(lanes[i])
    if not PostProgram.is_identity(lane_programs[i]) then tainted = true end
  end

  return {
    kind = 'group',
    group_kind = kind,
    box = box,
    join = join,
    lanes = lanes,
    -- The evidence inherited before entering the product belongs to the
    -- product box as a whole, not to each lane.  Lane frames carry only local
    -- deltas, while this base_evidence is merged once when the box is joined/worlded.
    base_evidence = (base_evidence or empty_evidence()):materialize(),
    post_program = PostProgram.product(lane_programs),
    after_post_program = PostProgram.identity(),
    boundary_tainted = tainted,
    addr = ctx and ctx:key() or nil,
    ctx = ctx,
  }
end

local function peel_continuation_chain_to_group(frame)
  if frame and frame.kind == 'group' then return frame, {} end
  if is_continuation_frame(frame) then
    local group, chain = peel_continuation_chain_to_group(frame.source)
    if group then
      chain[#chain + 1] = {
        kind = frame.kind,
        link = frame.link,
        after_post_program = frame_after_post_program(frame),
      }
      return group, chain
    end
  end
  return nil, nil
end

local function rebuild_continuation_chain(source, chain)
  local frame = source
  for i = 1, #(chain or {}) do
    local c = chain[i]
    if c.kind == 'bind' then
      frame = frame_bind(frame, c.link, c.after_post_program)
    elseif c.kind == 'map' then
      frame = frame_map(frame, c.link, c.after_post_program)
    else
      error('unknown continuation chain kind: ' .. tostring(c.kind), 2)
    end
  end
  return frame
end


local function frame_add_selected_settlement(frame, ref)
  if frame.kind == 'done' or frame.kind == 'wait' or frame.kind == 'nack' then
    local evidence = (frame.evidence or empty_evidence()):clone_local()
    evidence:add_selected_settlement(ref)
    frame.evidence = evidence
    return frame
  end

  if is_continuation_frame(frame) then
    frame.source = frame_add_selected_settlement(frame.source, ref)
    return frame
  end

  if frame.kind == 'group' then
    local base = EvidenceDelta.delta(frame.base_evidence or empty_evidence())
    base:add_selected_settlement(ref)
    frame.base_evidence = base:materialize()
    return frame
  end

  error('cannot attach selected settlement to frame kind: ' .. tostring(frame and frame.kind), 2)
end

local function collect_selected_from_evidence(evidence, out, seen)
  if not evidence then return end
  if evidence.base then collect_selected_from_evidence(evidence.base, out, seen) end

  local commit = evidence.commit or {}
  for _, key in ipairs(commit.selected_settlement_order or {}) do
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = commit.selected_settlements[key]
    end
  end
end

local function frame_collect_publishable_settlements(frame, out, seen)
  if not frame then return end

  if frame.kind == 'done' or frame.kind == 'wait' or frame.kind == 'nack' then
    collect_selected_from_evidence(frame.evidence, out, seen)
    return
  end

  if is_continuation_frame(frame) then
    frame_collect_publishable_settlements(frame.source, out, seen)
    return
  end

  if frame.kind == 'group' then
    collect_selected_from_evidence(frame.base_evidence, out, seen)
    for i = 1, #(frame.lanes or {}) do
      frame_collect_publishable_settlements(frame.lanes[i], out, seen)
    end
    return
  end
end


local function frame_collect_external_waits(frame, out, seen)
  if not frame then return end

  if frame.kind == 'await' then
    local key = tostring(frame.resource) .. '|' .. tostring(frame.addr or frame)
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = frame
    end
    return
  end

  if is_continuation_frame(frame) then
    frame_collect_external_waits(frame.source, out, seen)
    return
  end

  if frame.kind == 'group' then
    for i = 1, #(frame.lanes or {}) do
      frame_collect_external_waits(frame.lanes[i], out, seen)
    end
    return
  end
end

local function frame_open_wait(frame)
  if not frame then return nil end
  if frame.kind == 'wait' then return frame end
  if is_continuation_frame(frame) then return frame_open_wait(frame.source) end
  return nil
end

local function frame_after_cut(frame, response)
  if frame.kind == 'wait' then
    local evidence = frame.evidence:clone_local()
    local ok_evidence, reason = evidence:merge_response(response)
    if not ok_evidence then return nil, reason end
    return frame_done(response_values(response), evidence, frame_after_post_program(frame))
  elseif is_continuation_frame(frame) then
    local source, reason = frame_after_cut(frame.source, response)
    if not source then return nil, reason end
    return frame_with_source(frame, source)
  else
    return nil, 'frame has no open wait frontier'
  end
end

local expand_expr
local callback_returned_op

local function cartesian_frontiers(children, base_evidence, ctx, box, i, acc, out)
  if i > #children then
    local lanes = {}
    for j = 1, #acc do lanes[j] = acc[j] end
    out[#out + 1] = lanes
    return
  end

  local child_ctx = ctx and ctx:child('lane', i):in_box(box, i) or nil
  local frames = expand_expr(children[i], EvidenceDelta.delta(base_evidence), child_ctx)
  for r = 1, #frames do
    acc[i] = frames[r]
    cartesian_frontiers(children, base_evidence, ctx, box, i + 1, acc, out)
    acc[i] = nil
  end
end

local function expand_after_cut(frame, response)
  local next_frame, reason = frame_after_cut(frame, response)
  if not next_frame then return {} end
  return { next_frame }
end

local function attach_boundary(frames, boundary)
  local program = boundary.post_program or PostProgram.identity()
  for _, r in ipairs(frames) do
    if is_continuation_frame(r) then
      -- This is a boundary around a transactional continuation such as
      -- op:and_then(k):wrap(f).  The wrapper belongs after the explicit
      -- BindFrame/MapFrame has reduced, not before its source value.
      frame_compose_after_post(r, program)

    elseif r.kind == 'group' then
      r.post_program = PostProgram.compose(r.post_program, program)
      r.boundary_tainted = true

    else
      local evidence = r.evidence:clone_local()
      evidence:compose_post_program(program)
      r.evidence = evidence
    end
  end
  return frames
end


local function fallback_op(fallback)
  if type(fallback) == 'function' then return Op.guard(fallback) end
  return fallback
end

local function evidence_with_decision(evidence, site, branch, ctx, creates_obligation)
  -- A decision path entry records both the prefix that led to this site and the
  -- branch chosen at this site.  Fallback absence proofs must replay the prefix
  -- exactly, then flip this site to primary; therefore the obligation prefix is
  -- the path *before* appending the fallback decision.
  local prefix_before_site = evidence:decision_path_view()
  local occurrence = OccurrenceRef.new('prefer', ctx, evidence)

  local e = evidence:clone_local()
  e.decisions[site] = branch

  local decision_entry = {
    site = site,
    branch = branch,
    prefix = prefix_before_site,
  }
  e.decision_path[#e.decision_path + 1] = decision_entry

  if creates_obligation then
    e:add_pre_commit_obligation {
      kind = 'prefer_absence',
      root = ctx and ctx.root or nil,
      task = ctx and ctx.task or nil,
      site = site,
      prefix = prefix_before_site,
      force = 'primary',
      fallback_entry = decision_entry,
      occurrence = occurrence,
    }
  end
  return e
end

local function guard_memo_key(ctx, evidence)
  local prefix = evidence and evidence:decision_path_view() or {}
  return table.concat({
    'guard',
    tostring(ctx and ctx.root or 'anonymous'),
    tostring(ctx and ctx:key() or 'guard'),
    decision_path_key(prefix),
  }, '|')
end

local function expand_guard(op, evidence, ctx)
  local guard_ctx = ctx and ctx:child('guard') or ExpansionContext.root('guard')
  local attempt = guard_ctx.attempt
  local key = guard_memo_key(guard_ctx, evidence)
  local guarded_op

  if attempt and attempt.guard_memo then
    local memo = attempt.guard_memo[key]
    if memo then
      guarded_op = memo.op
    else
      guarded_op = run_in_phase('search', function()
        return callback_returned_op('guard', op.thunk())
      end)
      attempt.guard_memo[key] = { op = guarded_op }
    end
  else
    guarded_op = run_in_phase('search', function()
      return callback_returned_op('guard', op.thunk())
    end)
  end

  return expand_expr(
    guarded_op,
    evidence:clone_local(),
    guard_ctx:child('body')
  )
end


local function expand_with_nack(op, evidence, ctx)
  local wn_ctx = ctx and ctx:child('with_nack') or ExpansionContext.root('with_nack')
  local attempt = wn_ctx.attempt
  local parent = wn_ctx.settlement_parent
  local ref0 = SettlementRef.new('with_nack', wn_ctx, evidence, parent)
  local memo

  if attempt and attempt.settlement_memo then
    memo = attempt.settlement_memo[ref0.key]
  end

  if not memo then
    local ref = ref0
    local nack = nack_op(ref)
    local protected = run_in_phase('search', function()
      return callback_returned_op('with_nack', op.thunk(nack))
    end)

    memo = { ref = ref, nack = nack, protected = protected }
    if attempt and attempt.settlement_memo then
      attempt.settlement_memo[ref.key] = memo
    end
  end

  local body_ctx = wn_ctx:with_settlement_parent(memo.ref):child('body')
  local frames = expand_expr(memo.protected, evidence:clone_local(), body_ctx)
  for i = 1, #frames do
    frames[i] = frame_add_selected_settlement(frames[i], memo.ref)
  end
  return frames
end

local function expand_prefer(primary, fallback, evidence, ctx)
  local prefer_ctx = ctx and ctx:child('prefer') or ExpansionContext.root('prefer')
  local link = PreferLink.new(prefer_ctx)
  local site = link.addr
  local forced = prefer_ctx.forced_decisions and prefer_ctx.forced_decisions[site]

  if forced == 'primary' then
    local e = evidence_with_decision(evidence, site, 'primary', prefer_ctx, false)
    return expand_expr(primary, e, prefer_ctx:child('primary'))
  elseif forced == 'fallback' then
    local e = evidence_with_decision(evidence, site, 'fallback', prefer_ctx, false)
    return expand_expr(fallback_op(fallback), e, prefer_ctx:child('fallback'))
  end

  local out = expand_expr(primary, evidence_with_decision(evidence, site, 'primary', prefer_ctx, false), prefer_ctx:child('primary'))
  list_append(out, expand_expr(fallback_op(fallback), evidence_with_decision(evidence, site, 'fallback', prefer_ctx, true), prefer_ctx:child('fallback')))
  return out
end

local function expand_boundary(boundary, evidence, ctx)
  if boundary.tag == 'wrap' then
    local link = BoundaryLink.new(boundary.post_program or PostProgram.identity(), ctx and ctx:child('boundary'))
    local frames = expand_expr(boundary.inner, evidence:clone_local(), ctx and ctx:child('boundary', 'inner'))
    return attach_boundary(frames, link)
  elseif boundary.tag == 'choice' then
    local out = expand_expr(boundary.left, evidence:clone_local(), ctx and ctx:child('choice', 'left'))
    list_append(out, expand_expr(boundary.right, evidence:clone_local(), ctx and ctx:child('choice', 'right')))
    return out
  elseif boundary.tag == 'prefer' then
    return expand_prefer(boundary.primary, boundary.fallback, evidence:clone_local(), ctx)
  else
    error('unknown boundary tag: ' .. tostring(boundary.tag))
  end
end

expand_expr = function(op, evidence, ctx)
  evidence = evidence or empty_evidence()
  ctx = ctx or ExpansionContext.root('anonymous')

  if is_boundary(op) then
    return expand_boundary(op, evidence, ctx)
  end

  if op.tag == 'always' then
    return { frame_done(op.values, evidence:clone_local()) }

  elseif op.tag == 'never' then
    return {}

  elseif op.tag == 'guard' then
    return expand_guard(op, evidence:clone_local(), ctx)

  elseif op.tag == 'with_nack' then
    return expand_with_nack(op, evidence:clone_local(), ctx)

  elseif op.tag == 'nack' then
    return {
      frame_nack(op.settlement, evidence:clone_local(), ctx:child('nack'))
    }

  elseif op.tag == 'choice' then
    local out = expand_expr(op.left, evidence:clone_local(), ctx:child('choice', 'left'))
    list_append(out, expand_expr(op.right, evidence:clone_local(), ctx:child('choice', 'right')))
    return out

  elseif op.tag == 'prefer' then
    return expand_prefer(op.primary, op.fallback, evidence:clone_local(), ctx)

  elseif op.tag == 'bind' then
    local link = BindLink.new(op.k, ctx:child('bind'))
    local frames = expand_expr(op.op, evidence:clone_local(), ctx:child('bind', 'source'))
    return attach_continuation_to_frames(frames, link)

  elseif op.tag == 'map' then
    local link = MapLink.new(op.f, ctx:child('map'))
    local frames = expand_expr(op.op, evidence:clone_local(), ctx:child('map', 'source'))
    return attach_continuation_to_frames(frames, link)

  elseif op.tag == 'product' then
    if #op.children == 0 then return { frame_done(pack({}), evidence:clone_local()) } end
    local product_ctx = ctx:child(op.kind)
    local box = (op.kind == 'tensor') and Box.tensor(product_ctx) or Box.all(product_ctx)
    local base_evidence = evidence:materialize()
    local combos = {}
    cartesian_frontiers(op.children, base_evidence, product_ctx, box, 1, {}, combos)
    local out = {}
    for i = 1, #combos do
      out[#out + 1] = frame_product(op.kind, combos[i], product_ctx, box, base_evidence)
    end
    return out

  elseif op.tag == 'request' then
    return {
      frame_wait(op.resource, op.request, evidence:clone_local(), ctx:child('request'))
    }

  elseif op.tag == 'await' then
    return {
      frame_await(op.resource, op.request, evidence:clone_local(), ctx:child('await'))
    }

  elseif op.tag == 'access' then
    local evidence2 = evidence:clone_local()

    -- Reads observe the inherited proof context plus this lane's local delta.
    -- Writes remain local: resources that need the inherited view to answer a
    -- request may provide step_fragment_with_view(base_plus_delta, local_delta,
    -- request), returning the next local delta.  Without a base-aware method,
    -- ordinary resources keep the old local-fragment discipline.
    local local_fragment = evidence2:local_fragment(op.resource)
    local view, view_reason = evidence2:fragment_view(op.resource)
    if view == nil then return {} end

    local ok, response, next_local_fragment
    if op.resource.step_fragment_with_view then
      ok, response, next_local_fragment = op.resource:step_fragment_with_view(view, local_fragment, op.request)
    else
      ok, response, next_local_fragment = op.resource:step_fragment(local_fragment, op.request)
    end
    if not ok then return {} end

    evidence2:add_fragment(op.resource, next_local_fragment)
    local ok_evidence = evidence2:merge_response(response)
    if not ok_evidence then return {} end

    return { frame_done(response_values(response), evidence2) }

  elseif op.tag == 'emit' then
    local evidence2 = evidence:clone_local()
    evidence2:add_commit_descriptor(op.event)
    return { frame_done(pack(), evidence2) }

  else
    error('unknown op tag: ' .. tostring(op.tag))
  end
end

-- --------------------------------------------------------------------------
-- World: a closed proof ready to commit.
-- --------------------------------------------------------------------------

local World = {}
World.__index = World

local function merge_entry_evidence(entries)
  local evidence = EvidenceDelta.empty()
  local seen_groups = {}

  for _, entry in ipairs(entries or {}) do
    if entry.group then
      if not seen_groups[entry.group] then
        local ok, reason = evidence:merge_certificate_from(entry.group.base_evidence, true)
        if not ok then return nil, reason end
        seen_groups[entry.group] = true
      end

      -- Product lane frames carry local deltas.  Do not include evidence.base here;
      -- the product box base has already been merged exactly once above.
      local ok, reason = evidence:merge_certificate_from(entry.frame.evidence, false)
      if not ok then return nil, reason end
    else
      local ok, reason = evidence:merge_certificate_from(entry.frame.evidence, true)
      if not ok then return nil, reason end
    end
  end

  return evidence
end

local function build_resumption_certificate(entries)
  local task_order = {}
  local seen_task = {}
  local grouped = {}
  local direct = {}

  local function note_task(task)
    if not seen_task[task] then
      task_order[#task_order + 1] = task
      seen_task[task] = true
    end
  end

  for _, entry in ipairs(entries or {}) do
    note_task(entry.task)
    if entry.group then
      local g = grouped[entry.task]
      if not g then
        g = {
          lane_count = entry.group.lane_count,
          values = {},
          post_program = entry.group.post_program or PostProgram.identity(),
        }
        grouped[entry.task] = g
      end
      g.values[entry.lane] = entry.frame.values
    elseif not direct[entry.task] then
      direct[entry.task] = ResumptionEvidence.new(entry.task and entry.task.attempt, entry.task, entry.frame.values, frame_post_program(entry.frame))
    end
  end

  local resumptions = {}
  for _, task in ipairs(task_order) do
    if direct[task] then
      resumptions[#resumptions + 1] = direct[task]
    elseif grouped[task] then
      local g = grouped[task]
      local results = {}
      for i = 1, g.lane_count do results[i] = g.values[i] end
      resumptions[#resumptions + 1] = ResumptionEvidence.new(task and task.attempt, task, pack(results), g.post_program)
    end
  end
  return resumptions
end

function World.from_entries(entries, cuts)
  for _, entry in ipairs(entries) do
    if entry.frame.kind ~= 'done' then return nil, 'world is not closed' end
  end

  local evidence_delta, reason = merge_entry_evidence(entries)
  if not evidence_delta then return nil, reason end
  local evidence = WorldEvidence.from_delta(evidence_delta)
  local ok, validate_reason = evidence:validate_resources()
  if not ok then return nil, validate_reason end

  return setmetatable({
    entries = entries,
    cuts = cuts or {},
    evidence = evidence,
    resumptions = build_resumption_certificate(entries),
  }, World)
end

function World:preference_obligations()
  return self.evidence.pre_commit.obligations or {}
end

function World:commit_descriptors()
  return self.evidence.commit.descriptors or {}
end

function World:is_committable()
  return #(self:preference_obligations()) == 0 or self.preference_obligations_discharged == true
end

function World.from_proof(proof)
  return World.from_entries(proof.entries, proof.cuts)
end

local Commit = {}
Commit.__index = Commit

function Commit.new()
  return setmetatable({ events = {} }, Commit)
end

function Commit:emit(event)
  self.events[#self.events + 1] = event
end

local function default_print_event(event)
  if event.tag == 'ledger.move' then
    print(string.format('[commit event] move %s: %s -> %s', tostring(event.item), tostring(event.from), tostring(event.to)))
  elseif event.tag == 'ledger.close' then
    print(string.format('[commit event] close %s reason=%s', tostring(event.owner), tostring(event.reason)))
  else
    print('[commit event] ' .. tostring(event.tag))
  end
end

M.print_event = default_print_event

local CommitPlan = {}
CommitPlan.__index = CommitPlan

function CommitPlan.prepare(world, runtime)
  if not world:is_committable() then error('world is valid but not committable', 2) end

  local attempts = {}
  local seen_attempt = {}
  for _, resumption in ipairs(world.resumptions or {}) do
    local attempt = resumption.attempt
    if not attempt then
      return nil, 'resumption has no RootAttempt for task: ' .. tostring(resumption.task and resumption.task.name or resumption.task)
    end
    local ok_attempt, attempt_reason = attempt:validate_live(runtime)
    if not ok_attempt then return nil, attempt_reason end
    if not seen_attempt[attempt] then
      attempts[#attempts + 1] = attempt
      seen_attempt[attempt] = true
    end
  end

  local commit = Commit.new()
  local resources = world.evidence.resources

  -- Validate/prepare commit descriptors without installing state.
  for _, resource in ipairs(resources.fragment_order) do
    if resource.prepare_commit_fragment then
      resource:prepare_commit_fragment(resources.fragments[resource], commit)
    end
  end
  list_append(commit.events, world:commit_descriptors())

  local settlement_updates, settlement_reason = runtime:prepare_world_settlement_updates(world)
  if not settlement_updates then return nil, settlement_reason end

  return setmetatable({
    world = world,
    attempts = attempts,
    resources = resources,
    settlement_updates = settlement_updates,
    events = commit.events,
    resumptions = world.resumptions or {},
  }, CommitPlan)
end

function CommitPlan:apply(runtime)
  -- Revalidate live attempts before mutating runtime state.  Prepare is a dry
  -- run; apply is the single interpreter pass for the prepared plan.
  for _, attempt in ipairs(self.attempts or {}) do
    local ok_attempt, attempt_reason = attempt:validate_live(runtime)
    if not ok_attempt then error(attempt_reason or 'stale RootAttempt in commit plan', 2) end
  end

  -- Install resource fragments.
  for _, resource in ipairs(self.resources.fragment_order) do
    if resource.commit_fragment then
      resource:commit_fragment(self.resources.fragments[resource])
    end
  end

  -- Interpret settlement updates computed by CommitPlan.prepare.
  local ok_settlement, settlement_reason = runtime:apply_settlement_updates(self.settlement_updates)
  if not ok_settlement then error(settlement_reason or 'settlement commit failed', 2) end

  runtime:bump_generation('commit')

  -- Interpret commit descriptors.
  for _, event in ipairs(self.events) do
    if runtime and runtime.emit_descriptor then
      runtime:emit_descriptor(event)
    else
      M.print_event(event)
    end
  end

  -- Resume each participating root through its own post-commit value program.
  for _, resumption in ipairs(self.resumptions or {}) do
    if resumption.attempt and resumption.attempt.state == 'parked' then
      resumption.attempt.state = 'committed'
    end
    runtime:unpark(resumption.task, 'commit')
    resumption.task.values = pack(PostCommitFrame.new(resumption.values, resumption.post_program))
    runtime.runnable[#runtime.runnable + 1] = resumption.task
  end
end

function World:commit(runtime)
  local plan, reason = CommitPlan.prepare(self, runtime)
  if not plan then error(reason or 'could not prepare commit', 2) end
  return plan:apply(runtime)
end

-- --------------------------------------------------------------------------
-- Runtime / proof search.
-- --------------------------------------------------------------------------

-- Runtime is implemented in runtime.lua.  The core below remains the
-- transaction algebra, proof frontier, proof search and commit planner.

local function copy_entries(entries)
  local out = {}
  for i = 1, #entries do out[i] = entries[i] end
  return out
end

local function copy_cuts(cuts)
  local out = {}
  for i = 1, #(cuts or {}) do out[i] = cuts[i] end
  return out
end

local function expand_top_frame(task, frame)
  local group_frame, continuation_chain = peel_continuation_chain_to_group(frame)
  if group_frame then
    local entries = {}
    local group = {
      task = task,
      attempt = task and task.attempt or nil,
      box = group_frame.box,
      kind = group_frame.group_kind,
      lane_count = #group_frame.lanes,
      continuation_chain = continuation_chain or {},
      post_program = frame_post_program(group_frame),
      after_post_program = PostProgram.identity(),
      boundary_tainted = frame_boundary_tainted(group_frame),
      base_evidence = (group_frame.base_evidence or empty_evidence()):materialize(),
    }
    for i = 1, #group_frame.lanes do
      entries[i] = { task = task, frame = group_frame.lanes[i], group = group, lane = i }
    end
    return entries
  end
  return { { task = task, frame = frame } }
end

local PartialProof = {}
PartialProof.__index = PartialProof

function PartialProof.new(entries, used_tasks, cuts)
  return setmetatable({
    entries = entries or {},
    used_tasks = used_tasks or {},
    cuts = cuts or {},
  }, PartialProof)
end

function PartialProof:fork(changes)
  changes = changes or {}
  return PartialProof.new(
    changes.entries or copy_entries(self.entries),
    changes.used_tasks or shallow_copy(self.used_tasks),
    changes.cuts or copy_cuts(self.cuts)
  )
end

function PartialProof:with_entries(entries)
  return self:fork({ entries = entries })
end

function PartialProof:with_entries_and_cuts(entries, cuts)
  return self:fork({ entries = entries, cuts = cuts })
end

local function group_has_continuation(group)
  return group and group.continuation_chain and #group.continuation_chain > 0
end

function PartialProof:is_closed()
  for i = 1, #self.entries do
    local e = self.entries[i]
    if e.frame.kind ~= 'done' then return false end
    if e.group and group_has_continuation(e.group) then return false end
  end
  return true
end

function PartialProof:world()
  if not self:is_closed() then return nil, 'proof has open ports' end
  return World.from_proof(self)
end

callback_returned_op = function(where, value)
  if (type(value) == 'table' and (getmetatable(value) == OpMethods or getmetatable(value) == BoundaryMethods)) then
    return value
  end
  error(where .. ' callback must return an Op', 2)
end

local function frame_has_ready_continuation(frame)
  if not is_continuation_frame(frame) then return false end
  if frame.source.kind == 'done' then return true end
  return frame_has_ready_continuation(frame.source)
end

local function reduce_continuation_frame(frame)
  if not is_continuation_frame(frame) then return nil end

  if frame.source.kind == 'done' then
    if frame_pre_link_boundary_tainted(frame.source) then
      error('cannot reduce transactional continuation after boundary-tainted value', 2)
    end

    local source = frame.source
    local link = frame.link
    local replacement_frames = {}

    if frame.kind == 'bind' then
      local next_op = callback_returned_op('bind', link.k(unpack_pack(source.values)))
      local next_frames = expand_expr(next_op, source.evidence, link.ctx or ExpansionContext.root('bind-cont'))
      for i = 1, #next_frames do
        local nf = next_frames[i]
        frame_compose_after_post(nf, frame_after_post_program(frame))
        replacement_frames[#replacement_frames + 1] = nf
      end

    elseif frame.kind == 'map' then
      replacement_frames[1] = frame_done(pack(link.f(unpack_pack(source.values))), source.evidence, frame_after_post_program(frame))

    else
      error('unknown continuation frame kind: ' .. tostring(frame.kind), 2)
    end

    return replacement_frames
  end

  local reduced_sources = reduce_continuation_frame(frame.source)
  if not reduced_sources then return nil end

  local out = {}
  for i = 1, #reduced_sources do
    out[i] = frame_with_source(frame, reduced_sources[i])
  end
  return out
end

function PartialProof:find_ready_continuation_entry()
  for i = 1, #self.entries do
    local e = self.entries[i]
    if frame_has_ready_continuation(e.frame) then
      return i, e
    end
  end
  return nil
end

function PartialProof:reduce_ready_continuation_entry()
  local index, entry = self:find_ready_continuation_entry()
  if not entry then return nil end

  local replacement_frames = reduce_continuation_frame(entry.frame)
  if not replacement_frames then return nil end

  local out = {}
  for _, next_top in ipairs(replacement_frames) do
    local next_entries = {}
    for i, e in ipairs(self.entries) do
      if i ~= index then next_entries[#next_entries + 1] = e end
    end
    local expanded = expand_top_frame(entry.task, next_top)
    for _, e in ipairs(expanded) do next_entries[#next_entries + 1] = e end
    local p2 = self:with_entries(next_entries)
    if p2:fragments_compatible() then out[#out + 1] = p2 end
  end
  return out
end


local function frame_has_ready_nack(frame, runtime)
  if not frame then return false end

  if frame.kind == 'nack' then
    local cell = runtime:settlement_cell(frame.settlement)
    return cell.state == 'lost' or cell.state == 'withdrawn'
  end

  if is_continuation_frame(frame) then
    return frame_has_ready_nack(frame.source, runtime)
  end

  return false
end

local function reduce_nack_frame(frame, runtime)
  if frame.kind == 'nack' then
    local cell = runtime:settlement_cell(frame.settlement)
    if cell.state == 'lost' or cell.state == 'withdrawn' then
      return { frame_done(pack(), frame.evidence, frame_after_post_program(frame)) }
    end
    return nil
  end

  if is_continuation_frame(frame) then
    local reduced_sources = reduce_nack_frame(frame.source, runtime)
    if not reduced_sources then return nil end

    local out = {}
    for i = 1, #reduced_sources do
      out[i] = frame_with_source(frame, reduced_sources[i])
    end
    return out
  end

  return nil
end

function PartialProof:find_ready_nack_entry(runtime)
  for i = 1, #self.entries do
    local e = self.entries[i]
    if frame_has_ready_nack(e.frame, runtime) then
      return i, e
    end
  end
  return nil
end

function PartialProof:reduce_ready_nack_entry(runtime)
  local index, entry = self:find_ready_nack_entry(runtime)
  if not entry then return nil end

  local replacement_frames = reduce_nack_frame(entry.frame, runtime)
  if not replacement_frames then return nil end

  local out = {}
  for _, next_top in ipairs(replacement_frames) do
    local next_entries = {}
    for i, e in ipairs(self.entries) do
      if i ~= index then next_entries[#next_entries + 1] = e end
    end

    if entry.group then
      -- A nack reduced inside an all/tensor lane remains that lane.
      -- Expanding it as a fresh top frame would turn it into a direct root
      -- result and corrupt the product resumption certificate.
      next_entries[#next_entries + 1] = {
        task = entry.task,
        frame = next_top,
        group = entry.group,
        lane = entry.lane,
      }
    else
      local expanded = expand_top_frame(entry.task, next_top)
      for _, e in ipairs(expanded) do next_entries[#next_entries + 1] = e end
    end

    local p2 = self:with_entries(next_entries)
    if p2:fragments_compatible() then out[#out + 1] = p2 end
  end
  return out
end


local function frame_has_ready_await(frame, runtime)
  if not frame then return false end

  if frame.kind == 'await' then
    if not frame.resource or not frame.resource.ready then return false end
    local ok = frame.resource:ready(frame.request, runtime)
    return ok and true or false
  end

  if is_continuation_frame(frame) then
    return frame_has_ready_await(frame.source, runtime)
  end

  return false
end

local function reduce_await_frame(frame, runtime)
  if frame.kind == 'await' then
    if not frame.resource or not frame.resource.ready then return nil end
    local ok, response = frame.resource:ready(frame.request, runtime)
    if not ok then return nil end

    local evidence = frame.evidence:clone_local()
    if response then
      local ok_evidence = evidence:merge_response(response)
      if not ok_evidence then return nil end
    end
    return { frame_done(response_values(response or { value = true }), evidence, frame_after_post_program(frame)) }
  end

  if is_continuation_frame(frame) then
    local reduced_sources = reduce_await_frame(frame.source, runtime)
    if not reduced_sources then return nil end

    local out = {}
    for i = 1, #reduced_sources do
      out[i] = frame_with_source(frame, reduced_sources[i])
    end
    return out
  end

  return nil
end

function PartialProof:find_ready_await_entry(runtime)
  for i = 1, #self.entries do
    local e = self.entries[i]
    if frame_has_ready_await(e.frame, runtime) then
      return i, e
    end
  end
  return nil
end

function PartialProof:reduce_ready_await_entry(runtime)
  local index, entry = self:find_ready_await_entry(runtime)
  if not entry then return nil end

  local replacement_frames = reduce_await_frame(entry.frame, runtime)
  if not replacement_frames then return nil end

  local out = {}
  for _, next_top in ipairs(replacement_frames) do
    local next_entries = {}
    for i, e in ipairs(self.entries) do
      if i ~= index then next_entries[#next_entries + 1] = e end
    end

    if entry.group then
      next_entries[#next_entries + 1] = {
        task = entry.task,
        frame = next_top,
        group = entry.group,
        lane = entry.lane,
      }
    else
      local expanded = expand_top_frame(entry.task, next_top)
      for _, e in ipairs(expanded) do next_entries[#next_entries + 1] = e end
    end

    local p2 = self:with_entries(next_entries)
    if p2:fragments_compatible() then out[#out + 1] = p2 end
  end
  return out
end

function PartialProof:find_complete_join_group()
  local seen = {}
  for _, entry in ipairs(self.entries) do
    local group = entry.group
    if group_has_continuation(group) and not seen[group] then
      seen[group] = true
      local lane_entries = {}
      local count = 0
      for _, e in ipairs(self.entries) do
        if e.group == group then
          if e.frame.kind ~= 'done' then
            lane_entries = nil
            break
          end
          lane_entries[e.lane] = e
          count = count + 1
        end
      end
      if lane_entries and count == group.lane_count then
        return group, lane_entries
      end
    end
  end
  return nil
end

function PartialProof:reduce_complete_join_group()
  local group, lane_entries = self:find_complete_join_group()
  if not group then return nil end
  if group.boundary_tainted then
    error('cannot reduce boundary-tainted product into transactional continuation', 2)
  end

  local merge_inputs = {}
  local results = {}
  for lane = 1, group.lane_count do
    local entry = lane_entries[lane]
    if not entry then return nil end
    merge_inputs[#merge_inputs + 1] = entry
    results[lane] = entry.frame.values
  end

  local evidence, reason = merge_entry_evidence(merge_inputs)
  if not evidence then return nil, reason end

  local joined = frame_done(pack(results), evidence, group.after_post_program)
  local next_top = rebuild_continuation_chain(joined, group.continuation_chain)
  local out = {}
  local next_entries = {}
  for _, e in ipairs(self.entries) do
    if e.group ~= group then
      next_entries[#next_entries + 1] = e
    end
  end

  local expanded = expand_top_frame(group.task, next_top)
  for _, e in ipairs(expanded) do
    next_entries[#next_entries + 1] = e
  end

  local p2 = self:with_entries(next_entries)
  if p2:fragments_compatible() then out[#out + 1] = p2 end
  return out
end

function PartialProof:cut_allowed(entry_a, entry_b)
  -- Different roots may always cut if the resource permits it.
  if entry_a.task ~= entry_b.task then return true end

  -- Same-root cuts are only legal between distinct lanes of the same tensor box.
  if entry_a.group and entry_b.group and entry_a.group == entry_b.group and entry_a.lane ~= entry_b.lane then
    return entry_a.group.box.policy == 'allow_internal'
  end

  return false
end

function PartialProof:fragments_compatible(entries)
  local evidence, reason = merge_entry_evidence(entries or self.entries)
  if not evidence then return false, reason end
  return true
end

function PartialProof:try_cut(entry_a, entry_b)
  local wait_a = frame_open_wait(entry_a.frame)
  local wait_b = frame_open_wait(entry_b.frame)
  if not wait_a or not wait_b then return nil end
  if wait_a.resource ~= wait_b.resource then return nil end
  if not self:cut_allowed(entry_a, entry_b) then return nil, 'cut forbidden by box policy' end

  local ok, resp_a, resp_b = wait_a.resource:try_match(wait_a.request, wait_b.request)
  if not ok then return nil end

  return Cut.new(entry_a, entry_b, resp_a, resp_b), resp_a, resp_b
end

function PartialProof:with_internal_cut(i, j, next_a, next_b, cut)
  local next_entries = copy_entries(self.entries)
  next_entries[i] = {
    task = self.entries[i].task,
    frame = next_a,
    group = self.entries[i].group,
    lane = self.entries[i].lane,
  }
  next_entries[j] = {
    task = self.entries[j].task,
    frame = next_b,
    group = self.entries[j].group,
    lane = self.entries[j].lane,
  }
  local ok = self:fragments_compatible(next_entries)
  if not ok then return nil end
  local cuts = copy_cuts(self.cuts)
  cuts[#cuts + 1] = cut
  return self:with_entries_and_cuts(next_entries, cuts)
end

function PartialProof:with_external_cut(i, external_entries, external_index, next_a, next_b, task, cut)
  local next_entries = copy_entries(self.entries)
  next_entries[i] = {
    task = self.entries[i].task,
    frame = next_a,
    group = self.entries[i].group,
    lane = self.entries[i].lane,
  }

  for k = 1, #external_entries do
    local e = external_entries[k]
    next_entries[#next_entries + 1] = {
      task = e.task,
      frame = (k == external_index) and next_b or e.frame,
      group = e.group,
      lane = e.lane,
    }
  end

  local ok = self:fragments_compatible(next_entries)
  if not ok then return nil end

  local used = shallow_copy(self.used_tasks)
  used[task] = true
  local cuts = copy_cuts(self.cuts)
  cuts[#cuts + 1] = cut
  return self:fork({ entries = next_entries, used_tasks = used, cuts = cuts })
end


local Fuel = {}
Fuel.__index = Fuel

function Fuel.new(limit)
  return setmetatable({ limit = limit, used = 0 }, Fuel)
end

function Fuel:consume()
  if self.limit ~= nil and self.used >= self.limit then
    return false, 'search budget exhausted'
  end
  self.used = self.used + 1
  return true
end

local JudgementContext = {}
JudgementContext.__index = JudgementContext

function JudgementContext.new(runtime, budget_or_fuel)
  local fuel = budget_or_fuel
  if not (type(fuel) == 'table' and fuel.__is_fuel) then
    fuel = Fuel.new(budget_or_fuel)
  end
  fuel.__is_fuel = true
  return setmetatable({
    __is_judgement = true,
    runtime = runtime,
    generation = runtime.generation,
    fuel = fuel,
    stack = {},
    memo = {},
  }, JudgementContext)
end

local function ensure_judgement(runtime, value)
  if type(value) == 'table' and value.__is_judgement then return value end
  return JudgementContext.new(runtime, value)
end

local function require_judgement(method_name, judgement)
  if not (type(judgement) == 'table' and judgement.__is_judgement) then
    error(method_name .. ' requires an explicit JudgementContext', 2)
  end
  return judgement
end

local function forced_key(forced)
  if not forced then return '' end
  local parts = {}
  for site, branch in pairs(forced) do
    parts[#parts + 1] = tostring(site) .. '=' .. tostring(branch)
  end
  table.sort(parts)
  return table.concat(parts, ';')
end

local function committable_search_key(task, forced, generation)
  return tostring(task and task.id or '?') .. '|' .. tostring(generation) .. '|' .. forced_key(forced)
end

local ProofSearch = {}
ProofSearch.__index = ProofSearch

function ProofSearch.new(runtime, initial_proof, budget_or_judgement, accept_world)
  local judgement = ensure_judgement(runtime, budget_or_judgement)
  return setmetatable({
    runtime = runtime,
    initial_proof = initial_proof,
    judgement = judgement,
    accept_world = accept_world,
    generation = judgement.generation,
    status = 'open',
    world = nil,
  }, ProofSearch)
end

function ProofSearch:consume()
  if self.runtime.generation ~= self.generation then
    self.status = 'budget'
    self.reason = 'generation changed'
    return false
  end
  local ok, reason = self.judgement.fuel:consume()
  if not ok then
    self.status = 'budget'
    self.reason = reason or 'search budget exhausted'
    return false
  end
  return true
end

function ProofSearch:result(status, world)
  self.status = status
  self.world = world
  return {
    status = status,
    world = world,
    generation = self.generation,
    used = self.judgement.fuel.used,
    reason = self.reason,
  }
end

function ProofSearch:is_generation_current()
  return self.runtime.generation == self.generation
end

function ProofSearch:search_proof(proof)
  if not self:consume() then return nil, 'budget' end

  -- First reduce any explicit transactional continuation link whose source has
  -- produced a raw value.  User bind/map callbacks are invoked only here, never
  -- by ordinary expression expansion.
  local link_reductions = proof:reduce_ready_continuation_entry()
  if link_reductions then
    for _, p2 in ipairs(link_reductions) do
      local world, status = self:search_proof(p2)
      if world then return world, 'found' end
      if status == 'budget' then return nil, 'budget' end
    end
    return nil, 'absent'
  end

  -- Then reduce any completed tensor/all join link.  The join produces a raw
  -- product value that may feed explicit BindLink/MapLink reductions.
  local reductions = proof:reduce_complete_join_group()
  if reductions then
    for _, p2 in ipairs(reductions) do
      local world, status = self:search_proof(p2)
      if world then return world, 'found' end
      if status == 'budget' then return nil, 'budget' end
    end
    return nil, 'absent'
  end

  -- Then reduce any enabled negative acknowledgement.  Nack frames observe
  -- only prior terminal settlement states, never updates produced by the same
  -- candidate CommitPlan.
  local nack_reductions = proof:reduce_ready_nack_entry(self.runtime)
  if nack_reductions then
    for _, p2 in ipairs(nack_reductions) do
      local world, status = self:search_proof(p2)
      if world then return world, 'found' end
      if status == 'budget' then return nil, 'budget' end
    end
    return nil, 'absent'
  end


  -- Then reduce any external await whose resource is already ready.  Await
  -- frames observe prior external readiness only; retained waits are published
  -- by Runtime:park, not by proof search.
  local await_reductions = proof:reduce_ready_await_entry(self.runtime)
  if await_reductions then
    for _, p2 in ipairs(await_reductions) do
      local world, status = self:search_proof(p2)
      if world then return world, 'found' end
      if status == 'budget' then return nil, 'budget' end
    end
    return nil, 'absent'
  end

  -- Closed proof: all ports are cut and every participant/lane is done.
  if proof:is_closed() then
    local world = proof:world()
    if not world then return nil, 'absent' end

    if self.accept_world then
      local verdict = self.accept_world(world) or { status = 'reject', reason = 'world rejected' }
      if verdict.status == 'accept' then
        return verdict.world or world, 'found'
      elseif verdict.status == 'budget' then
        self.reason = verdict.reason or 'world acceptance budget'
        return nil, 'budget'
      elseif verdict.status == 'reject' then
        -- Valid but unacceptable for this search, for example a fallback world
        -- dominated by a preferred primary proof.  Reject this leaf and let the
        -- surrounding DFS continue looking for another closed candidate.
        return nil, 'absent'
      else
        error('unknown world acceptance status: ' .. tostring(verdict.status))
      end
    end

    return world, 'found'
  end

  -- Try every open port, not just the first.  This matters for TE-style
  -- multi-step protocols such as triple swap: one participant may need a
  -- different participant to progress before its own reply port can close.
  for wi = 1, #proof.entries do
    local waiting_entry = proof.entries[wi]
    local waiting_frame = waiting_entry.frame

    if frame_open_wait(waiting_frame) then
      -- First try cuts with ports already inside this partial proof.
      for j = 1, #proof.entries do
        if j ~= wi then
          local other_entry = proof.entries[j]
          local cut, resp_w, resp_o = proof:try_cut(waiting_entry, other_entry)
          if cut then
            local next_ws = expand_after_cut(waiting_frame, resp_w)
            local next_os = expand_after_cut(other_entry.frame, resp_o)
            for a = 1, #next_ws do
              for b = 1, #next_os do
                local p2 = proof:with_internal_cut(wi, j, next_ws[a], next_os[b], cut)
                if p2 then
                  local world, status = self:search_proof(p2)
                  if world then return world, 'found' end
                  if status == 'budget' then return nil, 'budget' end
                end
              end
            end
          end
        end
      end

      -- Then try cuts by drawing in another parked root.  If the drawn root is
      -- a tensor/all group, all of its lanes enter the proof together.
      for _, task in ipairs(self.runtime.waiting) do
        if task.parked and not proof.used_tasks[task] then
          for _, other_top_frame in ipairs(task.frontier or {}) do
            local external_entries = expand_top_frame(task, other_top_frame)
            for external_index, other_entry in ipairs(external_entries) do
              local cut, resp_w, resp_o = proof:try_cut(waiting_entry, other_entry)
              if cut then
                local next_ws = expand_after_cut(waiting_frame, resp_w)
                local next_os = expand_after_cut(other_entry.frame, resp_o)
                for a = 1, #next_ws do
                  for b = 1, #next_os do
                    local p2 = proof:with_external_cut(wi, external_entries, external_index, next_ws[a], next_os[b], task, cut)
                    if p2 then
                      local world, status = self:search_proof(p2)
                      if world then return world, 'found' end
                      if status == 'budget' then return nil, 'budget' end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  return nil, 'absent'
end

function ProofSearch:run()
  local world, status = run_in_phase('search', function()
    return self:search_proof(self.initial_proof)
  end)
  if world then return self:result('found', world) end
  if status == 'budget' then return self:result('budget') end
  return self:result('absent')
end

local function forced_decisions_for_obligation(obligation)
  local forced = {}

  for i = 1, #(obligation.prefix or {}) do
    local d = obligation.prefix[i]
    local existing = forced[d.site]
    if existing ~= nil and existing ~= d.branch then
      return nil, 'conflicting preference prefix'
    end
    forced[d.site] = d.branch
  end

  local force = obligation.force or 'primary'
  local existing = forced[obligation.site]
  if existing ~= nil and existing ~= force then
    return nil, 'obligation conflicts with its prefix'
  end

  forced[obligation.site] = force
  return forced
end

-- --------------------------------------------------------------------------
-- Module exports.
-- --------------------------------------------------------------------------

M.Op = Op
-- Runtime lives in runtime.lua.  This lazy proxy preserves the old
-- core.Runtime.new() convenience without making etfcore require runtime.lua.
M.Runtime = setmetatable({}, {
  __index = function(_, key)
    return require('runtime').Runtime[key]
  end,
})
M.World = World
M.JudgementContext = JudgementContext
M.Fuel = Fuel
M.ProofSearch = ProofSearch
M.PostProgram = PostProgram
M.PostCommitFrame = PostCommitFrame
M.OccurrenceRef = OccurrenceRef
M.SettlementRef = SettlementRef
M.RootAttempt = RootAttempt
M.EvidenceDelta = EvidenceDelta
M.WorldEvidence = WorldEvidence
M.ResumptionEvidence = ResumptionEvidence
M.CommitPlan = CommitPlan

M.Engine = {
  pack = pack,
  unpack_pack = unpack_pack,
  empty_evidence = empty_evidence,
  run_in_phase = run_in_phase,
  in_search_phase = in_search_phase,
  with_current_task = with_current_task,

  RootAttempt = RootAttempt,
  SettlementCell = SettlementCell,
  ExpansionContext = ExpansionContext,
  PartialProof = PartialProof,
  ProofSearch = ProofSearch,
  JudgementContext = JudgementContext,
  CommitPlan = CommitPlan,

  expand_expr = expand_expr,
  expand_top_frame = expand_top_frame,
  frame_collect_publishable_settlements = frame_collect_publishable_settlements,
  frame_collect_external_waits = frame_collect_external_waits,
  forced_decisions_for_obligation = forced_decisions_for_obligation,
  committable_search_key = committable_search_key,
}

-- Deliberately exposed test/introspection surface for this proof-net specimen.
M._test = {
  pack = pack,
  unpack_pack = unpack_pack,
  EvidenceDelta = EvidenceDelta,
  OccurrenceRef = OccurrenceRef,
  SettlementRef = SettlementRef,
  SettlementCell = SettlementCell,
  WorldEvidence = WorldEvidence,
  ResumptionEvidence = ResumptionEvidence,
  RootAttempt = RootAttempt,
  CommitPlan = CommitPlan,
  empty_evidence = empty_evidence,
  expand_expr = function(...) return expand_expr(...) end,
  expand_top_frame = expand_top_frame,
  ExpansionContext = ExpansionContext,
  PartialProof = PartialProof,
  forced_decisions_for_obligation = forced_decisions_for_obligation,
  committable_search_key = committable_search_key,
  current_task = function() return CURRENT_TASK end,
  phase = function() return PHASE end,
  set_print_event = function(fn) M.print_event = fn end,
  reset_print_event = function() M.print_event = default_print_event end,
}

return M
