-- etfcore.lua
--
-- Core proof-net/Eventful Transactions runtime used by the tests and demos.
--
-- It is not the full library.  It is the smallest useful physical model:
--
--   * an Op algebra
--   * parked roots expand into proof frontiers
--   * PartialProof / Port / Cut are explicit runtime objects
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

local function empty_env()
  return {
    base = nil,
    fragments = {}, fragment_order = {}, consequences = {}, wrappers = {},
    post_program = PostProgram.identity(),
    decisions = {}, decision_path = {}, obligations = {}
  }
end

local function clone_env(env)
  local e = {
    -- Product lanes may carry a base environment.  Cloning preserves the base
    -- pointer and copies only local lane effects.
    base = env and env.base or nil,
    fragments = {},
    fragment_order = list_copy(env and env.fragment_order),
    consequences = list_copy(env and env.consequences),
    wrappers = list_copy(env and env.wrappers),
    post_program = (env and env.post_program) or PostProgram.identity(),
    decisions = {},
    decision_path = list_copy(env and env.decision_path),
    obligations = list_copy(env and env.obligations),
  }
  if env and env.fragments then
    for k, v in pairs(env.fragments) do e.fragments[k] = v end
  end
  if env and env.decisions then
    for k, v in pairs(env.decisions) do e.decisions[k] = v end
  end
  return e
end

local function delta_env(base)
  local e = empty_env()
  e.base = base
  return e
end

local function set_fragment(env, resource, fragment)
  if env.fragments[resource] == nil then
    env.fragment_order[#env.fragment_order + 1] = resource
  end
  env.fragments[resource] = fragment
end

local function merge_fragment_into_env(env, resource, fragment)
  local current = env.fragments[resource]
  if current == nil then
    set_fragment(env, resource, fragment)
    return true
  end
  local ok, merged_or_reason = resource:merge_fragments(current, fragment)
  if not ok then return false, merged_or_reason end
  env.fragments[resource] = merged_or_reason
  return true
end

local function env_local_fragment(env, resource)
  if env and env.fragments and env.fragments[resource] ~= nil then
    return env.fragments[resource]
  end
  return resource:empty_fragment()
end

local function env_base_fragment_view(env, resource)
  local base_view
  if env and env.base then
    base_view = env_base_fragment_view(env.base, resource)
  end

  local local_fragment = env and env.fragments and env.fragments[resource] or nil
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

local function env_fragment_view(env, resource)
  local view, reason = env_base_fragment_view(env, resource)
  if view == nil and reason ~= nil then return nil, reason end
  if view == nil then return resource:empty_fragment() end
  return view
end

local merge_env_effects_into

local function materialize_env(env)
  local out = empty_env()
  local ok, reason = merge_env_effects_into(out, env, true)
  if not ok then error(reason or 'could not materialize environment', 2) end
  return out
end

local function env_decision_path(env)
  local out = {}
  if env and env.base then list_append(out, env_decision_path(env.base)) end
  list_append(out, env and env.decision_path)
  return out
end

local function merge_response(env, response)
  response = response or {}

  if response.fragments then
    for resource, fragment in pairs(response.fragments) do
      local ok, reason = merge_fragment_into_env(env, resource, fragment)
      if not ok then return nil, reason end
    end
  end

  if response.consequences then
    list_append(env.consequences, response.consequences)
  end

  return env
end


merge_env_effects_into = function(dst, env, include_base)
  if not env then return true end

  if include_base and env.base then
    local ok, reason = merge_env_effects_into(dst, env.base, true)
    if not ok then return false, reason end
  end

  for _, resource in ipairs(env.fragment_order or {}) do
    local ok, reason = merge_fragment_into_env(dst, resource, env.fragments[resource])
    if not ok then return false, reason end
  end

  list_append(dst.consequences, env.consequences)
  list_append(dst.wrappers, env.wrappers)
  list_append(dst.obligations, env.obligations)
  list_append(dst.decision_path, env.decision_path)

  for k, v in pairs(env.decisions or {}) do
    local old = dst.decisions[k]
    if old ~= nil and old ~= v then
      return false, 'conflicting decision for ' .. tostring(k)
    end
    dst.decisions[k] = v
  end

  return true
end

local function response_values(response)
  response = response or {}
  if response.values then return response.values end
  if response.value ~= nil then return pack(response.value) end
  return pack()
end

local function append_wrappers_to_env(env, wrappers)
  if not wrappers or #wrappers == 0 then return end
  env.wrappers = env.wrappers or {}
  for i = 1, #wrappers do
    env.wrappers[#env.wrappers + 1] = wrappers[i]
  end
  env.post_program = PostProgram.compose(env.post_program, PostProgram.apply(wrappers))
end

-- Explicit post-commit continuation frame.  World.commit sends this frame back
-- through the suspended Op.perform.  The frame is interpreted inside the
-- resumed fibre coroutine, so wrappers may perform fresh transactions.
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
-- Proof-net physical objects: Box / Port / Cut.
--
-- A Box is a topological region.  Tensor boxes allow sibling cuts; All boxes
-- forbid them.  A Port is an open resource obligation.  A Cut records a
-- successful closure between two ports.
-- --------------------------------------------------------------------------

local next_proof_id = 0
local function fresh_id(prefix)
  next_proof_id = next_proof_id + 1
  return (prefix or 'id') .. '-' .. tostring(next_proof_id)
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

function ExpansionContext.root(root_label, task, forced_decisions)
  return setmetatable({
    root = root_label,
    task = task,
    addr = Address.root(root_label),
    box = nil,
    lane = nil,
    forced_decisions = forced_decisions or {},
  }, ExpansionContext)
end

function ExpansionContext:child(...)
  return setmetatable({
    root = self.root,
    task = self.task,
    addr = self.addr:child(...),
    box = self.box,
    lane = self.lane,
    forced_decisions = self.forced_decisions,
  }, ExpansionContext)
end

function ExpansionContext:in_box(box, lane)
  return setmetatable({
    root = self.root,
    task = self.task,
    addr = self.addr,
    box = box,
    lane = lane,
    forced_decisions = self.forced_decisions,
  }, ExpansionContext)
end

function ExpansionContext:key()
  return self.addr:key()
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

local Port = {}
Port.__index = Port

function Port.new(resource, request, ctx)
  return setmetatable({
    id = fresh_id('port'),
    resource = resource,
    request = request,
    addr = ctx and ctx:key() or nil,
    root = ctx and ctx.root or nil,
    box = ctx and ctx.box or nil,
    lane = ctx and ctx.lane or nil,
  }, Port)
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

function BoundaryLink.new(wrappers, ctx)
  return setmetatable({
    id = fresh_id('boundary'),
    addr = ctx and ctx:key() or nil,
    wrappers = list_copy(wrappers or {}),
  }, BoundaryLink)
end

local JoinLink = {}
JoinLink.__index = JoinLink

function JoinLink.new(kind, wrappers, ctx)
  return setmetatable({
    id = fresh_id('join'),
    addr = ctx and ctx:key() or nil,
    kind = kind,
    wrappers = list_copy(wrappers),
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

function Op.emit(event)
  return new_op('emit', { event = event })
end

local CURRENT_TASK = nil
local PHASE = 'idle'

local function in_search_phase()
  return PHASE == 'search'
end

local function run_in_phase(phase, fn, ...)
  local old = PHASE
  PHASE = phase
  local result = pack(pcall(fn, ...))
  PHASE = old
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
  return new_boundary('wrap', { inner = self, wrappers = { f } })
end

function BoundaryMethods:choice(other)
  return new_boundary('choice', { left = self, right = other })
end

function BoundaryMethods:or_else(fallback)
  return new_boundary('prefer', { primary = self, fallback = fallback })
end

function BoundaryMethods:wrap(f)
  return new_boundary('wrap', { inner = self, wrappers = { f } })
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

local function frame_done(values, env, after_post_program)
  return {
    kind = 'done',
    values = values or pack(),
    env = env,
    after_post_program = after_post_program or PostProgram.identity(),
  }
end

local function frame_wait(resource, request, env, ctx, after_post_program)
  return {
    kind = 'wait',
    resource = resource,
    request = request,
    port = Port.new(resource, request, ctx),
    env = env,
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
  return (frame.env and frame.env.post_program) or PostProgram.identity()
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

local function frame_product(kind, lanes, wrappers, ctx, box, base_env)
  box = box or ((kind == 'tensor') and Box.tensor(ctx) or Box.all(ctx))
  local join = JoinLink.new(kind, wrappers, ctx and ctx:child('join'))

  local lane_programs = {}
  local tainted = false
  for i = 1, #(lanes or {}) do
    lane_programs[i] = frame_post_program(lanes[i])
    if not PostProgram.is_identity(lane_programs[i]) then tainted = true end
  end

  local post_program = PostProgram.product(lane_programs)
  if wrappers and #wrappers > 0 then
    post_program = PostProgram.compose(post_program, PostProgram.apply(wrappers))
    tainted = true
  end

  return {
    kind = 'group',
    group_kind = kind,
    box = box,
    join = join,
    lanes = lanes,
    -- The environment inherited before entering the product belongs to the
    -- product box as a whole, not to each lane.  Lane frames carry only local
    -- deltas, while this base_env is merged once when the box is joined/worlded.
    base_env = materialize_env(base_env or empty_env()),
    wrappers = join.wrappers,
    post_program = post_program,
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

local function frame_open_wait(frame)
  if not frame then return nil end
  if frame.kind == 'wait' then return frame end
  if is_continuation_frame(frame) then return frame_open_wait(frame.source) end
  return nil
end

local function frame_after_cut(frame, response)
  if frame.kind == 'wait' then
    local env = clone_env(frame.env)
    local ok_env, reason = merge_response(env, response)
    if not ok_env then return nil, reason end
    return frame_done(response_values(response), env, frame_after_post_program(frame))
  elseif is_continuation_frame(frame) then
    local source, reason = frame_after_cut(frame.source, response)
    if not source then return nil, reason end
    return frame_with_source(frame, source)
  else
    return nil, 'frame has no open wait frontier'
  end
end

local expand_expr

local function cartesian_frontiers(children, base_env, ctx, box, i, acc, out)
  if i > #children then
    local lanes = {}
    for j = 1, #acc do lanes[j] = acc[j] end
    out[#out + 1] = lanes
    return
  end

  local child_ctx = ctx and ctx:child('lane', i):in_box(box, i) or nil
  local frames = expand_expr(children[i], delta_env(base_env), child_ctx)
  for r = 1, #frames do
    acc[i] = frames[r]
    cartesian_frontiers(children, base_env, ctx, box, i + 1, acc, out)
    acc[i] = nil
  end
end

local function expand_after_cut(frame, response)
  local next_frame, reason = frame_after_cut(frame, response)
  if not next_frame then return {} end
  return { next_frame }
end

local function attach_boundary(frames, boundary)
  local program = PostProgram.apply(boundary.wrappers)
  for _, r in ipairs(frames) do
    if is_continuation_frame(r) then
      -- This is a boundary around a transactional continuation such as
      -- op:and_then(k):wrap(f).  The wrapper belongs after the explicit
      -- BindFrame/MapFrame has reduced, not before its source value.
      frame_compose_after_post(r, program)

    elseif r.kind == 'group' then
      r.wrappers = r.wrappers or {}
      for i = 1, #boundary.wrappers do r.wrappers[#r.wrappers + 1] = boundary.wrappers[i] end
      r.post_program = PostProgram.compose(r.post_program, program)
      r.boundary_tainted = true

    else
      local env = clone_env(r.env)
      append_wrappers_to_env(env, boundary.wrappers)
      r.env = env
    end
  end
  return frames
end


local function fallback_op(fallback)
  if type(fallback) == 'function' then return fallback() end
  return fallback
end

local function env_with_decision(env, site, branch, ctx, creates_obligation)
  -- A decision path entry records both the prefix that led to this site and the
  -- branch chosen at this site.  Fallback absence proofs must replay the prefix
  -- exactly, then flip this site to primary; therefore the obligation prefix is
  -- the path *before* appending the fallback decision.
  local prefix_before_site = env_decision_path(env)

  local e = clone_env(env)
  e.decisions[site] = branch

  local decision_entry = {
    site = site,
    branch = branch,
    prefix = prefix_before_site,
  }
  e.decision_path[#e.decision_path + 1] = decision_entry

  if creates_obligation then
    e.obligations[#e.obligations + 1] = {
      kind = 'prefer_absence',
      root = ctx and ctx.root or nil,
      task = ctx and ctx.task or nil,
      site = site,
      prefix = prefix_before_site,
      force = 'primary',
      fallback_entry = decision_entry,
    }
  end
  return e
end

local function expand_prefer(primary, fallback, env, ctx)
  local prefer_ctx = ctx and ctx:child('prefer') or ExpansionContext.root('prefer')
  local link = PreferLink.new(prefer_ctx)
  local site = link.addr
  local forced = prefer_ctx.forced_decisions and prefer_ctx.forced_decisions[site]

  if forced == 'primary' then
    local e = env_with_decision(env, site, 'primary', prefer_ctx, false)
    return expand_expr(primary, e, prefer_ctx:child('primary'))
  elseif forced == 'fallback' then
    local e = env_with_decision(env, site, 'fallback', prefer_ctx, false)
    return expand_expr(fallback_op(fallback), e, prefer_ctx:child('fallback'))
  end

  local out = expand_expr(primary, env_with_decision(env, site, 'primary', prefer_ctx, false), prefer_ctx:child('primary'))
  list_append(out, expand_expr(fallback_op(fallback), env_with_decision(env, site, 'fallback', prefer_ctx, true), prefer_ctx:child('fallback')))
  return out
end

local function expand_boundary(boundary, env, ctx)
  if boundary.tag == 'wrap' then
    local link = BoundaryLink.new(boundary.wrappers, ctx and ctx:child('boundary'))
    local frames = expand_expr(boundary.inner, clone_env(env), ctx and ctx:child('boundary', 'inner'))
    return attach_boundary(frames, link)
  elseif boundary.tag == 'choice' then
    local out = expand_expr(boundary.left, clone_env(env), ctx and ctx:child('choice', 'left'))
    list_append(out, expand_expr(boundary.right, clone_env(env), ctx and ctx:child('choice', 'right')))
    return out
  elseif boundary.tag == 'prefer' then
    return expand_prefer(boundary.primary, boundary.fallback, clone_env(env), ctx)
  else
    error('unknown boundary tag: ' .. tostring(boundary.tag))
  end
end

expand_expr = function(op, env, ctx)
  env = env or empty_env()
  ctx = ctx or ExpansionContext.root('anonymous')

  if is_boundary(op) then
    return expand_boundary(op, env, ctx)
  end

  if op.tag == 'always' then
    return { frame_done(op.values, clone_env(env)) }

  elseif op.tag == 'never' then
    return {}

  elseif op.tag == 'choice' then
    local out = expand_expr(op.left, clone_env(env), ctx:child('choice', 'left'))
    list_append(out, expand_expr(op.right, clone_env(env), ctx:child('choice', 'right')))
    return out

  elseif op.tag == 'prefer' then
    return expand_prefer(op.primary, op.fallback, clone_env(env), ctx)

  elseif op.tag == 'bind' then
    local link = BindLink.new(op.k, ctx:child('bind'))
    local frames = expand_expr(op.op, clone_env(env), ctx:child('bind', 'source'))
    return attach_continuation_to_frames(frames, link)

  elseif op.tag == 'map' then
    local link = MapLink.new(op.f, ctx:child('map'))
    local frames = expand_expr(op.op, clone_env(env), ctx:child('map', 'source'))
    return attach_continuation_to_frames(frames, link)

  elseif op.tag == 'product' then
    if #op.children == 0 then return { frame_done(pack({}), clone_env(env)) } end
    local product_ctx = ctx:child(op.kind)
    local box = (op.kind == 'tensor') and Box.tensor(product_ctx) or Box.all(product_ctx)
    local base_env = materialize_env(env)
    local combos = {}
    cartesian_frontiers(op.children, base_env, product_ctx, box, 1, {}, combos)
    local out = {}
    for i = 1, #combos do
      out[#out + 1] = frame_product(op.kind, combos[i], nil, product_ctx, box, base_env)
    end
    return out

  elseif op.tag == 'request' then
    return {
      frame_wait(op.resource, op.request, clone_env(env), ctx:child('request'))
    }

  elseif op.tag == 'access' then
    local env2 = clone_env(env)

    -- Reads observe the inherited proof context plus this lane's local delta.
    -- Writes remain local: resources that need the inherited view to answer a
    -- request may provide step_fragment_with_view(base_plus_delta, local_delta,
    -- request), returning the next local delta.  Without a base-aware method,
    -- ordinary resources keep the old local-fragment discipline.
    local local_fragment = env_local_fragment(env2, op.resource)
    local view, view_reason = env_fragment_view(env2, op.resource)
    if view == nil then return {} end

    local ok, response, next_local_fragment
    if op.resource.step_fragment_with_view then
      ok, response, next_local_fragment = op.resource:step_fragment_with_view(view, local_fragment, op.request)
    else
      ok, response, next_local_fragment = op.resource:step_fragment(local_fragment, op.request)
    end
    if not ok then return {} end

    set_fragment(env2, op.resource, next_local_fragment)
    local ok_env = merge_response(env2, response)
    if not ok_env then return {} end

    return { frame_done(response_values(response), env2) }

  elseif op.tag == 'emit' then
    local env2 = clone_env(env)
    env2.consequences[#env2.consequences + 1] = op.event
    return { frame_done(pack(), env2) }

  else
    error('unknown op tag: ' .. tostring(op.tag))
  end
end

-- --------------------------------------------------------------------------
-- World: a closed proof ready to commit.
-- --------------------------------------------------------------------------

local World = {}
World.__index = World

local function merge_entry_envs(entries)
  local env = empty_env()
  local seen_groups = {}

  for _, entry in ipairs(entries or {}) do
    if entry.group then
      if not seen_groups[entry.group] then
        local ok, reason = merge_env_effects_into(env, entry.group.base_env, true)
        if not ok then return nil, reason end
        seen_groups[entry.group] = true
      end

      -- Product lane frames carry local deltas.  Do not include env.base here;
      -- the product box base has already been merged exactly once above.
      local ok, reason = merge_env_effects_into(env, entry.frame.env, false)
      if not ok then return nil, reason end
    else
      local ok, reason = merge_env_effects_into(env, entry.frame.env, true)
      if not ok then return nil, reason end
    end
  end

  return env
end

local function merge_world_fragments(entries)
  local env, reason = merge_entry_envs(entries)
  if not env then return nil, reason end

  for _, resource in ipairs(env.fragment_order) do
    local ok, validate_reason = resource:validate_fragment(env.fragments[resource])
    if not ok then return nil, validate_reason end
  end

  return env.fragments, env.fragment_order, env.consequences, env.obligations, env.decisions, env.decision_path
end

function World.from_entries(entries, cuts)
  for _, entry in ipairs(entries) do
    if entry.frame.kind ~= 'done' then return nil, 'world is not closed' end
  end

  local fragments, fragment_order, consequences_or_reason, obligations, decisions, decision_path = merge_world_fragments(entries)
  if not fragments then return nil, consequences_or_reason end

  return setmetatable({
    entries = entries,
    cuts = cuts or {},
    fragments = fragments,
    fragment_order = fragment_order,
    consequences = consequences_or_reason,
    obligations = obligations or {},
    decisions = decisions or {},
    decision_path = decision_path or {},
  }, World)
end

function World:preference_obligations()
  return self.obligations or {}
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

local function post_program_for_env(env)
  return (env and env.post_program) or PostProgram.identity()
end

local function post_program_for_frame(frame)
  return frame_post_program(frame)
end

function World:commit(runtime)
  if not self:is_committable() then error('world is valid but not committable', 2) end
  local commit = Commit.new()

  -- First collect commit events without installing state.
  for _, resource in ipairs(self.fragment_order) do
    if resource.prepare_commit_fragment then
      resource:prepare_commit_fragment(self.fragments[resource], commit)
    end
  end
  list_append(commit.events, self.consequences)

  -- Then install state.
  for _, resource in ipairs(self.fragment_order) do
    if resource.commit_fragment then
      resource:commit_fragment(self.fragments[resource])
    end
  end

  runtime:bump_generation('commit')

  -- Then interpret commit events.
  for _, event in ipairs(commit.events) do M.print_event(event) end

  -- Finally resume each participating root once.  Tensor/all lane entries
  -- belong to one task; their lane results are assembled into a table of packs.
  local resumed = {}
  local grouped = {}

  for _, entry in ipairs(self.entries) do
    if entry.group then
      local g = grouped[entry.task]
      if not g then
        g = { lane_count = entry.group.lane_count, values = {}, post_program = entry.group.post_program or PostProgram.identity() }
        grouped[entry.task] = g
      end
      g.values[entry.lane] = entry.frame.values
    elseif not resumed[entry.task] then
      runtime:unpark(entry.task)
      entry.task.values = pack(PostCommitFrame.new(entry.frame.values, post_program_for_frame(entry.frame)))
      runtime.runnable[#runtime.runnable + 1] = entry.task
      resumed[entry.task] = true
    end
  end

  for task, g in pairs(grouped) do
    if not resumed[task] then
      local results = {}
      for i = 1, g.lane_count do results[i] = g.values[i] end
      runtime:unpark(task)
      task.values = pack(PostCommitFrame.new(pack(results), g.post_program))
      runtime.runnable[#runtime.runnable + 1] = task
      resumed[task] = true
    end
  end
end

-- --------------------------------------------------------------------------
-- Runtime / proof search.
-- --------------------------------------------------------------------------

local Runtime = {}
Runtime.__index = Runtime

function Runtime.new()
  return setmetatable({
    runnable = {},
    waiting = {},
    waiting_set = {},
    next_task_id = 0,
    generation = 0,
  }, Runtime)
end

function Runtime:bump_generation(_reason)
  self.generation = (self.generation or 0) + 1
  return self.generation
end

function Runtime:spawn(fn, name)
  if in_search_phase() then error('cannot spawn during proof search expansion', 2) end
  self.next_task_id = self.next_task_id + 1
  local task = {
    id = self.next_task_id,
    name = name or ('task-' .. tostring(self.next_task_id)),
    co = coroutine.create(fn),
    values = pack(),
    frontier = nil,
    parked = false,
    attempt_id = 0,
  }
  self.runnable[#self.runnable + 1] = task
  return task
end

function Runtime:park(task, op)
  task.attempt_id = (task.attempt_id or 0) + 1
  self:bump_generation('park')
  local root_label = 'task-' .. tostring(task.id) .. '/attempt-' .. tostring(task.attempt_id)
  task.op = op
  task.root_label = root_label
  task.frontier = run_in_phase('search', function()
    return expand_expr(op, empty_env(), ExpansionContext.root(root_label, task))
  end)
  task.parked = true
  if not self.waiting_set[task] then
    self.waiting[#self.waiting + 1] = task
    self.waiting_set[task] = true
  end
end

function Runtime:unpark(task)
  if not self.waiting_set[task] then return end
  self:bump_generation('unpark')
  self.waiting_set[task] = nil
  task.parked = false
  task.frontier = nil
  for i = #self.waiting, 1, -1 do
    if self.waiting[i] == task then table.remove(self.waiting, i); return end
  end
end

function Runtime:resume_task(task)
  local previous_task = CURRENT_TASK
  CURRENT_TASK = task
  local ok, yielded = coroutine.resume(task.co, unpack_pack(task.values))
  CURRENT_TASK = previous_task
  task.values = pack()

  if not ok then error(task.name .. ': ' .. tostring(yielded)) end
  if coroutine.status(task.co) == 'dead' then return end

  if type(yielded) ~= 'table' or not yielded.tag then
    error(task.name .. ': yielded non-operation')
  end

  self:park(task, yielded)
end

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
      box = group_frame.box,
      kind = group_frame.group_kind,
      lane_count = #group_frame.lanes,
      continuation_chain = continuation_chain or {},
      wrappers = list_copy(group_frame.wrappers),
      post_program = frame_post_program(group_frame),
      after_post_program = PostProgram.identity(),
      boundary_tainted = frame_boundary_tainted(group_frame),
      base_env = materialize_env(group_frame.base_env or empty_env()),
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

local function callback_returned_op(where, value)
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
      local next_frames = expand_expr(next_op, source.env, link.ctx or ExpansionContext.root('bind-cont'))
      for i = 1, #next_frames do
        local nf = next_frames[i]
        frame_compose_after_post(nf, frame_after_post_program(frame))
        replacement_frames[#replacement_frames + 1] = nf
      end

    elseif frame.kind == 'map' then
      replacement_frames[1] = frame_done(pack(link.f(unpack_pack(source.values))), source.env, frame_after_post_program(frame))

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

  local env, reason = merge_entry_envs(merge_inputs)
  if not env then return nil, reason end

  local joined = frame_done(pack(results), env, group.after_post_program)
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
  local env, reason = merge_entry_envs(entries or self.entries)
  if not env then return false, reason end
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

function Runtime:search_closed_world(proof, budget)
  local result = ProofSearch.new(self, proof, budget):run()
  if result.status == 'found' then return result.world, result end
  return nil, result
end


function Runtime:initial_proofs_for_task(task, forced_decisions)
  local root_label = task.root_label or ('task-' .. tostring(task.id) .. '/attempt-' .. tostring(task.attempt_id or 0))
  local frames
  if forced_decisions then
    frames = expand_expr(task.op, empty_env(), ExpansionContext.root(root_label, task, forced_decisions))
  else
    frames = task.frontier or {}
  end

  local proofs = {}
  for _, frame in ipairs(frames) do
    local used = { [task] = true }
    local proof = PartialProof.new(expand_top_frame(task, frame), used, {})
    if proof:fragments_compatible() then proofs[#proofs + 1] = proof end
  end
  return proofs
end

function Runtime:search_task(task, forced_decisions, budget)
  local proofs = self:initial_proofs_for_task(task, forced_decisions)
  local saw_budget = nil
  for _, proof in ipairs(proofs) do
    local result = ProofSearch.new(self, proof, budget):run()
    if result.status == 'found' then return result end
    if result.status == 'budget' then saw_budget = result end
  end
  return saw_budget or { status = 'absent', generation = self.generation }
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

function Runtime:prove_obligation(obligation, judgement)
  judgement = require_judgement('Runtime:prove_obligation', judgement)

  if not obligation.task then
    return { status = 'discharged', reason = 'no task for obligation', generation = judgement.generation }
  end

  local forced, reason = forced_decisions_for_obligation(obligation)
  if not forced then
    return { status = 'discharged', reason = reason, generation = judgement.generation }
  end

  local result = self:search_committable_task(obligation.task, forced, judgement)
  if result.status == 'found' then
    return {
      status = 'dominated',
      world = result.world,
      obligation = obligation,
      generation = judgement.generation,
    }
  elseif result.status == 'budget' then
    return {
      status = 'budget',
      obligation = obligation,
      reason = result.reason,
      generation = judgement.generation,
    }
  elseif result.status == 'absent' then
    return {
      status = 'discharged',
      obligation = obligation,
      reason = result.reason,
      generation = judgement.generation,
    }
  end

  return {
    status = result.status or 'unknown',
    obligation = obligation,
    reason = result.reason,
    generation = judgement.generation,
  }
end

function Runtime:prove_committable(world, judgement)
  judgement = require_judgement('Runtime:prove_committable', judgement)

  local obligations = world:preference_obligations()
  for i = 1, #obligations do
    local result = self:prove_obligation(obligations[i], judgement)
    if result.status == 'dominated' then
      return { status = 'dominated', world = result.world, obligation = obligations[i] }
    elseif result.status == 'budget' then
      return { status = 'budget', obligation = obligations[i], reason = result.reason }
    elseif result.status ~= 'discharged' then
      return { status = result.status or 'unknown', obligation = obligations[i], reason = result.reason }
    end
  end
  world.preference_obligations_discharged = true
  return { status = 'committable', world = world }
end

function Runtime:_search_committable_task_uncached(task, forced_decisions, judgement)
  local saw_dominated = false

  local function accept_world(world)
    local proof = self:prove_committable(world, judgement)
    if proof.status == 'committable' then
      return { status = 'accept', world = world }
    elseif proof.status == 'dominated' then
      saw_dominated = true
      return { status = 'reject', reason = 'dominated by preferred committable world', dominated_by = proof.world }
    elseif proof.status == 'budget' then
      return { status = 'budget', reason = proof.reason or 'preference obligation proof budget' }
    else
      return { status = 'reject', reason = proof.status or 'not committable' }
    end
  end

  local proofs = self:initial_proofs_for_task(task, forced_decisions)
  for _, proof in ipairs(proofs) do
    local result = ProofSearch.new(self, proof, judgement, accept_world):run()
    if result.status == 'found' then return result end
    if result.status == 'budget' then return result end
  end

  return {
    status = 'absent',
    generation = judgement.generation,
    used = judgement.fuel.used,
    reason = saw_dominated and 'all candidates absent or dominated' or 'absent',
  }
end

function Runtime:search_committable_task(task, forced_decisions, judgement)
  judgement = require_judgement('Runtime:search_committable_task', judgement)
  if forced_decisions ~= nil and type(forced_decisions) ~= 'table' then
    error('Runtime:search_committable_task forced_decisions must be a table or nil', 2)
  end

  if self.generation ~= judgement.generation then
    return {
      status = 'budget',
      generation = judgement.generation,
      used = judgement.fuel.used,
      reason = 'generation changed',
    }
  end

  local key = committable_search_key(task, forced_decisions, judgement.generation)
  if judgement.stack[key] then
    return {
      status = 'budget',
      generation = judgement.generation,
      used = judgement.fuel.used,
      reason = 'cyclic committability judgement',
    }
  end

  if judgement.memo[key] then return judgement.memo[key] end

  judgement.stack[key] = true
  local result = self:_search_committable_task_uncached(task, forced_decisions, judgement)
  judgement.stack[key] = nil

  judgement.memo[key] = result
  return result
end

function Runtime:try_commit_one()
  local judgement = JudgementContext.new(self)
  for _, task in ipairs(self.waiting) do
    if task.parked then
      local result = self:search_committable_task(task, nil, judgement)
      if result.status == 'found' then
        result.world:commit(self)
        return 'committed'
      elseif result.status == 'budget' then
        return 'budget', result
      end
    end
  end

  return 'blocked'
end

function Runtime:run()
  while true do
    while #self.runnable > 0 do
      local task = table.remove(self.runnable, 1)
      self:resume_task(task)
    end

    if #self.waiting == 0 then return end

    local status = self:try_commit_one()
    if status == 'budget' then
      error('budget: proof search incomplete')
    elseif status ~= 'committed' then
      if not self.quiet_deadlock then
        io.stderr:write('deadlock: no closed proof can be constructed\n')
        for _, task in ipairs(self.waiting) do
          io.stderr:write('  waiting: ' .. tostring(task.name) .. '\n')
        end
      end
      error('deadlock')
    end
  end
end

-- --------------------------------------------------------------------------
-- Module exports.
-- --------------------------------------------------------------------------

M.Op = Op
M.Runtime = Runtime
M.World = World
M.JudgementContext = JudgementContext
M.Fuel = Fuel
M.ProofSearch = ProofSearch
M.PostProgram = PostProgram
M.PostCommitFrame = PostCommitFrame

-- Deliberately exposed test/introspection surface for this proof-net specimen.
M._test = {
  pack = pack,
  unpack_pack = unpack_pack,
  empty_env = empty_env,
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
