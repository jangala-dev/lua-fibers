-- Machine frontier layer: snapshot-indexed expansion of Op expressions into
-- frontiers.  This layer owns origins, dependencies, views, obligation cells,
-- evidence rows, frames, and frontier freshness.

local Op = require('et.op')
local Kernel = require('et.kernel')
local Protocol = require('et.protocol')

local Status = Kernel.Status
local Util = Kernel.Util
local Phase = Kernel.Phase
local Origin, Dependency, Consequence

local Link = Protocol.Link

-- from machine/origin.lua
do
  Origin = {}

  local function esc(x)
    x = tostring(x)
    x = x:gsub('%%', '%%%%'):gsub('/', '%%/'):gsub(':', '%%:')
    return x
  end

  local function copy_list(xs)
    local out = {}
    for i = 1, #(xs or {}) do out[i] = xs[i] end
    return out
  end

  local function copy_boxes(xs)
    local out = {}
    for i = 1, #(xs or {}) do
      local x = xs[i]
      out[i] = { box = x.box, lane = x.lane, kind = x.kind, allow_internal = x.allow_internal }
    end
    return out
  end

  local Methods = {}
  Methods.__index = Methods

  local function new(fields)
    fields = fields or {}
    fields.segments = copy_list(fields.segments)
    fields.decision_prefix = copy_list(fields.decision_prefix)
    fields.lane_path = copy_boxes(fields.lane_path)
    fields.parent_obligation = fields.parent_obligation
    fields.__et_origin = true
    return setmetatable(fields, Methods)
  end

  function Origin.is(x)
    return type(x) == 'table' and x.__et_origin == true
  end

  local function coerce(origin)
    if Origin.is(origin) then return origin end
    return new({ segments = { tostring(origin or 'root') } })
  end

  function Origin.root(id)
    return new({ segments = { tostring(id or 'root') } })
  end

  function Origin.child(origin, label)
    origin = coerce(origin)
    local segments = copy_list(origin.segments)
    segments[#segments + 1] = tostring(label)
    return new({
      segments = segments,
      decision_prefix = origin.decision_prefix,
      lane_path = origin.lane_path,
      parent_obligation = origin.parent_obligation,
    })
  end

  function Origin.index(origin, label, i)
    return Origin.child(origin, tostring(label) .. ':' .. tostring(i))
  end

  function Origin.decision(origin, label, branch)
    origin = Origin.child(origin, tostring(label) .. ':' .. tostring(branch))
    local decisions = copy_list(origin.decision_prefix)
    decisions[#decisions + 1] = tostring(label) .. ':' .. tostring(branch)
    return new({
      segments = origin.segments,
      decision_prefix = decisions,
      lane_path = origin.lane_path,
      parent_obligation = origin.parent_obligation,
    })
  end

  function Origin.lane(origin, box, lane)
    origin = coerce(origin)
    local lanes = copy_boxes(origin.lane_path)
    lanes[#lanes + 1] = {
      box = box.id or box,
      lane = lane,
      kind = box.kind,
      allow_internal = box.allow_internal == true,
    }
    return new({
      segments = copy_list(origin.segments),
      decision_prefix = origin.decision_prefix,
      lane_path = lanes,
      parent_obligation = origin.parent_obligation,
    })
  end


  function Origin.with_lane_path(origin, path)
    origin = coerce(origin)
    return new({
      segments = origin.segments,
      decision_prefix = origin.decision_prefix,
      lane_path = path,
      parent_obligation = origin.parent_obligation,
    })
  end

  function Origin.with_parent_obligation(origin, ref)
    origin = coerce(origin)
    return new({
      segments = origin.segments,
      decision_prefix = origin.decision_prefix,
      lane_path = origin.lane_path,
      parent_obligation = ref,
    })
  end

  function Origin.copy(origin)
    origin = coerce(origin)
    return new({
      segments = origin.segments,
      decision_prefix = origin.decision_prefix,
      lane_path = origin.lane_path,
      parent_obligation = origin.parent_obligation,
    })
  end

  function Origin.key(origin)
    if not Origin.is(origin) then return esc(origin or 'root') end
    local parts = {}
    for i = 1, #(origin.segments or {}) do parts[#parts + 1] = esc(origin.segments[i]) end
    if #(origin.decision_prefix or {}) > 0 then
      parts[#parts + 1] = 'dec=' .. esc(table.concat(origin.decision_prefix, ','))
    end
    if #(origin.lane_path or {}) > 0 then
      local lanes = {}
      for i = 1, #origin.lane_path do
        local lane = origin.lane_path[i]
        lanes[#lanes + 1] = tostring(lane.box) .. '#' .. tostring(lane.lane)
      end
      parts[#parts + 1] = 'lane=' .. esc(table.concat(lanes, ','))
    end
    if origin.parent_obligation ~= nil then
      parts[#parts + 1] = 'parent=' .. esc(origin.parent_obligation)
    end
    return table.concat(parts, '/')
  end

  function Methods:key() return Origin.key(self) end
  function Methods:child(label) return Origin.child(self, label) end
  function Methods:copy() return Origin.copy(self) end
  function Methods:copy_boxes() return Origin.copy_boxes(self.lane_path or {}) end
  function Methods:__tostring() return Origin.key(self) end

  Origin.coerce = coerce
  Origin.copy_boxes = copy_boxes
  Origin.copy_list = copy_list
end

-- from machine/dependency.lua
do
  Dependency = {}
  local Methods = {}
  Methods.__index = Methods

  function Dependency.new()
    return setmetatable({ order = {}, by_resource = {} }, Methods)
  end

  function Methods:add(resource, version)
    local old = self.by_resource[resource]
    if old == nil then
      self.order[#self.order + 1] = resource
      self.by_resource[resource] = version
      return true
    end
    return old == version
  end

  function Methods:merge(other)
    for i = 1, #(other and other.order or {}) do
      local resource = other.order[i]
      if not self:add(resource, other.by_resource[resource]) then
        return false, resource
      end
    end
    return true
  end

  function Methods:stale_resources()
    local stale = {}
    for i = 1, #self.order do
      local resource = self.order[i]
      local expected = self.by_resource[resource]
      local current
      if type(resource.current_version) == 'function' then
        current = resource:current_version()
      else
        current = resource.version
      end
      if current ~= expected then stale[#stale + 1] = resource end
    end
    return stale
  end

  function Methods:fresh_status(reason)
    local stale = self:stale_resources()
    if #stale == 0 then return true end
    return false, Status.stale(stale, reason or 'dependencies stale')
  end

  function Methods:is_fresh()
    return #self:stale_resources() == 0
  end

  function Methods:copy()
    local out = Dependency.new()
    out:merge(self)
    return out
  end
end


-- from machine/consequence.lua
do
  Consequence = {}

  local function copy_items(xs)
    local out = {}
    for i = 1, #(xs or {}) do out[i] = Util.copy_descriptor(xs[i]) end
    return out
  end

  local function kind_of(c)
    return c and (c.kind or c.tag)
  end

  local function key_of(c)
    return c and (c.key or c.id or c.resource or c.target)
  end

  local function string_key(kind, key)
    return tostring(kind) .. ':' .. tostring(key)
  end

  local function descriptor_equal(a, b, seen)
    if a == b then return true end
    local ta, tb = type(a), type(b)
    if ta ~= tb then return false end
    if ta ~= 'table' then return false end
    if Util.is_et_identity_ref(a) or Util.is_et_identity_ref(b) then return a == b end
    seen = seen or {}
    seen[a] = seen[a] or {}
    if seen[a][b] then return true end
    seen[a][b] = true
    for k, v in pairs(a) do
      if not descriptor_equal(v, b[k], seen) then return false end
    end
    for k, _ in pairs(b) do
      if a[k] == nil then return false end
    end
    return true
  end

  function Consequence.empty()
    return { transaction = {}, resource = {}, obligation = {} }
  end

  function Consequence.copy(log)
    return {
      transaction = copy_items(log and log.transaction or {}),
      resource = copy_items(log and log.resource or {}),
      obligation = copy_items(log and log.obligation or {}),
    }
  end

  function Consequence.append_transaction(log, c)
    local out = Consequence.copy(log)
    out.transaction[#out.transaction + 1] = Util.copy_descriptor(c)
    return out
  end

  local function suffix_after(full, base)
    full = full or {}; base = base or {}
    local out = {}
    for i = #base + 1, #full do out[#out + 1] = Util.copy_descriptor(full[i]) end
    return out
  end

  function Consequence.subtract(full, base)
    full = Consequence.copy(full); base = Consequence.copy(base)
    return {
      transaction = suffix_after(full.transaction, base.transaction),
      resource = suffix_after(full.resource, base.resource),
      obligation = suffix_after(full.obligation, base.obligation),
    }
  end

  function Consequence.append(a, b)
    local out = Consequence.copy(a)
    local bcopy = Consequence.copy(b)
    Util.append_list(out.transaction, bcopy.transaction)
    Util.append_list(out.resource, bcopy.resource)
    Util.append_list(out.obligation, bcopy.obligation)
    return out
  end

  local RESOURCE_POLICIES = {
    wake = { mode = 'idempotent' },
    kick = { mode = 'idempotent' },
    publish = { mode = 'ordered' },
  }

  local OBLIGATION_POLICIES = {
    settlement = { mode = 'one_shot' },
    settle = { mode = 'one_shot' },
    admission = { mode = 'one_shot' },
    admitted = { mode = 'one_shot' },
    withdrawal = { mode = 'one_shot' },
    withdrawn = { mode = 'one_shot' },
    selected = { mode = 'one_shot' },
    lost = { mode = 'one_shot' },
    discharged = { mode = 'one_shot' },
    spawn = { mode = 'one_shot' },
  }

  local function normalise_resource(input, out)
    local seen = {}
    for i = 1, #input.resource do
      local c = input.resource[i]
      local kind = kind_of(c)
      local policy = RESOURCE_POLICIES[kind]
      if not policy then return Status.conflict('unknown resource consequence kind ' .. tostring(kind), c) end
      if policy.mode == 'ordered' then
        out.resource[#out.resource + 1] = Util.copy_descriptor(c)
      elseif policy.mode == 'idempotent' then
        local key = key_of(c)
        if key == nil then return Status.conflict('resource consequence ' .. tostring(kind) .. ' missing key/id/target', c) end
        local skey = string_key(kind, key)
        local prior = seen[skey]
        if prior == nil then
          seen[skey] = c
          out.resource[#out.resource + 1] = Util.copy_descriptor(c)
        elseif not descriptor_equal(prior, c) then
          return Status.conflict('incompatible duplicate resource consequence ' .. skey, { prior = prior, duplicate = c })
        end
      else
        return Status.conflict('unsupported resource consequence policy ' .. tostring(policy.mode), c)
      end
    end
    return Status.found(true)
  end

  local function normalise_obligation(input, out)
    local seen = {}
    for i = 1, #input.obligation do
      local c = input.obligation[i]
      local kind = kind_of(c)
      local policy = OBLIGATION_POLICIES[kind]
      if not policy then return Status.conflict('unknown obligation consequence kind ' .. tostring(kind), c) end
      local id = c.id or c.obligation_id or c.key
      if id == nil then return Status.conflict('obligation consequence missing id', c) end
      if seen[id] then
        return Status.conflict('duplicate obligation consequence ' .. tostring(id), { prior = seen[id], duplicate = c })
      end
      seen[id] = c
      out.obligation[#out.obligation + 1] = Util.copy_descriptor(c)
    end
    return Status.found(true)
  end

  function Consequence.normalise(log)
    local input = Consequence.copy(log)
    local out = Consequence.empty()
    out.transaction = copy_items(input.transaction)
    local rs = normalise_resource(input, out)
    if not Status.is_found(rs) then return rs end
    local os = normalise_obligation(input, out)
    if not Status.is_found(os) then return os end
    return Status.found(out)
  end

  function Consequence.interpret(log, runtime, token)
    Phase.require(token, 'consequence')
    local normalised = Consequence.normalise(log)
    if not Status.is_found(normalised) then return normalised end
    if runtime then
      runtime.published_consequences = runtime.published_consequences or {}
      runtime.published_consequences[#runtime.published_consequences + 1] = Consequence.copy(normalised.value)
    end
    return Status.found(Consequence.copy(normalised.value))
  end

  Consequence.RESOURCE_POLICIES = RESOURCE_POLICIES
  Consequence.OBLIGATION_POLICIES = OBLIGATION_POLICIES
end


local View, Obligation

-- from machine/view.lua
do
  View = {}
  local Methods = {}
  Methods.__index = Methods

  local next_id = 0

  function View.open(label)
    next_id = next_id + 1
    return setmetatable({
      id = next_id,
      label = label or ('view-' .. tostring(next_id)),
      entries = {},
      order = {},
    }, Methods)
  end

  function View.is(x)
    return type(x) == 'table' and getmetatable(x) == Methods
  end

  function View.assert(x, where)
    if not View.is(x) then error((where or 'view') .. ': expected View', 3) end
    return x
  end

  function Methods:of(resource)
    if type(resource) ~= 'table' or type(resource.snapshot) ~= 'function' then
      return Status.fatal('resource does not implement snapshot')
    end
    local entry = self.entries[resource]
    if not entry then
      local ok, snap = pcall(function() return resource:snapshot() end)
      if not ok then return Status.fatal(snap) end
      if type(snap) ~= 'table' then return Status.fatal('resource snapshot must be table') end
      if snap.resource == nil then snap.resource = resource end
      if snap.version == nil then return Status.fatal('resource snapshot missing version') end
      self.entries[resource] = snap
      self.order[#self.order + 1] = resource
      entry = snap
    end
    return Status.found(entry)
  end

  function Methods:current_version(resource)
    if type(resource) == 'table' and type(resource.current_version) == 'function' then
      return resource:current_version()
    end
    if type(resource) == 'table' and resource.version ~= nil then
      return resource.version
    end
    return nil
  end

  function Methods:is_fresh(dependencies)
    local stale = dependencies:stale_resources()
    if #stale == 0 then return true end
    return false, Status.stale(stale, 'view dependencies stale')
  end
end

-- from machine/obligation.lua
do
  Obligation = {}
  local StoreMethods = {}
  local RefMethods = {}
  StoreMethods.__index = StoreMethods
  RefMethods.__index = RefMethods

  local next_store_id = 0
  local default_store
  local registry = {}

  local function copy_payload(payload)
    if payload == nil then return nil end
    return Util.copy_descriptor(payload)
  end

  local function key_for(origin, kind)
    return Origin.key(origin) .. '/obligation:' .. tostring(kind or 'generic')
  end

  local function ref_from_cell(cell)
    return setmetatable({
      __et_obligation = true,
      id = cell.id,
      kind = cell.kind,
      origin = Origin.copy(cell.origin),
      origin_id = Origin.key(cell.origin),
      payload = copy_payload(cell.payload),
      store = cell.store,
      store_id = cell.store and cell.store.id,
    }, RefMethods)
  end

  local function new_store(id)
    next_store_id = next_store_id + 1
    local store = setmetatable({
      __et_obligation_store = true,
      id = id or ('obligation-store-' .. tostring(next_store_id)),
      cells = {},
    }, StoreMethods)
    return store
  end

  local function ensure_default_store()
    if default_store == nil then default_store = new_store('default-obligation-store') end
    return default_store
  end

  local function store_for_ref(ref)
    if type(ref) == 'table' and ref.store and ref.store.__et_obligation_store then return ref.store end
    local id = type(ref) == 'table' and ref.id or ref
    if id ~= nil and registry[id] then return registry[id].store end
    return ensure_default_store()
  end

  local function consequence_for(ref, state)
    local kind = state
    if state == 'selected' or state == 'lost' or state == 'withdrawn' or state == 'discharged' then
      kind = state
    end
    return {
      kind = kind,
      id = ref.id,
      obligation_id = ref.id,
      obligation_kind = ref.kind,
      origin_id = ref.origin_id,
      store_id = ref.store_id,
    }
  end

  function Obligation.Store_new(id)
    return new_store(id)
  end

  Obligation.Store = { new = new_store }

  function StoreMethods:ref(origin, kind, payload)
    origin = Origin.coerce(origin or 'obligation')
    local id = key_for(origin, kind)
    local cell = self.cells[id]
    if not cell then
      cell = {
        id = id,
        kind = kind or 'generic',
        origin = Origin.copy(origin),
        origin_id = Origin.key(origin),
        payload = copy_payload(payload),
        state = 'unpublished',
        published = false,
        store = self,
      }
      self.cells[id] = cell
      registry[id] = cell
    end
    return ref_from_cell(cell)
  end

  function StoreMethods:cell(ref)
    local id = type(ref) == 'table' and ref.id or ref
    if id == nil then return nil end
    return self.cells[id]
  end

  function StoreMethods:state(ref)
    local cell = self:cell(ref)
    return cell and cell.state or 'unpublished'
  end

  function StoreMethods:is_terminal(ref)
    local s = self:state(ref)
    return s == 'selected' or s == 'lost' or s == 'withdrawn' or s == 'discharged'
  end

  function StoreMethods:nack_enabled(ref)
    local s = self:state(ref)
    return s == 'lost' or s == 'withdrawn'
  end

  function StoreMethods:publish(ref)
    if not Obligation.is(ref) then return Status.fatal('publish requires obligation ref') end
    local cell = self:cell(ref)
    if not cell then return Status.fatal('unknown obligation ref ' .. tostring(ref.id)) end
    if cell.state == 'unpublished' then cell.state = 'pending' end
    cell.published = true
    return Status.found(ref_from_cell(cell))
  end

  function StoreMethods:withdraw(ref)
    if not Obligation.is(ref) then return Status.fatal('withdraw requires obligation ref') end
    local cell = self:cell(ref)
    if not cell then return Status.fatal('unknown obligation ref ' .. tostring(ref.id)) end
    if cell.state == 'unpublished' or cell.state == 'pending' then
      cell.state = 'withdrawn'
      cell.published = true
      return Status.found(ref_from_cell(cell))
    end
    if cell.state == 'withdrawn' then return Status.found(ref_from_cell(cell)) end
    return Status.conflict('cannot withdraw terminal obligation ' .. tostring(cell.state), ref)
  end

  function StoreMethods:prepare_transition(ref, target_state, token)
    Phase.require(token, 'prepare')
    if not Obligation.is(ref) then return Status.fatal('obligation transition requires ref') end
    local cell = self:cell(ref)
    if not cell then return Status.fatal('unknown obligation ref ' .. tostring(ref.id)) end
    if cell.state == target_state then
      return Status.found({
        ref = ref_from_cell(cell),
        target_state = target_state,
        consequences = Consequence.empty(),
        apply = function(commit_token) Phase.require(commit_token, 'commit') end,
      })
    end
    if cell.state == 'selected' or cell.state == 'lost' or cell.state == 'withdrawn' or cell.state == 'discharged' then
      return Status.conflict('obligation already terminal: ' .. tostring(cell.state), ref)
    end
    if target_state ~= 'selected' and target_state ~= 'lost' and target_state ~= 'withdrawn' and target_state ~= 'discharged' then
      return Status.fatal('unsupported obligation target state ' .. tostring(target_state))
    end
    local store = self
    return Status.found({
      ref = ref_from_cell(cell),
      target_state = target_state,
      consequences = {
        transaction = {},
        resource = {},
        obligation = { consequence_for(ref_from_cell(cell), target_state) },
      },
      apply = function(commit_token)
        Phase.require(commit_token, 'commit')
        local current = store.cells[ref.id]
        if not current then error('unknown obligation at commit ' .. tostring(ref.id), 2) end
        if current.state ~= 'pending' and current.state ~= 'unpublished' then
          error('obligation not pending at commit: ' .. tostring(ref.id) .. ' is ' .. tostring(current.state), 2)
        end
        current.state = target_state
        current.published = current.published or target_state == 'selected'
      end,
    })
  end

  function StoreMethods:reset()
    for id, cell in pairs(self.cells) do
      if registry[id] == cell then registry[id] = nil end
    end
    self.cells = {}
  end

  function Obligation.is(x)
    return type(x) == 'table' and x.__et_obligation == true
  end

  function Obligation.key(ref)
    return ref and ref.id
  end

  function Obligation.ref(origin, kind, payload, store)
    return (store or ensure_default_store()):ref(origin, kind, payload)
  end

  function Obligation.cell(ref)
    if not Obligation.is(ref) then return nil end
    return store_for_ref(ref):cell(ref)
  end

  function Obligation.state(ref)
    return store_for_ref(ref):state(ref)
  end

  function Obligation.is_terminal(ref)
    return store_for_ref(ref):is_terminal(ref)
  end

  function Obligation.nack_enabled(ref)
    return store_for_ref(ref):nack_enabled(ref)
  end

  function Obligation.withdraw(ref)
    return store_for_ref(ref):withdraw(ref)
  end

  function Obligation.publish(ref)
    return store_for_ref(ref):publish(ref)
  end

  function Obligation.prepare_transition(ref, target_state, token)
    return store_for_ref(ref):prepare_transition(ref, target_state, token)
  end

  function Obligation.default_store()
    return ensure_default_store()
  end

  function Obligation.reset_for_tests()
    registry = {}
    default_store = new_store('default-obligation-store')
  end

  function RefMethods:state()
    return Obligation.state(self)
  end

  function RefMethods:with_state(_state)
    error('obligation refs are linear cells; use prepare_transition', 2)
  end

  function RefMethods:__tostring()
    return '<obligation ' .. tostring(self.id) .. ' ' .. tostring(Obligation.state(self)) .. '>'
  end
end

local Absence, ExpansionMemo, Evidence, Frame, Frontier

-- from machine/absence.lua
do
  Absence = {}

  local next_id = 0

  function Absence.obligation(fields)
    next_id = next_id + 1
    local origin = Origin.copy(fields.origin)
    return {
      tag = 'absence_obligation',
      id = 'absence-' .. tostring(next_id),
      op = fields.op,
      evidence = fields.evidence,
      origin = origin,
      occurrence = origin,
      origin_id = Origin.key(origin),
      decision_prefix = Origin.copy_list(origin.decision_prefix),
      lane_path = Origin.copy_boxes(origin.lane_path),
      snapshot_id = fields.snapshot_id,
    }
  end

  function Absence.certificate(obligation, root, search_space_id)
    return {
      tag = 'absence_certificate',
      obligation = obligation,
      obligation_id = obligation.id,
      root = root,
      snapshot_id = obligation.snapshot_id,
      search_space_id = search_space_id,
    }
  end
end

-- from machine/expansion_memo.lua
do
  ExpansionMemo = {}

  local function ensure(attempt)
    if type(attempt) ~= 'table' then
      return nil, Status.fatal('ExpansionMemo requires RootAttempt')
    end
    attempt.expansion_memo = attempt.expansion_memo or {}
    return attempt.expansion_memo
  end

  function ExpansionMemo.ensure(attempt)
    local memo, err = ensure(attempt)
    if not memo then return err end
    return Status.found(memo)
  end

  function ExpansionMemo.key(kind, occurrence)
    return tostring(kind) .. ':' .. Origin.key(occurrence)
  end

  function ExpansionMemo.force(attempt, kind, occurrence, thunk)
    if type(thunk) ~= 'function' then return Status.fatal('ExpansionMemo.force requires thunk') end
    local memo, err = ensure(attempt)
    if not memo then return err end
    local bucket = memo[kind]
    if not bucket then
      bucket = {}
      memo[kind] = bucket
    end
    local key = ExpansionMemo.key(kind, occurrence)
    local cell = bucket[key]
    if cell then
      if cell.state == 'ready' then return Status.found(cell.value) end
      if cell.state == 'forcing' then return Status.fatal('recursive expansion memo force: ' .. key) end
      if cell.state == 'failed' then return Status.fatal(cell.reason) end
      return Status.fatal('unknown expansion memo state: ' .. tostring(cell.state))
    end
    cell = { state = 'forcing', kind = kind, occurrence = Origin.copy(occurrence), key = key }
    bucket[key] = cell
    local ok, value = pcall(thunk)
    if not ok then
      cell.state = 'failed'
      cell.reason = value
      return Status.fatal(value)
    end
    cell.state = 'ready'
    cell.value = value
    return Status.found(value)
  end

  function ExpansionMemo.count(attempt, kind)
    local memo = attempt and attempt.expansion_memo or nil
    local bucket = memo and memo[kind] or nil
    local n = 0
    for _ in pairs(bucket or {}) do n = n + 1 end
    return n
  end
end

-- from machine/evidence.lua
do
  Evidence = {}

  local function new_resources()
    return { order = {}, by_resource = {} }
  end

  local function copy_resources(resources)
    local out = new_resources()
    for i = 1, #(resources and resources.order or {}) do
      local resource = resources.order[i]
      out.order[#out.order + 1] = resource
      out.by_resource[resource] = resources.by_resource[resource]
    end
    return out
  end

  local function copy_occurrence(o)
    if type(o) ~= 'table' then return o end
    local out = {}
    for k, v in pairs(o) do out[k] = v end
    if o.lane_path then out.lane_path = Origin.copy_boxes(o.lane_path) end
    if o.decision_prefix then out.decision_prefix = Origin.copy_list(o.decision_prefix) end
    return out
  end

  local function copy_occurrences(xs)
    local out = {}
    for i = 1, #(xs or {}) do out[i] = copy_occurrence(xs[i]) end
    return out
  end

  function Evidence.empty()
    return {
      resources = new_resources(),
      dependencies = Dependency.new(),
      consequences = Consequence.empty(),
      post_programs = {},
      absence_obligations = {},
      absence_certificates = {},
      obligation_publications = {},
      selected_obligations = {},
      selected_occurrences = {},
    }
  end

  function Evidence.copy(e)
    return {
      resources = copy_resources(e and e.resources or nil),
      dependencies = e and e.dependencies and e.dependencies:copy() or Dependency.new(),
      consequences = Consequence.copy(e and e.consequences or nil),
      post_programs = Util.copy_list(e and e.post_programs or {}),
      absence_obligations = Util.copy_list(e and e.absence_obligations or {}),
      absence_certificates = Util.copy_list(e and e.absence_certificates or {}),
      obligation_publications = Util.copy_list(e and e.obligation_publications or {}),
      selected_obligations = Util.copy_list(e and e.selected_obligations or {}),
      selected_occurrences = copy_occurrences(e and e.selected_occurrences or {}),
    }
  end

  local function put_resource(resources, resource, fragment)
    if fragment == nil then return end
    if resources.by_resource[resource] == nil then
      resources.order[#resources.order + 1] = resource
    end
    resources.by_resource[resource] = fragment
  end

  Evidence.put_resource = put_resource

  function Evidence.coexist(a, b, view, token)
    if view ~= nil then Phase.require(token, 'search') end
    local out = Evidence.copy(a)
    for i = 1, #(b.resources and b.resources.order or {}) do
      local resource = b.resources.order[i]
      local existing = out.resources.by_resource[resource]
      local incoming = b.resources.by_resource[resource]
      if existing == nil then
        put_resource(out.resources, resource, incoming)
      elseif existing ~= incoming then
        if view == nil then
          return Status.conflict('evidence coexist requires view/token for resource fragment algebra', resource)
        end
        local combined = Link.merge(view, resource, { kind = 'coexist', fragments = { existing, incoming } }, token)
        if not Status.is_found(combined) then return combined end
        put_resource(out.resources, resource, combined.value.fragment)
      end
    end
    local ok, resource = out.dependencies:merge(b.dependencies)
    if not ok then return Status.stale({ resource }, 'evidence dependencies disagree') end
    out.consequences = Consequence.append(out.consequences, b.consequences)
    Util.append_list(out.post_programs, b.post_programs)
    Util.append_list(out.absence_obligations, b.absence_obligations)
    Util.append_list(out.absence_certificates, b.absence_certificates)
    Util.append_list(out.obligation_publications, b.obligation_publications)
    Util.append_list(out.selected_obligations, b.selected_obligations)
    Util.append_list(out.selected_occurrences, b.selected_occurrences)
    return Status.found(out)
  end

  -- Extend an inherited prefix with a lane contribution after sibling lanes have
  -- been reconciled. Prefix <> lane is ordered; lane <> lane is coexistence.
  function Evidence.extend(prefix, delta, view, token)
    Phase.require(token, 'search')
    local out = Evidence.copy(prefix)
    for i = 1, #(delta.resources and delta.resources.order or {}) do
      local resource = delta.resources.order[i]
      local existing = out.resources.by_resource[resource]
      local incoming = delta.resources.by_resource[resource]
      if existing == nil then
        put_resource(out.resources, resource, incoming)
      elseif incoming ~= nil then
        local extended = Link.merge(view, resource, { kind = 'extend', base = existing, fragments = { incoming } }, token)
        if not Status.is_found(extended) then return extended end
        put_resource(out.resources, resource, extended.value.fragment)
      end
    end
    local ok, resource = out.dependencies:merge(delta.dependencies)
    if not ok then return Status.stale({ resource }, 'evidence dependencies disagree') end
    out.consequences = Consequence.append(out.consequences, delta.consequences)
    Util.append_list(out.post_programs, delta.post_programs)
    Util.append_list(out.absence_obligations, delta.absence_obligations)
    Util.append_list(out.absence_certificates, delta.absence_certificates)
    Util.append_list(out.obligation_publications, delta.obligation_publications)
    Util.append_list(out.selected_obligations, delta.selected_obligations)
    Util.append_list(out.selected_occurrences, delta.selected_occurrences)
    return Status.found(out)
  end

  function Evidence.project(base, full, view, token)
    Phase.require(token, 'search')
    local out = Evidence.empty()
    for i = 1, #(full.resources and full.resources.order or {}) do
      local resource = full.resources.order[i]
      local base_fragment = base.resources and base.resources.by_resource[resource]
      local full_fragment = full.resources.by_resource[resource]
      if base_fragment == nil then
        put_resource(out.resources, resource, full_fragment)
      elseif full_fragment ~= base_fragment then
        local projected = Link.merge(view, resource, { kind = 'project', base = base_fragment, fragments = { full_fragment } }, token)
        if not Status.is_found(projected) then return projected end
        if projected.value.fragment ~= nil then put_resource(out.resources, resource, projected.value.fragment) end
      end
    end
    -- Dependencies are certificates for the snapshot.  A lane delta retains the
    -- full dependency set used to construct it; merge is idempotent by version.
    out.dependencies = full.dependencies:copy()

    -- Consequences/post programs/obligations/selected occurrences in a product
    -- lane are lane-local: the inherited base is not duplicated.
    out.consequences = Consequence.subtract(full.consequences, base.consequences)
    for i = #((base.post_programs) or {}) + 1, #(full.post_programs or {}) do out.post_programs[#out.post_programs + 1] = full.post_programs[i] end
    for i = #((base.absence_obligations) or {}) + 1, #(full.absence_obligations or {}) do out.absence_obligations[#out.absence_obligations + 1] = full.absence_obligations[i] end
    for i = #((base.absence_certificates) or {}) + 1, #(full.absence_certificates or {}) do out.absence_certificates[#out.absence_certificates + 1] = full.absence_certificates[i] end
    for i = #((base.obligation_publications) or {}) + 1, #(full.obligation_publications or {}) do out.obligation_publications[#out.obligation_publications + 1] = full.obligation_publications[i] end
    for i = #((base.selected_obligations) or {}) + 1, #(full.selected_obligations or {}) do out.selected_obligations[#out.selected_obligations + 1] = full.selected_obligations[i] end
    for i = #((base.selected_occurrences) or {}) + 1, #(full.selected_occurrences or {}) do out.selected_occurrences[#out.selected_occurrences + 1] = copy_occurrence(full.selected_occurrences[i]) end
    return Status.found(out)
  end

  function Evidence.with_transaction_consequence(e, c)
    local out = Evidence.copy(e)
    out.consequences = Consequence.append_transaction(out.consequences, c)
    return out
  end

  function Evidence.with_post_program(e, k)
    local out = Evidence.copy(e)
    out.post_programs[#out.post_programs + 1] = k
    return out
  end

  function Evidence.with_absence_obligation(e, obligation)
    local out = Evidence.copy(e)
    out.absence_obligations[#out.absence_obligations + 1] = obligation
    return out
  end

  function Evidence.with_absence_certificate(e, certificate)
    local out = Evidence.copy(e)
    out.absence_certificates[#out.absence_certificates + 1] = certificate
    return out
  end


  function Evidence.with_obligation_publication(e, ref)
    local out = Evidence.copy(e)
    out.obligation_publications[#out.obligation_publications + 1] = ref
    return out
  end

  function Evidence.with_selected_obligation(e, ref)
    local out = Evidence.copy(e)
    out.selected_obligations[#out.selected_obligations + 1] = ref
    return out
  end

  function Evidence.has_nack_observation(e, ref)
    local id = ref and ref.id
    if id == nil then return false end
    for i = 1, #(e and e.selected_occurrences or {}) do
      local occ = e.selected_occurrences[i]
      if occ.kind == 'nack' and occ.obligation_id == id then return true end
    end
    return false
  end

  function Evidence.with_selected_occurrence(e, occurrence)
    local out = Evidence.copy(e)
    out.selected_occurrences[#out.selected_occurrences + 1] = copy_occurrence(occurrence)
    return out
  end

  Evidence.copy_resources = copy_resources
  Evidence.new_resources = new_resources
  Evidence.copy_occurrence = copy_occurrence
end

-- from machine/frame.lua
do
  Frame = {}
  local Methods = {}
  Methods.__index = Methods

  local next_open_claim_id = 0
  local next_frame_id = 0

  local function copy_assignments(assignments)
    local out = {}
    for k, v in pairs(assignments or {}) do out[k] = v end
    return out
  end

  local function copy_steps(steps)
    local out = {}
    for i = 1, #(steps or {}) do out[i] = steps[i] end
    return out
  end

  local function copy_box_path(path)
    local out = {}
    for i = 1, #(path or {}) do
      local x = path[i]
      out[i] = { box = x.box, lane = x.lane, kind = x.kind, allow_internal = x.allow_internal }
    end
    return out
  end

  local function copy_open_claim(open_claim)
    local out = {}
    for k, v in pairs(open_claim or {}) do out[k] = v end
    out.box_path = copy_box_path(open_claim and open_claim.box_path or {})
    if open_claim and open_claim.origin then out.origin = Origin.copy(open_claim.origin) end
    return out
  end

  local function copy_open_claims(open_claims)
    local out = {}
    for i = 1, #(open_claims or {}) do out[i] = copy_open_claim(open_claims[i]) end
    return out
  end

  local function copy_wait(wait)
    local out = {}
    for k, v in pairs(wait or {}) do out[k] = v end
    if wait and wait.origin then out.origin = Origin.copy(wait.origin) end
    return out
  end

  local function copy_waits(waits)
    local out = {}
    for i = 1, #(waits or {}) do out[i] = copy_wait(waits[i]) end
    return out
  end

  local function new_frame(fields)
    next_frame_id = next_frame_id + 1
    fields = fields or {}
    fields.id = fields.id or ('frame-' .. tostring(next_frame_id))
    fields.origin = Origin.coerce(fields.origin or fields.origin_id or fields.id)
    fields.origin_id = Origin.key(fields.origin)
    fields.open_claims = fields.open_claims or {}
    fields.external_waits = copy_waits(fields.external_waits or {})
    fields.evidence = Evidence.copy(fields.evidence or Evidence.empty())
    fields.kont = copy_steps(fields.kont)
    return setmetatable(fields, Methods)
  end

  function Frame.next_open_claim_id()
    next_open_claim_id = next_open_claim_id + 1
    return 'open_claim-' .. tostring(next_open_claim_id)
  end

  function Frame.new_product_box(kind, origin)
    return {
      id = Origin.key(origin) .. '/box:' .. tostring(kind),
      kind = kind,
      allow_internal = kind == 'tensor',
    }
  end

  function Frame.done(values, evidence, origin)
    values = values or Util.pack()
    return new_frame({
      kind = 'done',
      origin = origin,
      values = values,
      eval = function(_assignments) return values end,
      evidence = evidence,
    })
  end

  function Frame.pending(wait, evidence, origin)
    if type(wait) ~= 'table' then error('Frame.pending: expected external wait', 2) end
    origin = Origin.coerce(origin or wait.origin or ('wait-' .. tostring(next_frame_id + 1)))
    local w = copy_wait(wait)
    w.origin = Origin.coerce(w.origin or origin)
    w.origin_id = Origin.key(w.origin)
    return new_frame({
      kind = 'pending',
      origin = origin,
      external_waits = { w },
      evidence = evidence,
      eval = function(_) error('pending external wait has no committed value', 2) end,
    })
  end

  function Frame.open_claim(raw_open_claim, evidence, origin)
    if type(raw_open_claim) ~= 'table' then error('Frame.open_claim: expected open claim', 2) end
    origin = Origin.coerce(origin or raw_open_claim.origin or ('open_claim-' .. tostring(next_open_claim_id + 1)))
    local open_claim = copy_open_claim(raw_open_claim)
    open_claim.id = open_claim.id or Frame.next_open_claim_id()
    open_claim.origin = Origin.coerce(open_claim.origin or Origin.child(origin, 'open_claim:' .. tostring(open_claim.role or open_claim.tag or 'claim')))
    open_claim.origin_id = Origin.key(open_claim.origin)
    open_claim.box_path = Origin.copy_boxes(origin.lane_path or open_claim.box_path or {})
    return new_frame({
      kind = 'open',
      origin = origin,
      open_claims = { open_claim },
      evidence = evidence,
      eval = function(assignments)
        assignments = assignments or {}
        local row = assignments[open_claim.id]
        if row == nil then error('open claim has no completion assignment: ' .. tostring(open_claim.id), 2) end
        return Util.pack(Util.unpack(row))
      end,
    })
  end

  local function open_claim_with_lane(open_claim, box, lane)
    local out = copy_open_claim(open_claim)
    out.box_path = copy_box_path(out.box_path or {})
    local already = false
    for i = 1, #out.box_path do
      if out.box_path[i].box == box.id then already = true; break end
    end
    if not already then
      table.insert(out.box_path, 1, {
        box = box.id,
        lane = lane,
        kind = box.kind,
        allow_internal = box.allow_internal == true,
      })
    end
    out.origin = Origin.with_lane_path(out.origin or out.origin_id or open_claim.id, out.box_path)
    out.origin_id = Origin.key(out.origin)
    return out
  end

  function Frame.product(children, evidence, internal_assignments, open_open_claims, allow_internal, origin, kont, box)
    children = children or {}
    internal_assignments = copy_assignments(internal_assignments)
    origin = Origin.coerce(origin or ('product-' .. tostring(next_frame_id + 1)))
    local kind = allow_internal and 'tensor' or 'all'
    box = box or Frame.new_product_box(kind, origin)
    local open_claims = open_open_claims and copy_open_claims(open_open_claims) or {}
    local external_waits = {}
    if open_open_claims == nil then
      for i = 1, #children do
        for j = 1, #(children[i].open_claims or {}) do
          open_claims[#open_claims + 1] = open_claim_with_lane(children[i].open_claims[j], box, i)
        end
        for j = 1, #(children[i].external_waits or {}) do
          external_waits[#external_waits + 1] = copy_wait(children[i].external_waits[j])
        end
      end
    end
    local eval = function(assignments)
      local merged = copy_assignments(internal_assignments)
      for k, v in pairs(assignments or {}) do merged[k] = v end
      local out = {}
      for i = 1, #children do
        local values = children[i]:evaluate(merged)
        out[i] = Util.pack(Util.unpack(values))
      end
      return Util.pack(out)
    end
    local values = nil
    local has_steps = #(kont or {}) > 0
    local has_waits = #external_waits > 0
    if #open_claims == 0 and not has_steps and not has_waits then values = eval({}) end
    return new_frame({
      kind = has_waits and 'pending' or (#open_claims == 0 and 'done' or 'open'),
      origin = origin,
      open_claims = open_claims,
      external_waits = external_waits,
      evidence = evidence,
      children = children,
      internal_assignments = internal_assignments,
      allow_internal = allow_internal == true,
      product_box = box,
      values = values,
      eval = eval,
      kont = kont,
    })
  end

  local function with_steps(frame, steps, evidence)
    return new_frame({
      kind = frame.kind,
      origin = frame.origin,
      open_claims = copy_open_claims(frame.open_claims),
      external_waits = copy_waits(frame.external_waits),
      evidence = evidence or frame.evidence,
      inner = frame.inner,
      children = frame.children,
      internal_assignments = frame.internal_assignments,
      allow_internal = frame.allow_internal,
      product_box = frame.product_box,
      values = frame.values,
      eval = frame.eval,
      kont = steps,
    })
  end

  function Frame.with_kont(frame, step)
    Frame.assert(frame, 'Frame.with_kont')
    local steps = copy_steps(frame.kont)
    steps[#steps + 1] = step
    return with_steps(frame, steps)
  end

  function Frame.mapped(frame, f)
    Frame.assert(frame, 'Frame.mapped')
    if type(f) ~= 'function' then error('Frame.mapped: expected function', 2) end
    if #(frame.open_claims or {}) ~= 0 or frame:has_deferred() or frame:is_pending() then
      return Frame.with_kont(frame, { tag = 'map', f = f })
    end
    local eval = function(assignments)
      local values = frame:evaluate(assignments)
      return Util.pack(f(Util.unpack(values)))
    end
    local values = eval({})
    return new_frame({
      kind = frame.kind,
      origin = Origin.child(frame.origin, 'map'),
      open_claims = copy_open_claims(frame.open_claims),
      external_waits = copy_waits(frame.external_waits),
      evidence = frame.evidence,
      inner = frame,
      values = values,
      eval = eval,
    })
  end

  function Frame.deferred_bind(frame, view, k, attempt)
    Frame.assert(frame, 'Frame.deferred_bind')
    if type(k) ~= 'function' then error('Frame.deferred_bind: expected continuation', 2) end
    return Frame.with_kont(frame, { tag = 'bind', view = view, k = k, attempt = attempt })
  end

  function Frame.with_evidence(frame, evidence)
    Frame.assert(frame, 'Frame.with_evidence')
    return with_steps(frame, copy_steps(frame.kont), evidence)
  end

  function Frame.is(x)
    return type(x) == 'table' and getmetatable(x) == Methods
  end

  function Frame.assert(x, where)
    if not Frame.is(x) then error((where or 'frame') .. ': expected Frame', 3) end
    return x
  end

  function Methods:is_pending()
    if self.kind == 'pending' or #(self.external_waits or {}) > 0 then return true end
    for i = 1, #(self.children or {}) do
      local child = self.children[i]
      if child.is_pending and child:is_pending() then return true end
    end
    return false
  end

  function Methods:is_deferred()
    return #(self.kont or {}) > 0
  end

  function Methods:has_deferred()
    if self:is_deferred() then return true end
    for i = 1, #(self.children or {}) do
      local child = self.children[i]
      if child.has_deferred and child:has_deferred() then return true end
    end
    return false
  end

  function Methods:is_fresh(_view)
    local ok, status = self.evidence.dependencies:fresh_status('frame dependencies stale')
    if ok then return true end
    return false, status
  end

  function Methods:probe(view)
    local ok, status = self:is_fresh(view)
    if not ok then return status end
    return Status.found(self)
  end

  function Methods:evaluate(assignments)
    return self.eval(assignments or {})
  end

  Frame.copy_steps = copy_steps


  Frame.copy_open_claim = copy_open_claim
  Frame.copy_open_claims = copy_open_claims
  Frame.copy_waits = copy_waits
end

-- from machine/frontier.lua
do
  local Op = require('et.op')
  Frontier = {}
  local FrontierMethods = {}
  FrontierMethods.__index = FrontierMethods

  local expand_op

  local function append_frames(dst, src)
    for i = 1, #src do dst[#dst + 1] = src[i] end
    return dst
  end

  local function frames_status(frames)
    return Status.found(frames)
  end

  local function expand_done(op, _view, evidence, _token, origin)
    return frames_status({ Frame.done(op.values, evidence, origin) })
  end

  local function expand_never(_op, _view, _evidence, _token)
    return frames_status({})
  end

  local function expand_access(op, view, evidence, token, origin)
    local e = Evidence.copy(evidence)
    local current_fragment = e.resources.by_resource[op.resource]
    local value_status = Link.claim(view, op.resource, current_fragment, { kind = 'access', request = op.request, origin = origin }, token)
    if not Status.is_found(value_status) then return value_status end
    local claim_result = value_status.value
    if claim_result.fragment ~= nil then
      Evidence.put_resource(e.resources, op.resource, claim_result.fragment)
    end
    if claim_result.dependencies then
      local ok, resource = e.dependencies:merge(claim_result.dependencies)
      if not ok then return Status.stale({ resource }, 'access dependencies disagree') end
    end
    e = Evidence.with_selected_occurrence(e, {
      kind = 'access',
      origin = origin,
      origin_id = Origin.key(origin),
      resource = op.resource,
      request = op.request,
      lane_path = origin.lane_path,
      decision_prefix = origin.decision_prefix,
    })
    return frames_status({ Frame.done(claim_result.values, e, origin) })
  end

  local function expand_open_claim(op, view, evidence, token, origin)
    local open_claim_status = Link.claim(view, op.resource, nil, { kind = 'open_claim', request = op.request, origin = origin }, token)
    if not Status.is_found(open_claim_status) then return open_claim_status end
    local open_claim_result = open_claim_status.value
    local open_claim = open_claim_result.open_claim
    local e = Evidence.copy(evidence)
    if open_claim.dependencies then
      local ok, resource = e.dependencies:merge(open_claim.dependencies)
      if not ok then return Status.stale({ resource }, 'open claim dependencies disagree') end
    end
    e = Evidence.with_selected_occurrence(e, {
      kind = 'open_claim',
      origin = origin,
      origin_id = Origin.key(origin),
      resource = op.resource,
      request = op.request,
      role = open_claim.role,
      open_claim_id = open_claim.id,
      lane_path = origin.lane_path,
      decision_prefix = origin.decision_prefix,
    })
    return frames_status({ Frame.open_claim(open_claim, e, origin) })
  end

  local function expand_await(op, view, evidence, token, origin)
    local awaited = Link.claim(view, op.resource, nil, { kind = 'await', request = op.request, origin = origin }, token)
    local e = Evidence.copy(evidence)
    if Status.is_found(awaited) then
      local result = awaited.value
      if result.dependencies then
        local ok, resource = e.dependencies:merge(result.dependencies)
        if not ok then return Status.stale({ resource }, 'external await dependencies disagree') end
      end
      e = Evidence.with_selected_occurrence(e, {
        kind = 'await', origin = origin, origin_id = Origin.key(origin),
        resource = op.resource, request = op.request,
        lane_path = origin.lane_path, decision_prefix = origin.decision_prefix,
      })
      return frames_status({ Frame.done(result.values or Util.pack(result.value), e, origin) })
    elseif awaited.tag == 'pending' then
      local wait = awaited.detail or {}
      if wait.dependencies then
        local ok, resource = e.dependencies:merge(wait.dependencies)
        if not ok then return Status.stale({ resource }, 'external wait dependencies disagree') end
      end
      e = Evidence.with_selected_occurrence(e, {
        kind = 'await_pending', origin = origin, origin_id = Origin.key(origin),
        resource = op.resource, request = op.request,
        lane_path = origin.lane_path, decision_prefix = origin.decision_prefix,
      })
      return frames_status({ Frame.pending(wait, e, origin) })
    end
    return awaited
  end

  local function expand_emit(op, _view, evidence, _token, origin)
    local e = Evidence.with_transaction_consequence(evidence, op.consequence)
    e = Evidence.with_selected_occurrence(e, {
      kind = 'emit', origin = origin, origin_id = Origin.key(origin),
      lane_path = origin.lane_path, decision_prefix = origin.decision_prefix,
    })
    return frames_status({ Frame.done(Util.pack(), e, origin) })
  end

  local function expand_map(op, view, evidence, token, origin, attempt)
    local left = expand_op(op.op, view, evidence, token, Origin.child(origin, 'map-subject'), attempt)
    if not Status.is_found(left) then return left end
    local out = {}
    for i = 1, #left.value do
      out[#out + 1] = Frame.mapped(left.value[i], op.f)
    end
    return frames_status(out)
  end

  local function expand_bind(op, view, evidence, token, origin, attempt)
    local left = expand_op(op.op, view, evidence, token, Origin.child(origin, 'bind-subject'), attempt)
    if not Status.is_found(left) then return left end
    local out = {}
    for i = 1, #left.value do
      local frame = left.value[i]
      if #(frame.open_claims or {}) ~= 0 or (frame.is_deferred and frame:is_deferred()) or (frame.is_pending and frame:is_pending()) then
        out[#out + 1] = Frame.deferred_bind(frame, view, op.k, attempt)
      else
        local ok_eval, vals = pcall(function() return frame:evaluate({}) end)
        if not ok_eval then return Status.fatal(vals) end
        local ok, next_op = pcall(function()
          return op.k(Util.unpack(vals))
        end)
        if not ok then return Status.fatal(next_op) end
        if not Op.is(next_op) then return Status.fatal('bind continuation did not return Op') end
        local next_frames = expand_op(next_op, view, frame.evidence, token, Origin.child(origin, 'bind-now'), attempt)
        if not Status.is_found(next_frames) then return next_frames end
        append_frames(out, next_frames.value)
      end
    end
    return frames_status(out)
  end

  local function expand_choice(op, view, evidence, token, origin, attempt)
    local out = {}
    local deferred
    local function collect(branch_status)
      if Status.is_found(branch_status) then
        append_frames(out, branch_status.value)
      elseif branch_status.tag == 'absent' or branch_status.tag == 'conflict' then
        -- Branch-local failure: the losing branch simply contributes no frames.
      elseif branch_status.tag == 'stale' then
        deferred = deferred or branch_status
      else
        deferred = deferred or branch_status
      end
    end
    collect(expand_op(op.left, view, evidence, token, Origin.decision(origin, 'choice', 'L'), attempt))
    collect(expand_op(op.right, view, evidence, token, Origin.decision(origin, 'choice', 'R'), attempt))
    if #out > 0 then return frames_status(out) end
    if deferred then return deferred end
    return frames_status({})
  end

  local function combinations(lists, i, acc, out)
    if i > #lists then
      out[#out + 1] = Util.copy_list(acc)
      return
    end
    for j = 1, #lists[i] do
      acc[i] = lists[i][j]
      combinations(lists, i + 1, acc, out)
    end
    acc[i] = nil
  end

  local function expand_product(op, view, evidence, token, allow_internal, origin, attempt)
    local lists = {}
    local base = Evidence.copy(evidence)
    local box = Frame.new_product_box(allow_internal and 'tensor' or 'all', origin)
    for i = 1, #(op.items or {}) do
      local child = op.items[i]
      Op.assert(child, 'product item')
      local indexed = Origin.index(origin, allow_internal and 'tensor' or 'all', i)
      local child_origin = Origin.lane(indexed, box, i)
      local child_frames = expand_op(child, view, base, token, child_origin, attempt)
      if Status.is_found(child_frames) then
        if #child_frames.value == 0 then return frames_status({}) end
        lists[i] = child_frames.value
      elseif child_frames.tag == 'absent' or child_frames.tag == 'conflict' then
        return frames_status({})
      else
        return child_frames
      end
    end
    if #lists == 0 then return frames_status({ Frame.done(Util.pack({}), base, origin) }) end

    local combos = {}
    combinations(lists, 1, {}, combos)
    local out = {}
    local deferred
    local saw_local_failure = false
    for i = 1, #combos do
      local combo = combos[i]
      local lane_contribution = Evidence.empty()
      local combo_ok = true
      for j = 1, #combo do
        local contribution = Evidence.project(base, combo[j].evidence, view, token)
        if not Status.is_found(contribution) then
          if contribution.tag == 'absent' or contribution.tag == 'conflict' then
            saw_local_failure = true
          else
            deferred = deferred or contribution
          end
          combo_ok = false
          break
        end
        local c = Evidence.coexist(lane_contribution, contribution.value, view, token)
        if Status.is_found(c) then
          lane_contribution = c.value
        elseif c.tag == 'absent' or c.tag == 'conflict' then
          saw_local_failure = true
          combo_ok = false
          break
        else
          deferred = deferred or c
          combo_ok = false
          break
        end
      end
      if combo_ok then
        local extended = Evidence.extend(base, lane_contribution, view, token)
        if Status.is_found(extended) then
          out[#out + 1] = Frame.product(combo, extended.value, {}, nil, allow_internal, origin, nil, box)
        elseif extended.tag == 'absent' or extended.tag == 'conflict' then
          saw_local_failure = true
        else
          deferred = deferred or extended
        end
      end
    end
    if #out > 0 then return frames_status(out) end
    if deferred then return deferred end
    if saw_local_failure then return frames_status({}) end
    return frames_status(out)
  end

  local function expand_or_else(op, view, evidence, token, origin, attempt)
    local out = {}
    local primary = expand_op(op.primary, view, evidence, token, Origin.child(origin, 'or_else:primary'), attempt)
    local primary_frames = {}
    if Status.is_found(primary) then
      primary_frames = primary.value
      append_frames(out, primary_frames)
    elseif primary.tag == 'absent' or primary.tag == 'conflict' then
      primary_frames = {}
    else
      return primary -- stale/budget/fatal are not absence.
    end

    local fallback = expand_op(op.fallback, view, evidence, token, Origin.child(origin, 'or_else:fallback'), attempt)
    if Status.is_found(fallback) then
      for i = 1, #fallback.value do
        local obligation = Absence.obligation({
          op = op.primary,
          evidence = Evidence.copy(evidence),
          origin = Origin.child(origin, 'or_else:absence'),
          snapshot_id = view.id,
        })
        local e = Evidence.with_absence_obligation(fallback.value[i].evidence, obligation)
        out[#out + 1] = Frame.with_evidence(fallback.value[i], e)
      end
    elseif fallback.tag == 'absent' or fallback.tag == 'conflict' then
      -- fallback contributes no frames
    elseif #primary_frames == 0 then
      return fallback
    end

    return frames_status(out)
  end


  local function expand_nack(op, _view, evidence, _token, origin, attempt)
    local ref = op.obligation
    if not Obligation.is(ref) then return Status.fatal('nack has invalid obligation ref') end
    local store = ref.store or (attempt and attempt.obligation_store) or Obligation.default_store()
    if not store:nack_enabled(ref) then return frames_status({}) end
    local e = Evidence.with_selected_occurrence(evidence, {
      kind = 'nack',
      origin = origin,
      origin_id = Origin.key(origin),
      obligation = ref,
      obligation_id = ref.id,
      lane_path = origin.lane_path,
      decision_prefix = origin.decision_prefix,
    })
    return frames_status({ Frame.done(Util.pack(true), e, origin) })
  end

  local function expand_guard(op, view, evidence, token, origin, attempt)
    if type(attempt) ~= 'table' then return Status.fatal('guard expansion requires RootAttempt') end
    local guard_origin = Origin.child(origin, 'guard')
    local forced = ExpansionMemo.force(attempt, 'guard', guard_origin, function()
      local guarded_op = op.f()
      if not Op.is(guarded_op) then error('guard callback did not return Op', 2) end
      return guarded_op
    end)
    if not Status.is_found(forced) then return forced end
    return expand_op(forced.value, view, evidence, token, Origin.child(origin, 'guard:body'), attempt)
  end

  local function expand_with_nack(op, view, evidence, token, origin, attempt)
    if type(attempt) ~= 'table' then return Status.fatal('with_nack expansion requires RootAttempt') end
    local ref_origin = Origin.child(origin, 'with_nack')
    local forced = ExpansionMemo.force(attempt, 'with_nack', ref_origin, function()
      local store = attempt.obligation_store or Obligation.default_store()
      local ref = store:ref(ref_origin, 'settlement')
      local nack = Op._nack(ref)
      local protected_op = op.f(nack)
      if not Op.is(protected_op) then error('with_nack callback did not return Op', 2) end
      return { ref = ref, nack = nack, protected_op = protected_op }
    end)
    if not Status.is_found(forced) then return forced end
    local entry = forced.value
    local ref = entry.ref
    local body_origin = Origin.with_parent_obligation(Origin.child(origin, 'with_nack:body'), ref.id)
    local body = expand_op(entry.protected_op, view, evidence, token, body_origin, attempt)
    if not Status.is_found(body) then return body end
    local out = {}
    for i = 1, #body.value do
      local frame = body.value[i]
      local e = Evidence.with_obligation_publication(frame.evidence, ref)
      if not Evidence.has_nack_observation(e, ref) then
        e = Evidence.with_selected_obligation(e, ref)
        e = Evidence.with_selected_occurrence(e, {
          kind = 'obligation_selected',
          origin = ref_origin,
          origin_id = Origin.key(ref_origin),
          obligation = ref,
          obligation_id = ref.id,
          lane_path = ref_origin.lane_path,
          decision_prefix = ref_origin.decision_prefix,
          parent_obligation = ref_origin.parent_obligation,
        })
      end
      out[#out + 1] = Frame.with_evidence(frame, e)
    end
    return frames_status(out)
  end

  local function expand_wrap(op, view, evidence, token, origin, attempt)
    local inner = expand_op(op.op, view, evidence, token, Origin.child(origin, 'wrap-subject'), attempt)
    if not Status.is_found(inner) then return inner end
    local out = {}
    for i = 1, #inner.value do
      local frame = inner.value[i]
      local e = Evidence.copy(frame.evidence)
      for j = 1, #(op.wrappers or {}) do
        e = Evidence.with_post_program(e, op.wrappers[j])
      end
      out[#out + 1] = Frame.with_evidence(frame, e)
    end
    return frames_status(out)
  end

  expand_op = function(op, view, evidence, token, origin, attempt)
    Phase.require(token, 'search')
    Op.assert(op, 'expand')
    View.assert(view, 'expand')
    evidence = Evidence.copy(evidence or Evidence.empty())
    origin = Origin.coerce(origin or 'op')
    if op.tag == 'always' then return expand_done(op, view, evidence, token, origin)
    elseif op.tag == 'never' then return expand_never(op, view, evidence, token)
    elseif op.tag == 'access' then return expand_access(op, view, evidence, token, origin)
    elseif op.tag == 'open_claim' then return expand_open_claim(op, view, evidence, token, origin)
    elseif op.tag == 'await' then return expand_await(op, view, evidence, token, origin)
    elseif op.tag == 'emit' then return expand_emit(op, view, evidence, token, origin)
    elseif op.tag == 'map' then return expand_map(op, view, evidence, token, origin, attempt)
    elseif op.tag == 'bind' then return expand_bind(op, view, evidence, token, origin, attempt)
    elseif op.tag == 'choice' then return expand_choice(op, view, evidence, token, origin, attempt)
    elseif op.tag == 'tensor' then return expand_product(op, view, evidence, token, true, origin, attempt)
    elseif op.tag == 'all' then return expand_product(op, view, evidence, token, false, origin, attempt)
    elseif op.tag == 'wrap' then return expand_wrap(op, view, evidence, token, origin, attempt)
    elseif op.tag == 'guard' then return expand_guard(op, view, evidence, token, origin, attempt)
    elseif op.tag == 'with_nack' then return expand_with_nack(op, view, evidence, token, origin, attempt)
    elseif op.tag == 'nack' then return expand_nack(op, view, evidence, token, origin, attempt)
    elseif op.tag == 'or_else' then return expand_or_else(op, view, evidence, token, origin, attempt)
    else return Status.fatal('unsupported Op tag: ' .. tostring(op.tag)) end
  end



  local function combine_child_evidence(children, view, token)
    local combined = Evidence.empty()
    for i = 1, #children do
      local c = Evidence.coexist(combined, children[i].evidence, view, token)
      if not Status.is_found(c) then return c end
      combined = c.value
    end
    return Status.found(combined)
  end

  local function append_remaining_steps(frames, steps)
    if #steps == 0 then return frames end
    local out = {}
    for i = 1, #frames do
      local f = frames[i]
      for j = 1, #steps do
        f = Frame.with_kont(f, steps[j])
      end
      out[#out + 1] = f
    end
    return out
  end

  local function continue_own_steps(frame, assignments, token, view)
    local ok_eval, vals = pcall(function()
      return frame:evaluate(assignments or {})
    end)
    if not ok_eval then return Status.fatal(vals) end

    local steps = Frame.copy_steps(frame.kont)
    local current_values = vals
    local current_evidence = Evidence.copy(frame.evidence)
    local i = 1
    while i <= #steps do
      local step = steps[i]
      if step.tag == 'map' then
        local ok, mapped = pcall(function() return Util.pack(step.f(Util.unpack(current_values))) end)
        if not ok then return Status.fatal(mapped) end
        current_values = mapped
        i = i + 1
      elseif step.tag == 'bind' then
        local ok_next, next_op = pcall(function()
          return step.k(Util.unpack(current_values))
        end)
        if not ok_next then return Status.fatal(next_op) end
        if not Op.is(next_op) then return Status.fatal('bind continuation did not return Op') end
        local bind_view = step.view or view
        local origin = Origin.index(frame.origin, 'kont', i)
        local expanded = expand_op(next_op, bind_view, current_evidence, token, origin, step.attempt)
        if not Status.is_found(expanded) then return expanded end
        local remaining = {}
        for j = i + 1, #steps do remaining[#remaining + 1] = steps[j] end
        return Status.found(append_remaining_steps(expanded.value, remaining))
      else
        return Status.fatal('unknown continuation step ' .. tostring(step.tag))
      end
    end
    return Status.found({ Frame.done(current_values, current_evidence, Origin.child(frame.origin, 'kont-done')) })
  end

  local function continue_after_match(frame, assignments, token, view)
    Phase.require(token, 'search')

    for i = 1, #(frame.children or {}) do
      local child = frame.children[i]
      if child.has_deferred and child:has_deferred() then
        local continued = continue_after_match(child, assignments, token, view)
        if not Status.is_found(continued) then return continued end
        local out = {}
        for j = 1, #continued.value do
          local children = Util.copy_list(frame.children)
          children[i] = continued.value[j]
          local combined = combine_child_evidence(children, view, token)
          if not Status.is_found(combined) then return combined end
          out[#out + 1] = Frame.product(children, combined.value, frame.internal_assignments, nil, frame.allow_internal, frame.origin, frame.kont, frame.product_box)
        end
        return Status.found(out)
      end
    end

    if not frame:is_deferred() then return Status.found({ frame }) end
    return continue_own_steps(frame, assignments, token, view)
  end

  function Frontier.continue_after_match(frame, assignments, token, view)
    Frame.assert(frame, 'Frontier.continue_after_match')
    return continue_after_match(frame, assignments, token, view)
  end

  local function obligation_publications(frames)
    local out = {}
    local seen = {}
    for i = 1, #(frames or {}) do
      local pubs = frames[i].evidence and frames[i].evidence.obligation_publications or {}
      for j = 1, #pubs do
        local ref = pubs[j]
        if ref and ref.id and not seen[ref.id] then
          seen[ref.id] = true
          out[#out + 1] = ref
        end
      end
    end
    return out
  end

  local function external_waits(frames)
    local out = {}
    for i = 1, #(frames or {}) do
      local waits = frames[i].external_waits or {}
      for j = 1, #waits do out[#out + 1] = waits[j] end
    end
    return out
  end

  local function combined_dependencies(frames)
    local deps = Dependency.new()
    for i = 1, #frames do
      local ok, resource = deps:merge(frames[i].evidence.dependencies)
      if not ok then return nil, resource end
    end
    return deps
  end

  function Frontier.expand(op, attempt, view, token)
    Phase.require(token, 'search')
    if type(attempt) ~= 'table' then return Status.fatal('Frontier.expand requires attempt table') end
    View.assert(view, 'Frontier.expand')
    local ok, result = pcall(function()
      local frames = expand_op(op, view, Evidence.empty(), token, Origin.root(attempt.id), attempt)
      if not Status.is_found(frames) then return frames end
      local deps, resource = combined_dependencies(frames.value)
      if not deps then return Status.stale({ resource }, 'frontier frame dependencies disagree') end
      return Status.found(setmetatable({
        op = op,
        attempt = attempt,
        view = view,
        view_id = view.id,
        dependencies = deps, -- frontier certificate dependencies; proof search may inspect frames only while fresh.
        frames = frames.value,
        obligation_publications = obligation_publications(frames.value),
        external_waits = external_waits(frames.value),
      }, FrontierMethods))
    end)
    if not ok then return Status.fatal(result) end
    return result
  end

  function Frontier.expand_in_search(op, attempt, view)
    return Phase.with('search', function(token)
      return Frontier.expand(op, attempt, view, token)
    end)
  end

  function Frontier.is(x)
    return type(x) == 'table' and getmetatable(x) == FrontierMethods
  end

  function Frontier.assert(x, where)
    if not Frontier.is(x) then error((where or 'frontier') .. ': expected Frontier', 3) end
    return x
  end

  function FrontierMethods:stale_status(view)
    if view and view.id ~= self.view_id then
      return Status.stale({}, 'frontier belongs to a different view')
    end
    local stale = self.dependencies:stale_resources()
    if #stale > 0 then return Status.stale(stale, 'frontier dependencies stale') end
    return nil
  end

  function FrontierMethods:is_fresh(view)
    if view and view.id ~= self.view_id then return false end
    return self.dependencies:is_fresh()
  end

  function FrontierMethods:probe(view, token)
    Phase.require(token, 'search')
    View.assert(view, 'Frontier.probe')
    local stale = self:stale_status(view)
    if stale then return stale end
    local fresh = {}
    local pending = {}
    for i = 1, #self.frames do
      local probed = self.frames[i]:probe(view)
      if Status.is_found(probed) then
        if probed.value.is_pending and probed.value:is_pending() then
          for j = 1, #(probed.value.external_waits or {}) do pending[#pending + 1] = probed.value.external_waits[j] end
        else
          fresh[#fresh + 1] = probed.value
        end
      elseif probed.tag == 'stale' or probed.tag == 'fatal' or probed.tag == 'pending' then
        return probed
      end
    end
    if #fresh > 0 then return Status.found(fresh) end
    if #pending > 0 or #(self.external_waits or {}) > 0 then
      return Status.pending('frontier has pending external waits', { waits = #pending > 0 and pending or self.external_waits })
    end
    return Status.absent('frontier has no frames')
  end

  function FrontierMethods:refresh(view, token)
    Phase.require(token, 'search')
    return Frontier.expand(self.op, self.attempt, view, token)
  end

  Frontier.expand_op = expand_op
  Frontier.new_evidence = Evidence.empty
  Frontier.copy_evidence = Evidence.copy
  Frontier.frame_done = Frame.done
end

return {
  Origin = Origin,
  Dependency = Dependency,
  Consequence = Consequence,
  View = View,
  Obligation = Obligation,
  Absence = Absence,
  Memo = ExpansionMemo,
  Evidence = Evidence,
  Frame = Frame,
  Frontier = Frontier,
  expand = Frontier.expand,
  continue_after_match = Frontier.continue_after_match,
}
