-- etf_demo.lua
--
-- A deliberately tiny, single-file, Lua 5.1/texlua runnable sketch of an
-- Eventful Transactions / proof-net flavoured runtime.
--
-- It is not the full library.  It is the smallest useful physical model:
--
--   * an Op algebra
--   * parked roots expand into proof frontiers
--   * PartialProof / Port / Cut are explicit runtime objects
--   * wait frames are open ports
--   * channel rendezvous is a cut between dual ports
--   * tensor/all are boxes with internal cut policy
--   * tensor/all joins and wrap boundaries are explicit links
--   * resources contribute mergeable fragments
--   * a closed candidate becomes a World
--   * World commit validates fragments, checks committability, emits commit events, installs state,
--     then resumes participating fibres
--
-- Demos at the bottom:
--   1. triple swap over synchronous channels
--   2. ledger transfer + close as one atomic transaction with commit events

local unpack_ = rawget(table, 'unpack') or _G.unpack

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

function JoinLink.new(kind, cont, wrappers, ctx)
  return setmetatable({
    id = fresh_id('join'),
    addr = ctx and ctx:key() or nil,
    kind = kind,
    cont = cont,
    wrappers = list_copy(wrappers),
  }, JoinLink)
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
  return self:and_then(function(...)
    return Op.always(f(...))
  end)
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
-- done frame: a closed proof for one participant/lane.
-- wait frame: an open resource port; must be cut with a compatible port.
-- --------------------------------------------------------------------------

local function frame_done(values, env)
  return { kind = 'done', values = values or pack(), env = env }
end

local function frame_wait(resource, request, env, cont, ctx)
  return {
    kind = 'wait',
    resource = resource,
    request = request,
    port = Port.new(resource, request, ctx),
    env = env,
    cont = cont,
    cont_ctx = ctx and ctx:child('cont') or nil,
    addr = ctx and ctx:key() or nil,
  }
end

local function frame_post_program(frame)
  if not frame then return PostProgram.identity() end
  if frame.kind == 'group' then return frame.post_program or PostProgram.identity() end
  return (frame.env and frame.env.post_program) or PostProgram.identity()
end

local function frame_boundary_tainted(frame)
  return not PostProgram.is_identity(frame_post_program(frame))
end

local function frame_product(kind, lanes, cont, wrappers, ctx, box, base_env)
  box = box or ((kind == 'tensor') and Box.tensor(ctx) or Box.all(ctx))
  local join = JoinLink.new(kind, cont, wrappers, ctx and ctx:child('join'))

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
    cont = join.cont,
    cont_ctx = ctx and ctx:child('join', 'cont') or nil,
    wrappers = join.wrappers,
    post_program = post_program,
    boundary_tainted = tainted,
    addr = ctx and ctx:key() or nil,
    ctx = ctx,
  }
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
  local env = clone_env(frame.env)
  local ok_env, reason = merge_response(env, response)
  if not ok_env then return {} end
  local next_op = frame.cont(response_values(response))
  return expand_expr(next_op, env, frame.cont_ctx)
end

local function attach_boundary(frames, boundary)
  local program = PostProgram.apply(boundary.wrappers)
  for _, r in ipairs(frames) do
    if r.kind == 'group' then
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
    local out = {}
    local frames = expand_expr(op.op, clone_env(env), ctx:child('bind', 'left'))
    for i = 1, #frames do
      local r = frames[i]
      if r.kind == 'done' then
        local next_op = op.k(unpack_pack(r.values))
        list_append(out, expand_expr(next_op, r.env, ctx:child('bind', 'cont')))
      elseif r.kind == 'wait' then
        local old = r
        out[#out + 1] = frame_wait(old.resource, old.request, old.env, function(values)
          return old.cont(values):and_then(op.k)
        end, ctx:child('bind', 'cont'))
      elseif r.kind == 'group' then
        if r.boundary_tainted then
          error('cannot attach transactional continuation after product containing boundary lane', 2)
        end
        local old = r
        out[#out + 1] = frame_product(old.group_kind, old.lanes, function(results)
          local base
          if old.cont then
            base = old.cont(results)
          else
            base = Op.always(results)
          end
          return base:and_then(op.k)
        end, old.wrappers, old.cont_ctx or ctx:child('bind', 'cont'), old.box, old.base_env)
      end
    end
    return out

  elseif op.tag == 'product' then
    if #op.children == 0 then return { frame_done(pack({}), clone_env(env)) } end
    local product_ctx = ctx:child(op.kind)
    local box = (op.kind == 'tensor') and Box.tensor(product_ctx) or Box.all(product_ctx)
    local base_env = materialize_env(env)
    local combos = {}
    cartesian_frontiers(op.children, base_env, product_ctx, box, 1, {}, combos)
    local out = {}
    for i = 1, #combos do
      out[#out + 1] = frame_product(op.kind, combos[i], nil, nil, product_ctx, box, base_env)
    end
    return out

  elseif op.tag == 'request' then
    return {
      frame_wait(op.resource, op.request, clone_env(env), function(values)
        return Op.always(unpack_pack(values))
      end, ctx:child('request'))
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
-- Channel resource: put/get ports cut against each other.
-- --------------------------------------------------------------------------

local Channel = {}
Channel.__index = Channel

function Channel.new(name)
  return setmetatable({ name = name or 'channel' }, Channel)
end

function Channel:put(value)
  return Op.request(self, { tag = 'put', value = value })
end

function Channel:get()
  return Op.request(self, { tag = 'get' })
end

function Channel:empty_fragment()
  return { matches = {} }
end

function Channel:merge_fragments(a, b)
  local out = { matches = {} }
  for k, v in pairs(a.matches or {}) do out.matches[k] = v end
  for k, v in pairs(b.matches or {}) do
    local old = out.matches[k]
    if old and old ~= v then return false, 'channel match conflict' end
    out.matches[k] = v
  end
  return true, out
end

function Channel:validate_fragment(_) return true end
function Channel:prepare_commit_fragment(_, _) end
function Channel:commit_fragment(_) end

function Channel:try_match(a, b)
  if a.tag == 'put' and b.tag == 'get' then
    local token = {}
    local fragment = { matches = { [token] = a.value } }
    return true,
      { value = true, fragments = { [self] = fragment } },
      { value = a.value, fragments = { [self] = fragment } }

  elseif a.tag == 'get' and b.tag == 'put' then
    local token = {}
    local fragment = { matches = { [token] = b.value } }
    return true,
      { value = b.value, fragments = { [self] = fragment } },
      { value = true, fragments = { [self] = fragment } }
  end

  return false
end

-- --------------------------------------------------------------------------
-- Ledger resource: native fragments + commit events.
--
-- State: item -> owner, and closed owners.
-- Fragment: planned moves and closes.  Transfer+close-source is legal if the
-- close leaves the owner with no remaining items after planned moves.
-- --------------------------------------------------------------------------

local Ledger = {}
Ledger.__index = Ledger

function Ledger.new(owners)
  return setmetatable({ owners = shallow_copy(owners or {}), closed = {} }, Ledger)
end

function Ledger:move(item, from_owner, to_owner)
  return Op.access(self, { tag = 'move', item = item, from = from_owner, to = to_owner })
end

function Ledger:close(owner, reason)
  return Op.access(self, { tag = 'close', owner = owner, reason = reason or 'closed' })
end

function Ledger:empty_fragment()
  return { moves = {}, move_order = {}, closes = {}, close_order = {} }
end

local function ledger_clone_fragment(f)
  local g = { moves = {}, move_order = list_copy(f.move_order), closes = {}, close_order = list_copy(f.close_order) }
  for k, v in pairs(f.moves or {}) do g.moves[k] = { item = v.item, from = v.from, to = v.to } end
  for k, v in pairs(f.closes or {}) do g.closes[k] = { owner = v.owner, reason = v.reason } end
  return g
end

function Ledger:step_fragment(fragment, request)
  local f = ledger_clone_fragment(fragment)

  if request.tag == 'move' then
    local old = f.moves[request.item]
    local move = { item = request.item, from = request.from, to = request.to }
    if old and (old.from ~= move.from or old.to ~= move.to) then
      return false, 'conflicting move for ' .. tostring(request.item)
    end
    if not old then f.move_order[#f.move_order + 1] = request.item end
    f.moves[request.item] = move
    return true, { value = true }, f

  elseif request.tag == 'close' then
    local old = f.closes[request.owner]
    local close = { owner = request.owner, reason = request.reason }
    if old and old.reason ~= close.reason then
      return false, 'conflicting close for ' .. tostring(request.owner)
    end
    if not old then f.close_order[#f.close_order + 1] = request.owner end
    f.closes[request.owner] = close
    return true, { value = true }, f
  end

  return false, 'unknown ledger request'
end

function Ledger:step_fragment_with_view(view_fragment, local_fragment, request)
  -- Ledger requests currently do not return values that depend on pending state,
  -- so the local delta can be stepped directly.  This method documents the
  -- base-aware resource protocol: view_fragment is available for reads, while
  -- the returned fragment must be the next local contribution only.
  return self:step_fragment(local_fragment, request)
end

function Ledger:merge_fragments(a, b)
  local out = ledger_clone_fragment(a)

  for _, item in ipairs(b.move_order or {}) do
    local mv = b.moves[item]
    local old = out.moves[item]
    if old and (old.from ~= mv.from or old.to ~= mv.to) then
      return false, 'conflicting move for ' .. tostring(item)
    end
    if not old then out.move_order[#out.move_order + 1] = item end
    out.moves[item] = { item = mv.item, from = mv.from, to = mv.to }
  end

  for _, owner in ipairs(b.close_order or {}) do
    local cl = b.closes[owner]
    local old = out.closes[owner]
    if old and old.reason ~= cl.reason then
      return false, 'conflicting close for ' .. tostring(owner)
    end
    if not old then out.close_order[#out.close_order + 1] = owner end
    out.closes[owner] = { owner = cl.owner, reason = cl.reason }
  end

  return true, out
end

function Ledger:validate_fragment(fragment)
  -- Validate moves against committed state and planned closes.
  local planned_owner = shallow_copy(self.owners)

  for _, item in ipairs(fragment.move_order or {}) do
    local mv = fragment.moves[item]
    if self.closed[mv.from] then return false, 'source owner already closed: ' .. tostring(mv.from) end
    if self.closed[mv.to] then return false, 'target owner already closed: ' .. tostring(mv.to) end
    if planned_owner[item] ~= mv.from then
      return false, 'owner mismatch for ' .. tostring(item) .. ': expected ' .. tostring(mv.from) .. ', have ' .. tostring(planned_owner[item])
    end
    planned_owner[item] = mv.to
  end

  for _, owner in ipairs(fragment.close_order or {}) do
    if self.closed[owner] then return false, 'already closed: ' .. tostring(owner) end
    for item, item_owner in pairs(planned_owner) do
      if item_owner == owner then
        return false, 'cannot close non-empty owner ' .. tostring(owner) .. '; still owns ' .. tostring(item)
      end
    end
  end

  return true
end

function Ledger:prepare_commit_fragment(fragment, commit)
  for _, item in ipairs(fragment.move_order or {}) do
    local mv = fragment.moves[item]
    commit:emit({ tag = 'ledger.move', item = mv.item, from = mv.from, to = mv.to })
  end
  for _, owner in ipairs(fragment.close_order or {}) do
    local cl = fragment.closes[owner]
    commit:emit({ tag = 'ledger.close', owner = cl.owner, reason = cl.reason })
  end
end

function Ledger:commit_fragment(fragment)
  for _, item in ipairs(fragment.move_order or {}) do
    local mv = fragment.moves[item]
    self.owners[item] = mv.to
  end
  for _, owner in ipairs(fragment.close_order or {}) do
    local cl = fragment.closes[owner]
    self.closed[owner] = cl.reason
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

local function print_event(event)
  if event.tag == 'ledger.move' then
    print(string.format('[commit event] move %s: %s -> %s', tostring(event.item), tostring(event.from), tostring(event.to)))
  elseif event.tag == 'ledger.close' then
    print(string.format('[commit event] close %s reason=%s', tostring(event.owner), tostring(event.reason)))
  else
    print('[commit event] ' .. tostring(event.tag))
  end
end

local function post_program_for_env(env)
  return (env and env.post_program) or PostProgram.identity()
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
  for _, event in ipairs(commit.events) do print_event(event) end

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
      entry.task.values = pack(PostCommitFrame.new(entry.frame.values, post_program_for_env(entry.frame.env)))
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
  if frame.kind == 'group' then
    local entries = {}
    local group = {
      task = task,
      box = frame.box,
      kind = frame.group_kind,
      lane_count = #frame.lanes,
      cont = frame.cont,
      cont_ctx = frame.cont_ctx,
      wrappers = list_copy(frame.wrappers),
      post_program = frame.post_program or PostProgram.identity(),
      boundary_tainted = frame.boundary_tainted == true,
      base_env = materialize_env(frame.base_env or empty_env()),
    }
    for i = 1, #frame.lanes do
      entries[i] = { task = task, frame = frame.lanes[i], group = group, lane = i }
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

function PartialProof:is_closed()
  for i = 1, #self.entries do
    local e = self.entries[i]
    if e.frame.kind ~= 'done' then return false end
    if e.group and e.group.cont then return false end
  end
  return true
end

function PartialProof:world()
  if not self:is_closed() then return nil, 'proof has open ports' end
  return World.from_proof(self)
end


function PartialProof:find_complete_join_group()
  local seen = {}
  for _, entry in ipairs(self.entries) do
    local group = entry.group
    if group and group.cont and not seen[group] then
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

  local next_op = group.cont(results)
  local next_frames = expand_expr(next_op, env, group.cont_ctx or ExpansionContext.root('join-cont'))
  local out = {}

  for _, next_top in ipairs(next_frames) do
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
    if p2:fragments_compatible() then
      out[#out + 1] = p2
    end
  end

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
  if entry_a.frame.kind ~= 'wait' or entry_b.frame.kind ~= 'wait' then return nil end
  if entry_a.frame.resource ~= entry_b.frame.resource then return nil end
  if not self:cut_allowed(entry_a, entry_b) then return nil, 'cut forbidden by box policy' end

  local ok, resp_a, resp_b = entry_a.frame.resource:try_match(entry_a.frame.request, entry_b.frame.request)
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


local ProofSearch = {}
ProofSearch.__index = ProofSearch

function ProofSearch.new(runtime, initial_proof, budget, accept_world)
  return setmetatable({
    runtime = runtime,
    initial_proof = initial_proof,
    budget = budget,
    accept_world = accept_world,
    used = 0,
    generation = runtime.generation,
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
  if self.budget ~= nil then
    if self.used >= self.budget then
      self.status = 'budget'
      self.reason = 'search budget exhausted'
      return false
    end
    self.used = self.used + 1
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
    used = self.used,
    reason = self.reason,
  }
end

function ProofSearch:is_generation_current()
  return self.runtime.generation == self.generation
end

function ProofSearch:search_proof(proof)
  if not self:consume() then return nil, 'budget' end

  -- First reduce any completed tensor/all join link.  The join produces a
  -- normal continuation frame, so product results can feed later transactional
  -- requests before the world commits.
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

    if waiting_frame.kind == 'wait' then
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

function Runtime:prove_obligation(obligation, budget)
  if not obligation.task then
    return { status = 'absent', reason = 'no task for obligation', generation = self.generation }
  end

  local forced, reason = forced_decisions_for_obligation(obligation)
  if not forced then
    return { status = 'absent', reason = reason, generation = self.generation }
  end

  return self:search_task(obligation.task, forced, budget)
end

function Runtime:prove_committable(world, budget)
  local obligations = world:preference_obligations()
  for i = 1, #obligations do
    local result = self:prove_obligation(obligations[i], budget)
    if result.status == 'found' then
      return { status = 'dominated', world = result.world, obligation = obligations[i] }
    elseif result.status == 'budget' then
      return { status = 'budget', obligation = obligations[i], reason = result.reason }
    elseif result.status ~= 'absent' then
      return { status = result.status or 'unknown', obligation = obligations[i] }
    end
  end
  world.preference_obligations_discharged = true
  return { status = 'committable', world = world }
end

function Runtime:search_committable_task(task, budget)
  local saw_dominated = false

  local function accept_world(world)
    local proof = self:prove_committable(world, budget)
    if proof.status == 'committable' then
      return { status = 'accept', world = world }
    elseif proof.status == 'dominated' then
      saw_dominated = true
      return { status = 'reject', reason = 'dominated by preferred proof', dominated_by = proof.world }
    elseif proof.status == 'budget' then
      return { status = 'budget', reason = proof.reason or 'preference obligation proof budget' }
    else
      return { status = 'reject', reason = proof.status or 'not committable' }
    end
  end

  local proofs = self:initial_proofs_for_task(task)
  for _, proof in ipairs(proofs) do
    local result = ProofSearch.new(self, proof, budget, accept_world):run()
    if result.status == 'found' then return result end
    if result.status == 'budget' then return result end
  end

  return {
    status = 'absent',
    generation = self.generation,
    reason = saw_dominated and 'all candidates absent or dominated' or 'absent',
  }
end

function Runtime:try_commit_one()
  for _, task in ipairs(self.waiting) do
    if task.parked then
      local result = self:search_committable_task(task)
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
-- Demo 1: Triple swap
-- --------------------------------------------------------------------------

local function pair(a, b)
  return { a, b }
end

local function triple_swap_op(ch, x)
  local reply = Channel.new('reply-' .. tostring(x))

  local client = ch:put({ x = x, reply = reply }):and_then(function()
    return reply:get()
  end)

  local leader = ch:get():and_then(function(m2)
    return ch:get():and_then(function(m3)
      return m2.reply:put(pair(m3.x, x)):and_then(function()
        return m3.reply:put(pair(x, m2.x)):and_then(function()
          return Op.always(pair(m2.x, m3.x))
        end)
      end)
    end)
  end)

  return Op.choice(client, leader)
end

local function demo_triple_swap()
  print('--- demo: triple swap ---')
  local rt = Runtime.new()
  local ch = Channel.new('triple')
  local results = {}

  for i = 1, 3 do
    local x = 10 + i
    rt:spawn(function()
      local got = Op.perform(triple_swap_op(ch, x))
      results[x] = got
      print(string.format('swapper %d got {%d,%d}', x, got[1], got[2]))
    end, 'swapper-' .. tostring(x))
  end

  rt:run()

  local checksum = 0
  for x, got in pairs(results) do checksum = checksum + x + got[1] + got[2] end
  print('triple swap checksum:', checksum)
  print()
end

-- --------------------------------------------------------------------------
-- Demo 2: Ledger transfer + close as one transaction.
-- --------------------------------------------------------------------------

local function demo_ledger()
  print('--- demo: ledger transfer + close commit event ---')
  local rt = Runtime.new()
  local ledger = Ledger.new({ ticket = 'extent:A' })

  rt:spawn(function()
    local ok = Op.perform(
      ledger:move('ticket', 'extent:A', 'extent:B'):and_then(function()
        return ledger:close('extent:A', 'moved-out'):and_then(function()
          return Op.emit({ tag = 'user.note', message = 'ledger tx body complete' }):and_then(function()
            return Op.always('transaction-result')
          end)
        end)
      end)
    )
    print('ledger transaction returned:', ok)
  end, 'ledger-tx')

  rt:run()

  print('ledger owner(ticket):', ledger.owners.ticket)
  print('ledger closed(extent:A):', ledger.closed['extent:A'])
  print()
end

-- --------------------------------------------------------------------------
-- Tiny correctness tests for the new physical objects.
-- --------------------------------------------------------------------------

local function assert_eq(a, b, message)
  if a ~= b then error((message or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end


local function test_derivation_addresses_are_stable()
  local ch = Channel.new('addr-stable')
  local operation = Op.tensor({ ch:put('x'), ch:get() })

  local frames1 = expand_expr(operation, empty_env(), ExpansionContext.root('addr-root'))
  local frames2 = expand_expr(operation, empty_env(), ExpansionContext.root('addr-root'))

  assert_eq(frames1[1].lanes[1].addr, frames2[1].lanes[1].addr, 'lane 1 address should be replay-stable')
  assert_eq(frames1[1].lanes[2].addr, frames2[1].lanes[2].addr, 'lane 2 address should be replay-stable')
  assert(frames1[1].lanes[1].addr ~= frames1[1].lanes[2].addr, 'distinct tensor lanes should have distinct addresses')
  assert(frames1[1].box.addr and frames1[1].box.addr:match('addr%-root'), 'box should carry derivation address')
  assert(frames1[1].lanes[1].port.box == frames1[1].box, 'lane 1 port should be physically inside product box')
  assert(frames1[1].lanes[2].port.box == frames1[1].box, 'lane 2 port should be physically inside product box')
end

local function drain_runnable(rt)
  while #rt.runnable > 0 do
    local task = table.remove(rt.runnable, 1)
    rt:resume_task(task)
  end
end

local function first_proof_for(task)
  local frame = assert(task.frontier and task.frontier[1], 'task has no frontier')
  local used = { [task] = true }
  return PartialProof.new(expand_top_frame(task, frame), used, {})
end

local function test_proof_search_is_tri_valued_and_budgeted()
  local rt = Runtime.new()
  local ch = Channel.new('proof-search-budget')

  local receiver = rt:spawn(function()
    Op.perform(ch:get())
  end, 'budget-receiver')
  drain_runnable(rt)

  local proof = first_proof_for(receiver)
  local budgeted = ProofSearch.new(rt, proof, 0):run()
  assert_eq(budgeted.status, 'budget', 'zero-budget proof search should report budget')

  local absent = ProofSearch.new(rt, proof):run()
  assert_eq(absent.status, 'absent', 'unmatched get should prove absence in closed current generation')
  assert_eq(absent.generation, rt.generation, 'absence proof should record current generation')
end

local function test_absence_is_generation_stable_not_timeless()
  local rt = Runtime.new()
  local ch = Channel.new('proof-search-generation')

  local receiver = rt:spawn(function()
    Op.perform(ch:get())
  end, 'generation-receiver')
  drain_runnable(rt)

  local absent = ProofSearch.new(rt, first_proof_for(receiver)):run()
  assert_eq(absent.status, 'absent', 'initial receiver-only search should prove absence')
  local absent_generation = absent.generation

  rt:spawn(function()
    Op.perform(ch:put('x'))
  end, 'generation-sender')
  drain_runnable(rt)

  assert(absent_generation ~= rt.generation, 'old absence proof should be invalid after generation change')

  local found = ProofSearch.new(rt, first_proof_for(receiver)):run()
  assert_eq(found.status, 'found', 'new sender should make a closed proof available')
  assert(found.world:is_committable(), 'worlds without preference obligations should be committable')
end

local function test_tensor_self_rendezvous_succeeds()
  local rt = Runtime.new()
  local ch = Channel.new('tensor-self')
  local got

  rt:spawn(function()
    got = Op.perform(Op.tensor({ ch:put('x'), ch:get() }))
  end, 'tensor-root')

  rt:run()

  assert(type(got) == 'table', 'tensor should return lane result table')
  assert_eq(got[1][1], true, 'put lane result')
  assert_eq(got[2][1], 'x', 'get lane result')
end

local function test_all_self_rendezvous_fails()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local ch = Channel.new('all-self')

  rt:spawn(function()
    Op.perform(Op.all({ ch:put('x'), ch:get() }))
  end, 'all-root')

  local ok, err = pcall(function() rt:run() end)
  assert(ok == false, 'all self-rendezvous should deadlock')
  assert(tostring(err):match('deadlock'), 'expected deadlock error, got ' .. tostring(err))
end


local function test_tensor_join_feeds_transactional_continuation()
  local rt = Runtime.new()
  local internal = Channel.new('tensor-join-internal')
  local out = Channel.new('tensor-join-out')
  local received

  rt:spawn(function()
    local ok = Op.perform(
      Op.tensor({ internal:put('x'), internal:get() }):and_then(function(results)
        return out:put(results[2][1])
      end)
    )
    assert(ok == true, 'tensor continuation put should return true')
  end, 'tensor-join-root')

  rt:spawn(function()
    received = Op.perform(out:get())
  end, 'tensor-join-receiver')

  rt:run()
  assert_eq(received, 'x', 'tensor join should feed continuation inside same transaction')
end

local function test_all_join_feeds_transactional_continuation_after_external_cuts()
  local rt = Runtime.new()
  local a = Channel.new('all-join-a')
  local b = Channel.new('all-join-b')
  local out = Channel.new('all-join-out')
  local received

  rt:spawn(function()
    local ok = Op.perform(
      Op.all({ a:get(), b:get() }):and_then(function(results)
        return out:put(results[1][1] .. results[2][1])
      end)
    )
    assert(ok == true, 'all continuation put should return true')
  end, 'all-join-root')

  rt:spawn(function() Op.perform(a:put('A')) end, 'all-sender-a')
  rt:spawn(function() Op.perform(b:put('B')) end, 'all-sender-b')
  rt:spawn(function() received = Op.perform(out:get()) end, 'all-join-receiver')

  rt:run()
  assert_eq(received, 'AB', 'all join should feed continuation after external cuts')
end


local function test_wrap_boundary_transforms_after_commit()
  local rt = Runtime.new()
  local ch = Channel.new('wrap-ch')
  local got
  local ran = false

  rt:spawn(function()
    got = Op.perform(ch:get():wrap(function(x)
      ran = true
      return x .. '!'
    end))
  end, 'wrap-receiver')

  rt:spawn(function()
    Op.perform(ch:put('x'))
  end, 'wrap-sender')

  rt:run()
  assert(ran == true, 'wrap boundary should run after commit')
  assert_eq(got, 'x!', 'wrap should transform resumed value')
end

local function test_wrap_boundary_rejects_transactional_continuation()
  local ch = Channel.new('wrap-reject')
  local ok, err = pcall(function()
    return ch:get():wrap(function(x) return x end):and_then(function(x)
      return Op.always(x)
    end)
  end)
  assert(ok == false, 'wrap:and_then should be rejected')
  assert(tostring(err):match('wrap boundary'), 'expected wrap boundary error, got ' .. tostring(err))

  ok, err = pcall(function()
    return ch:get():wrap(function(x) return x end):map(function(x) return x end)
  end)
  assert(ok == false, 'wrap:map should be rejected')
  assert(tostring(err):match('wrap boundary'), 'expected wrap boundary error, got ' .. tostring(err))
end

local function test_wrap_boundary_is_branch_local()
  local rt = Runtime.new()
  local ch = Channel.new('wrap-branch')
  local got
  local ran = false

  rt:spawn(function()
    got = Op.perform(Op.choice(
      Op.always('plain'),
      ch:get():wrap(function(x)
        ran = true
        return x .. '!'
      end)
    ))
  end, 'wrap-choice')

  rt:run()
  assert_eq(got, 'plain', 'plain branch should commit')
  assert(ran == false, 'wrap should not run for unchosen branch')
end

local function test_wrap_boundary_can_perform_after_commit()
  local rt = Runtime.new()
  local ch = Channel.new('wrap-perform-in')
  local out = Channel.new('wrap-perform-out')
  local got
  local observed

  rt:spawn(function()
    got = Op.perform(ch:get():wrap(function(x)
      local ok = Op.perform(out:put(x .. '!'))
      assert(ok == true, 'post-commit wrapper put should complete')
      return x .. '?'
    end))
  end, 'wrap-performing-root')

  rt:spawn(function()
    Op.perform(ch:put('x'))
  end, 'wrap-performing-sender')

  rt:spawn(function()
    observed = Op.perform(out:get())
  end, 'wrap-performing-observer')

  rt:run()
  assert_eq(observed, 'x!', 'wrapper should be able to perform after commit')
  assert_eq(got, 'x?', 'wrapper should transform original perform result')
end


local function test_wrap_boundary_after_commit_event_order()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local ch = Channel.new('wrap-order-ch')
  local order = {}

  local old_print_event = print_event
  print_event = function(event)
    if event.tag == 'order.event' then
      order[#order + 1] = 'commit'
    else
      old_print_event(event)
    end
  end

  rt:spawn(function()
    local got = Op.perform(
      ch:get():and_then(function(x)
        return Op.emit({ tag = 'order.event' }):and_then(function()
          return Op.always(x)
        end)
      end):wrap(function(x)
        order[#order + 1] = 'wrap'
        return x
      end)
    )
    assert_eq(got, 'x', 'order wrap value')
  end, 'wrap-order-receiver')

  rt:spawn(function() Op.perform(ch:put('x')) end, 'wrap-order-sender')
  rt:run()
  print_event = old_print_event

  assert_eq(order[1], 'commit', 'commit event should run before wrapper')
  assert_eq(order[2], 'wrap', 'wrapper should run after commit event')
end


local function test_search_phase_forbids_perform_and_spawn()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local ch = Channel.new('search-phase-guard')

  rt:spawn(function()
    Op.perform(Op.always('x'):and_then(function()
      return Op.perform(ch:get())
    end))
  end, 'bad-perform-during-search')

  local ok, err = pcall(function() drain_runnable(rt) end)
  assert(ok == false, 'perform during proof search expansion should fail')
  assert(tostring(err):match('proof search'), 'expected proof search error, got ' .. tostring(err))

  rt = Runtime.new()
  rt:spawn(function()
    Op.perform(Op.always('x'):and_then(function()
      rt:spawn(function() end, 'bad-spawned-during-search')
      return Op.always('ok')
    end))
  end, 'bad-spawn-during-search')

  ok, err = pcall(function() drain_runnable(rt) end)
  assert(ok == false, 'spawn during proof search expansion should fail')
  assert(tostring(err):match('proof search'), 'expected proof search error, got ' .. tostring(err))
end

local function test_post_commit_phase_is_explicit_in_wrapper()
  local rt = Runtime.new()
  local ch = Channel.new('post-commit-phase')
  local out = Channel.new('post-commit-phase-out')
  local observed
  local saw_post_commit_before = false
  local saw_post_commit_after = false

  rt:spawn(function()
    local got = Op.perform(ch:get():wrap(function(x)
      saw_post_commit_before = CURRENT_TASK and CURRENT_TASK.phase == 'post_commit'
      local ok = Op.perform(out:put(x .. '!'))
      assert(ok == true, 'post-commit phase nested put should complete')
      saw_post_commit_after = CURRENT_TASK and CURRENT_TASK.phase == 'post_commit'
      return x .. '?'
    end))
    assert_eq(got, 'x?', 'post-commit phase wrapper value')
  end, 'post-commit-phase-root')

  rt:spawn(function() Op.perform(ch:put('x')) end, 'post-commit-phase-sender')
  rt:spawn(function() observed = Op.perform(out:get()) end, 'post-commit-phase-observer')
  rt:run()

  assert_eq(observed, 'x!', 'nested post-commit perform observed')
  assert(saw_post_commit_before == true, 'wrapper should run in explicit post_commit phase before nested perform')
  assert(saw_post_commit_after == true, 'wrapper should remain in post_commit phase after nested perform')
end


local function test_or_else_primary_done_wins()
  local rt = Runtime.new()
  local got

  rt:spawn(function()
    got = Op.perform(Op.always('primary'):or_else(Op.always('fallback')))
  end, 'prefer-primary-done')

  rt:run()
  assert_eq(got, 'primary', 'or_else primary should win when immediately available')
end

local function test_or_else_fallback_commits_after_absence_proof()
  local rt = Runtime.new()
  local ch = Channel.new('prefer-fallback-absent')
  local got

  rt:spawn(function()
    got = Op.perform(ch:get():or_else(Op.always('fallback')))
  end, 'prefer-fallback-root')

  rt:run()
  assert_eq(got, 'fallback', 'or_else fallback should commit after primary absence is proved')
end

local function test_or_else_primary_rendezvous_beats_fallback()
  local rt = Runtime.new()
  local ch = Channel.new('prefer-primary-rendezvous')
  local got

  rt:spawn(function()
    got = Op.perform(ch:get():or_else(Op.always('fallback')))
  end, 'prefer-receiver')

  rt:spawn(function()
    Op.perform(ch:put('primary-value'))
  end, 'prefer-sender')

  rt:run()
  assert_eq(got, 'primary-value', 'available primary rendezvous should beat fallback')
end

local function test_or_else_fallback_absence_can_report_budget()
  local rt = Runtime.new()
  local ch = Channel.new('prefer-budget')

  local receiver = rt:spawn(function()
    Op.perform(ch:get():or_else(Op.always('fallback')))
  end, 'prefer-budget-root')
  drain_runnable(rt)

  local result = rt:search_task(receiver)
  assert_eq(result.status, 'found', 'fallback world should be valid before committability proof')
  assert(#result.world:preference_obligations() > 0, 'fallback world should carry preference obligation')

  local proof = rt:prove_committable(result.world, 0)
  assert_eq(proof.status, 'budget', 'zero-budget absence proof should report budget')
end

local function test_or_else_site_address_is_replay_stable()
  local ch = Channel.new('prefer-address')
  local operation = ch:get():or_else(Op.always('fallback'))
  local frames1 = expand_expr(operation, empty_env(), ExpansionContext.root('prefer-address-root'))
  local frames2 = expand_expr(operation, empty_env(), ExpansionContext.root('prefer-address-root'))
  local site1, site2
  for _, f in ipairs(frames1) do
    if f.env and f.env.obligations and f.env.obligations[1] then site1 = f.env.obligations[1].site end
  end
  for _, f in ipairs(frames2) do
    if f.env and f.env.obligations and f.env.obligations[1] then site2 = f.env.obligations[1].site end
  end
  assert(site1 and site2, 'fallback branch should expose preference obligation site')
  assert_eq(site1, site2, 'PreferLink site address should be replay-stable')
end


local function nested_or_else_op(outer, inner)
  return outer:get():or_else(
    inner:get():or_else(Op.always('fallback'))
  )
end

local function test_nested_or_else_obligation_prefixes()
  local rt = Runtime.new()
  local outer = Channel.new('nested-prefix-outer')
  local inner = Channel.new('nested-prefix-inner')

  local receiver = rt:spawn(function()
    Op.perform(nested_or_else_op(outer, inner))
  end, 'nested-prefix-root')
  drain_runnable(rt)

  local result = rt:search_task(receiver)
  assert_eq(result.status, 'found', 'nested fallback world should be valid')

  local obligations = result.world:preference_obligations()
  assert_eq(#obligations, 2, 'nested fallback should create two preference obligations')

  local outer_obligation = obligations[1]
  local inner_obligation = obligations[2]

  assert_eq(#outer_obligation.prefix, 0, 'outer fallback obligation prefix should be empty')
  assert_eq(outer_obligation.fallback_entry.site, outer_obligation.site, 'outer fallback entry should point at outer site')
  assert_eq(outer_obligation.fallback_entry.branch, 'fallback', 'outer fallback entry should record fallback branch')
  assert_eq(#outer_obligation.fallback_entry.prefix, 0, 'outer fallback entry prefix should be empty')

  assert_eq(#inner_obligation.prefix, 1, 'inner fallback obligation should preserve outer fallback prefix')
  assert_eq(inner_obligation.prefix[1].site, outer_obligation.site, 'inner prefix should mention outer site')
  assert_eq(inner_obligation.prefix[1].branch, 'fallback', 'inner prefix should force outer fallback')
  assert_eq(inner_obligation.fallback_entry.site, inner_obligation.site, 'inner fallback entry should point at inner site')
  assert_eq(inner_obligation.fallback_entry.branch, 'fallback', 'inner fallback entry should record fallback branch')
end

local function test_forced_decisions_for_nested_obligation()
  local rt = Runtime.new()
  local outer = Channel.new('nested-forced-outer')
  local inner = Channel.new('nested-forced-inner')

  local receiver = rt:spawn(function()
    Op.perform(nested_or_else_op(outer, inner))
  end, 'nested-forced-root')
  drain_runnable(rt)

  local result = rt:search_task(receiver)
  assert_eq(result.status, 'found', 'nested fallback world should be valid for forced decision test')
  local obligations = result.world:preference_obligations()
  local outer_obligation = obligations[1]
  local inner_obligation = obligations[2]

  local forced_outer = assert(forced_decisions_for_obligation(outer_obligation))
  assert_eq(forced_outer[outer_obligation.site], 'primary', 'outer obligation should force outer primary')

  local forced_inner = assert(forced_decisions_for_obligation(inner_obligation))
  assert_eq(forced_inner[outer_obligation.site], 'fallback', 'inner obligation should replay outer fallback prefix')
  assert_eq(forced_inner[inner_obligation.site], 'primary', 'inner obligation should force inner primary')
end

local function test_nested_or_else_inner_primary_under_outer_fallback()
  local rt = Runtime.new()
  local outer = Channel.new('nested-outer-absent')
  local inner = Channel.new('nested-inner-present')
  local got

  rt:spawn(function()
    got = Op.perform(nested_or_else_op(outer, inner))
  end, 'nested-inner-receiver')

  rt:spawn(function()
    Op.perform(inner:put('inner-primary'))
  end, 'nested-inner-sender')

  rt:run()
  assert_eq(got, 'inner-primary', 'inner primary should win under outer=fallback')
end

local function test_nested_or_else_outer_primary_dominates_inner_fallback()
  local rt = Runtime.new()
  local outer = Channel.new('nested-outer-present')
  local inner = Channel.new('nested-inner-irrelevant')
  local got

  rt:spawn(function()
    got = Op.perform(nested_or_else_op(outer, inner))
  end, 'nested-outer-receiver')

  rt:spawn(function()
    Op.perform(outer:put('outer-primary'))
  end, 'nested-outer-sender')

  rt:run()
  assert_eq(got, 'outer-primary', 'outer primary should dominate nested fallback world')
end


local function test_product_base_env_not_duplicated()
  local rt = Runtime.new()
  local ch = Channel.new('product-base-no-dup')

  local operation = ch:get():or_else(Op.always('fallback')):and_then(function()
    return Op.tensor({ Op.always('a'), Op.always('b') })
  end)

  local receiver = rt:spawn(function()
    Op.perform(operation)
  end, 'product-base-no-dup-root')
  drain_runnable(rt)

  local result = rt:search_task(receiver)
  assert_eq(result.status, 'found', 'product fallback world should be valid before committability proof')

  local obligations = result.world:preference_obligations()
  assert_eq(#obligations, 1, 'pre-product fallback obligation should appear once, not once per lane')
end

local function test_product_lane_obligations_are_lane_local()
  local rt = Runtime.new()
  local a = Channel.new('lane-a')
  local b = Channel.new('lane-b')

  local operation = Op.tensor({
    a:get():or_else(Op.always('fa')),
    b:get():or_else(Op.always('fb')),
  })

  local receiver = rt:spawn(function()
    Op.perform(operation)
  end, 'lane-local-prefer-root')
  drain_runnable(rt)

  local result = rt:search_task(receiver)
  assert_eq(result.status, 'found', 'lane-local fallback world should be valid')

  local obligations = result.world:preference_obligations()
  assert_eq(#obligations, 2, 'each lane fallback should create exactly one local obligation')
  assert(obligations[1].site ~= obligations[2].site, 'lane PreferLink sites should be distinct')
end

local function test_search_committable_task_skips_rejected_candidate()
  local rt = Runtime.new()
  local got

  rt:spawn(function()
    got = Op.perform(Op.choice(Op.always('first'), Op.always('second')))
  end, 'skip-rejected-candidate-root')
  drain_runnable(rt)

  local old_prove = rt.prove_committable
  rt.prove_committable = function(self, world, budget)
    local value = world.entries[1].frame.values[1]
    if value == 'first' then
      return { status = 'dominated', world = world, reason = 'test rejection' }
    end
    return old_prove(self, world, budget)
  end

  local status = rt:try_commit_one()
  rt.prove_committable = old_prove

  assert_eq(status, 'committed', 'runtime should continue past a dominated candidate to a committable candidate')
  while #rt.runnable > 0 do
    local task = table.remove(rt.runnable, 1)
    rt:resume_task(task)
  end
  assert_eq(got, 'second', 'the later committable candidate should be committed')
end


-- Resource used to assert the base+delta read discipline for Op.access.  Its
-- response reports the visible count, while its returned fragment contributes
-- exactly one local tick.
local ViewCounter = {}
ViewCounter.__index = ViewCounter

function ViewCounter.new()
  return setmetatable({ committed = 0 }, ViewCounter)
end

function ViewCounter:tick()
  return Op.access(self, { tag = 'tick' })
end

function ViewCounter:empty_fragment()
  return { count = 0 }
end

function ViewCounter:merge_fragments(a, b)
  return true, { count = (a and a.count or 0) + (b and b.count or 0) }
end

function ViewCounter:step_fragment(fragment, _request)
  local current = fragment and fragment.count or 0
  return true, { value = current }, { count = current + 1 }
end

function ViewCounter:step_fragment_with_view(view_fragment, local_fragment, _request)
  local visible = view_fragment and view_fragment.count or 0
  local local_count = local_fragment and local_fragment.count or 0
  return true, { value = visible }, { count = local_count + 1 }
end

function ViewCounter:validate_fragment(_fragment)
  return true
end

function ViewCounter:commit_fragment(fragment)
  self.committed = self.committed + (fragment and fragment.count or 0)
end

local function test_product_lane_access_reads_base_but_writes_delta()
  local rt = Runtime.new()
  local counter = ViewCounter.new()
  local observed

  rt:spawn(function()
    observed = Op.perform(counter:tick():and_then(function(before_product)
      assert_eq(before_product, 0, 'first access should see empty fragment')
      return Op.tensor({
        counter:tick(),
        Op.always('other-lane'),
      })
    end))
  end, 'fragment-view-root')

  rt:run()

  assert_eq(observed[1][1], 1, 'product lane access should read base_env + local delta')
  assert_eq(counter.committed, 2, 'product lane access should commit base once plus one lane delta')
end


local function test_product_lane_wrap_transforms_after_commit()
  local rt = Runtime.new()
  local a = Channel.new('lane-wrap-a')
  local b = Channel.new('lane-wrap-b')
  local got
  local ran = false

  rt:spawn(function()
    got = Op.perform(Op.tensor({
      a:get():wrap(function(x)
        ran = true
        return x .. '!'
      end),
      b:get(),
    }))
  end, 'lane-wrap-root')

  rt:spawn(function() Op.perform(a:put('A')) end, 'lane-wrap-sender-a')
  rt:spawn(function() Op.perform(b:put('B')) end, 'lane-wrap-sender-b')
  rt:run()

  assert(ran == true, 'lane-local wrapper should run after product commit')
  assert_eq(got[1][1], 'A!', 'lane-local wrapper should transform only lane 1')
  assert_eq(got[2][1], 'B', 'unwrapped lane should return raw value')
end

local function test_product_lane_wrap_can_perform_after_commit()
  local rt = Runtime.new()
  local a = Channel.new('lane-wrap-perform-a')
  local b = Channel.new('lane-wrap-perform-b')
  local c = Channel.new('lane-wrap-perform-c')
  local got

  rt:spawn(function()
    got = Op.perform(Op.tensor({
      a:get():wrap(function(x)
        local y = Op.perform(c:get())
        return x .. y
      end),
      b:get(),
    }))
  end, 'lane-wrap-performing-root')

  rt:spawn(function() Op.perform(a:put('A')) end, 'lane-wrap-performing-sender-a')
  rt:spawn(function() Op.perform(b:put('B')) end, 'lane-wrap-performing-sender-b')
  rt:spawn(function() Op.perform(c:put('C')) end, 'lane-wrap-performing-sender-c')
  rt:run()

  assert_eq(got[1][1], 'AC', 'lane-local wrapper may perform a fresh transaction before outer perform returns')
  assert_eq(got[2][1], 'B', 'other product lane should remain raw')
end

local function test_product_lane_wrap_rejects_transactional_continuation()
  local rt = Runtime.new()
  rt.quiet_deadlock = true

  rt:spawn(function()
    Op.perform(Op.tensor({
      Op.always('a'):wrap(function(x) return x .. '!' end),
      Op.always('b'),
    }):and_then(function(results)
      return Op.always(results)
    end))
  end, 'lane-wrap-bad-cont')

  local ok, err = pcall(function() drain_runnable(rt) end)
  assert(ok == false, 'boundary-tainted product should reject transactional continuation')
  assert(tostring(err):match('boundary lane'), 'expected boundary lane error, got ' .. tostring(err))
end

local function test_product_lane_and_product_wrap_compose_post_commit()
  local rt = Runtime.new()
  local got

  rt:spawn(function()
    got = Op.perform(Op.tensor({
      Op.always('a'):wrap(function(x) return x .. '1' end),
      Op.always('b'),
    }):wrap(function(results)
      return results[1][1] .. results[2][1]
    end))
  end, 'lane-and-product-wrap')

  rt:run()
  assert_eq(got, 'a1b', 'lane-local post program should run before product-level wrapper')
end

local function run_tests()
  test_derivation_addresses_are_stable()
  test_proof_search_is_tri_valued_and_budgeted()
  test_absence_is_generation_stable_not_timeless()
  test_search_phase_forbids_perform_and_spawn()
  test_tensor_self_rendezvous_succeeds()
  test_all_self_rendezvous_fails()
  test_tensor_join_feeds_transactional_continuation()
  test_all_join_feeds_transactional_continuation_after_external_cuts()
  test_wrap_boundary_transforms_after_commit()
  test_wrap_boundary_rejects_transactional_continuation()
  test_wrap_boundary_is_branch_local()
  test_wrap_boundary_can_perform_after_commit()
  test_wrap_boundary_after_commit_event_order()
  test_post_commit_phase_is_explicit_in_wrapper()
  test_or_else_primary_done_wins()
  test_or_else_fallback_commits_after_absence_proof()
  test_or_else_primary_rendezvous_beats_fallback()
  test_or_else_fallback_absence_can_report_budget()
  test_or_else_site_address_is_replay_stable()
  test_nested_or_else_obligation_prefixes()
  test_forced_decisions_for_nested_obligation()
  test_nested_or_else_inner_primary_under_outer_fallback()
  test_nested_or_else_outer_primary_dominates_inner_fallback()
  test_product_base_env_not_duplicated()
  test_product_lane_obligations_are_lane_local()
  test_search_committable_task_skips_rejected_candidate()
  test_product_lane_access_reads_base_but_writes_delta()
  test_product_lane_wrap_transforms_after_commit()
  test_product_lane_wrap_can_perform_after_commit()
  test_product_lane_wrap_rejects_transactional_continuation()
  test_product_lane_and_product_wrap_compose_post_commit()
  print('tests: addresses, proof search/phase guards, tensor/all joins, post-commit frames, PreferLink, nested or_else, product envs, commit search, fragment views, and product boundary programs passed')
  print()
end

-- Run tests and demos.
run_tests()
demo_triple_swap()
demo_ledger()
