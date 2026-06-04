-- Public resource/machine conduit: Protocol.Link.
--
-- This is the only primitive-resource protocol surface.  Resources implement the
-- six semantic verbs snapshot / initial / claim / merge / prepare / commit;
-- the machine interprets their classified results.

local Kernel = require('et.kernel')
local Status = Kernel.Status
local Util = Kernel.Util
local Phase = Kernel.Phase
local Link

local function copy_box_path(xs)
  local out = {}
  for i = 1, #(xs or {}) do
    local x = xs[i]
    out[i] = { box = x.box, lane = x.lane, kind = x.kind, allow_internal = x.allow_internal }
  end
  return out
end

local function origin_key(origin)
  if type(origin) == 'table' then
    if type(origin.key) == 'function' then return origin:key() end
    if origin.origin_id ~= nil then return origin.origin_id end
  end
  return tostring(origin)
end

local function origin_child(origin, label)
  if type(origin) == 'table' and type(origin.child) == 'function' then
    return origin:child(label)
  end
  return nil
end

local function origin_boxes(origin)
  if type(origin) == 'table' then return copy_box_path(origin.lane_path or {}) end
  return {}
end

local DependencyReport = {}
local DependencyMethods = {}
DependencyMethods.__index = DependencyMethods

function DependencyReport.new()
  return setmetatable({ order = {}, by_resource = {} }, DependencyMethods)
end

function DependencyMethods:add(resource, version)
  local old = self.by_resource[resource]
  if old == nil then
    self.order[#self.order + 1] = resource
    self.by_resource[resource] = version
    return true
  end
  return old == version
end

function DependencyMethods:merge(other)
  for i = 1, #(other and other.order or {}) do
    local resource = other.order[i]
    if not self:add(resource, other.by_resource[resource]) then return false, resource end
  end
  return true
end

function DependencyMethods:stale_resources()
  local stale = {}
  for i = 1, #self.order do
    local resource = self.order[i]
    local expected = self.by_resource[resource]
    local current
    if type(resource.current_version) == 'function' then current = resource:current_version() else current = resource.version end
    if current ~= expected then stale[#stale + 1] = resource end
  end
  return stale
end

function DependencyMethods:is_fresh()
  return #self:stale_resources() == 0
end

function DependencyMethods:copy()
  local out = DependencyReport.new()
  out:merge(self)
  return out
end

-- Protocol link: the narrow machine/primitive message boundary.
--
-- This is now the only machine-facing primitive interface.  A primitive is any
-- marked participant that can answer these six messages:
--
--   snapshot / initial / claim / merge / prepare / commit
--
-- Wait watching is runtime/host integration; Link stays focused on the six semantic verbs.
do
  Link = {}

  local next_open_claim_id = 0

  function Link.next_open_claim_id()
    next_open_claim_id = next_open_claim_id + 1
    return 'open-claim-' .. tostring(next_open_claim_id)
  end

  function Link.mark(resource)
    if type(resource) ~= 'table' then return resource end
    resource.__et_resource = true
    resource.__et_link_resource = true
    return resource
  end

  function Link.is(resource)
    return type(resource) == 'table' and resource.__et_resource == true and resource.__et_link_resource == true
  end

  local function link_error(where, msg)
    return Status.fatal('Protocol.Link.' .. tostring(where) .. ': ' .. tostring(msg))
  end

  local function status_or_found(x)
    if type(x) == 'table' and type(x.tag) == 'string' then return x end
    return Status.found(x)
  end

  local function call(resource, method, ...)
    if type(resource) ~= 'table' then return link_error(method, 'resource must be table') end
    local fn = resource[method]
    if type(fn) ~= 'function' then return link_error(method, 'resource does not implement ' .. method) end
    local ok, r = pcall(function(...) return fn(resource, ...) end, ...)
    if not ok then return Status.fatal(r) end
    return status_or_found(r)
  end

  local function require_snapshot(view, resource)
    if view ~= nil and type(view.of) == 'function' then return view:of(resource) end
    return Link.snapshot(nil, resource)
  end

  local function ensure_dependency(deps, resource, version, why)
    deps = deps or DependencyReport.new()
    if type(deps) ~= 'table' or type(deps.add) ~= 'function' or type(deps.merge) ~= 'function' then
      return nil, Status.fatal(why .. ' dependencies must be Dependency')
    end
    if not deps:add(resource, version) then
      return nil, Status.stale({ resource }, why .. ' dependency version disagreement')
    end
    return deps, nil
  end

  local function normalise_values(result)
    if result.values == nil then result.values = Util.pack(result.value) end
    return result
  end

  function Link.snapshot(view, resource)
    if view ~= nil and type(view.of) == 'function' then
      return view:of(resource)
    end
    if type(resource) ~= 'table' or type(resource.snapshot) ~= 'function' then
      return link_error('snapshot', 'resource does not implement snapshot')
    end
    local ok, snap = pcall(function() return resource:snapshot() end)
    if not ok then return Status.fatal(snap) end
    if type(snap) ~= 'table' then return link_error('snapshot', 'resource snapshot must be table') end
    if snap.resource == nil then snap.resource = resource end
    if snap.version == nil then return link_error('snapshot', 'resource snapshot missing version') end
    return Status.found(snap)
  end

  function Link.initial(view, resource, snapshot, token)
    if token ~= nil then Phase.require(token, 'search') end
    local snap = snapshot
    if snap == nil then
      local snap_status = require_snapshot(view, resource)
      if not Status.is_found(snap_status) then return snap_status end
      snap = snap_status.value
    end
    return call(resource, 'initial', snap, token)
  end

  function Link.claim(view, resource, fragment, claim, token)
    Phase.require(token, 'search')
    claim = claim or {}
    claim.kind = claim.kind or 'access'

    local snap_status = require_snapshot(view, resource)
    if not Status.is_found(snap_status) then return snap_status end
    local snap = snap_status.value

    local active_fragment = fragment
    if active_fragment == nil and claim.kind == 'access' then
      local initial_status = Link.initial(view, resource, snap, token)
      if not Status.is_found(initial_status) then return initial_status end
      active_fragment = initial_status.value
    end

    local status = call(resource, 'claim', snap, active_fragment, claim, token)

    local why = 'claim'
    if claim.kind == 'await' then why = 'external await' end
    if claim.kind == 'open_claim' then why = 'open claim' end

    if Status.is_found(status) then
      local result = status.value or {}
      if type(result) ~= 'table' then result = { value = result } end
      result.kind = result.kind or claim.kind
      result.resource = result.resource or resource

      if claim.kind == 'open_claim' then
        local open_claim = result.open_claim or result
        if type(open_claim) ~= 'table' then return link_error('claim', 'open claim must return claim table') end
        open_claim.id = open_claim.id or Link.next_open_claim_id()
        open_claim.resource = open_claim.resource or resource
        open_claim.origin = open_claim.origin or claim.origin
        if open_claim.origin_id == nil and open_claim.origin ~= nil then open_claim.origin_id = origin_key(open_claim.origin) end
        if open_claim.box_path == nil then open_claim.box_path = origin_boxes(claim.origin) end
        local deps, err = ensure_dependency(open_claim.dependencies, resource, snap.version, why)
        if err then return err end
        open_claim.dependencies = deps
        result.open_claim = open_claim
        result.dependencies = open_claim.dependencies
        return Status.found(result)
      end

      local deps, err = ensure_dependency(result.dependencies, resource, snap.version, why)
      if err then return err end
      result.dependencies = deps
      normalise_values(result)
      return Status.found(result)
    end

    if status.tag == 'pending' and claim.kind == 'await' then
      local wait = status.detail or status.wait or status.value or {}
      if type(wait) ~= 'table' then wait = { value = wait } end
      wait.resource = wait.resource or resource
      wait.request = wait.request or claim.request or claim.payload or claim
      wait.origin = wait.origin or claim.origin
      local deps, err = ensure_dependency(wait.dependencies, resource, snap.version, 'external wait')
      if err then return err end
      wait.dependencies = deps
      return Status.pending(status.reason or 'external wait pending', wait)
    end

    return status
  end

  function Link.merge(view, resource, request, token)
    Phase.require(token, 'search')
    if type(request) ~= 'table' then return link_error('merge', 'merge request must be table') end
    request.fragments = request.fragments or {}

    local snap_status = require_snapshot(view, resource)
    if not Status.is_found(snap_status) then return snap_status end
    local snap = snap_status.value
    request.snapshot = request.snapshot or snap

    local status = call(resource, 'merge', snap, request, token)
    if not Status.is_found(status) then return status end

    local result = status.value
    if request.kind == 'complete' then
      if type(result) ~= 'table' then return link_error('merge', 'complete merge must return completion list') end
      return status
    end

    if type(result) == 'table' and result.fragment ~= nil then return status end
    return Status.found({ fragment = result })
  end

  function Link.prepare(resource, fragment, token)
    Phase.require(token, 'prepare')
    local status = call(resource, 'prepare', fragment, token)
    if not Status.is_found(status) then return status end
    local prepared = status.value
    if type(prepared) ~= 'table' then return link_error('prepare', 'prepared value must be table') end
    prepared.resource = prepared.resource or resource
    if prepared.apply == nil and type(resource.commit) == 'function' then
      prepared.apply = function(commit_token)
        Phase.require(commit_token, 'commit')
        return resource:commit(prepared, commit_token)
      end
    end
    return Status.found(prepared)
  end

  local function commit_success_or_fatal(where, r)
    if r == nil then return Status.found(true) end
    if type(r) == 'table' and type(r.tag) == 'string' then
      if Status.is_found(r) and (r.value == nil or r.value == true) then return Status.found(true) end
      if Status.is_found(r) then return Status.fatal(where .. ' returned found(false/non-true)', r) end
      return Status.fatal(where .. ' returned non-success status', r)
    end
    if r == true then return Status.found(true) end
    return Status.fatal(where .. ' returned invalid non-success value', r)
  end

  function Link.commit(prepared, token)
    Phase.require(token, 'commit')
    if type(prepared) ~= 'table' then return link_error('commit', 'prepared commit must be table') end
    if type(prepared.apply) == 'function' then
      local r = prepared.apply(token)
      return commit_success_or_fatal('Protocol.Link.commit: prepared apply', r)
    end
    local resource = prepared.resource
    if type(resource) == 'table' and type(resource.commit) == 'function' then
      local r = call(resource, 'commit', prepared, token)
      return commit_success_or_fatal('Protocol.Link.commit: resource commit', r)
    end
    return link_error('commit', 'prepared commit missing apply(commit_token)')
  end

end

local LinkResource = {}

local ContextMethods = {}
ContextMethods.__index = ContextMethods

local function is_status(x)
  return type(x) == 'table' and type(x.tag) == 'string'
end

local function status_or_found(x)
  if is_status(x) then return x end
  return Status.found(x)
end

local function new_context(kind, resource, snapshot, fragment, token, origin, request)
  return setmetatable({
    kind = kind,
    resource = resource,
    snapshot = snapshot,
    fragment = fragment,
    token = token,
    origin = origin,
    request = request,
  }, ContextMethods)
end

function ContextMethods:self()
  return self.resource
end

function ContextMethods:version(resource)
  resource = resource or self.resource
  if self.snapshot and self.snapshot.resource == resource and self.snapshot.version ~= nil then
    return self.snapshot.version
  end
  if type(resource.current_version) == 'function' then return resource:current_version() end
  return resource.version
end

function ContextMethods:values(...)
  return Util.pack(...)
end

function ContextMethods:found(value)
  return Status.found(value)
end

function ContextMethods:accept(fragment, ...)
  return Status.found({ values = Util.pack(...), fragment = fragment })
end

function ContextMethods:complete(...)
  return Status.found({ values = Util.pack(...), fragment = self.fragment })
end

function ContextMethods:ready(...)
  return Status.found({ values = Util.pack(...) })
end

function ContextMethods:no_match(reason, detail)
  return Status.absent(reason or 'open claims do not complete', detail)
end

function ContextMethods:open_claim(fields)
  fields = fields or {}
  local origin = self.origin
  local role = fields.role or fields.tag or fields.kind or 'claim'
  local open_claim_origin = fields.origin
  if open_claim_origin == nil and origin ~= nil then
    open_claim_origin = origin_child(origin, 'open:' .. tostring(role))
  end
  local out = {
    id = fields.id or Link.next_open_claim_id(),
    resource = fields.resource or self.resource,
    role = role,
    request = fields.request or self.request,
    values = fields.values or Util.pack(),
    origin = open_claim_origin,
    origin_id = fields.origin_id or (open_claim_origin and origin_key(open_claim_origin) or nil),
    box_path = fields.box_path or origin_boxes(origin),
    dependencies = fields.dependencies,
  }
  for k, v in pairs(fields) do
    if out[k] == nil then out[k] = v end
  end
  return Status.found({ open_claim = out })
end

function ContextMethods:match(fields)
  fields = fields or {}
  fields.tag = fields.tag or 'claim_completion'
  fields.resource = fields.resource or self.resource
  return fields
end

function ContextMethods:absent(reason, detail)
  return Status.absent(reason, detail)
end

function ContextMethods:conflict(reason, detail)
  return Status.conflict(reason, detail)
end

function ContextMethods:stale(resources, reason, detail)
  if resources == nil then resources = { self.resource } end
  return Status.stale(resources, reason, detail)
end

function ContextMethods:fatal(reason, detail)
  return Status.fatal(reason, detail)
end

function ContextMethods:pending(reason, detail)
  return Status.pending(reason, detail)
end

function ContextMethods:dependencies()
  return DependencyReport.new()
end

function ContextMethods:dependency_on(resource, version)
  local deps = DependencyReport.new()
  deps:add(resource or self.resource, version or self:version(resource or self.resource))
  return deps
end

function ContextMethods:pending_on(resource, version, reason, detail)
  local wait = detail or {}
  wait.resource = wait.resource or (resource or self.resource)
  wait.request = wait.request or self.request
  wait.origin = wait.origin or self.origin
  wait.dependencies = wait.dependencies or self:dependency_on(resource or self.resource, version)
  return Status.pending(reason or 'pending', wait)
end

function ContextMethods:pending_on_self(reason, detail)
  return self:pending_on(self.resource, self:version(self.resource), reason, detail)
end

function ContextMethods:effect(effect)
  return Util.copy_descriptor(effect)
end

function ContextMethods:prepared(fields)
  return Status.found(fields or {})
end

local function require_function(spec, key)
  local fn = spec[key]
  if type(fn) ~= 'function' then
    error('Protocol.Link.resource: missing ' .. tostring(key) .. ' function', 3)
  end
  return fn
end

function LinkResource.define(spec)
  if type(spec) ~= 'table' then error('Protocol.Link.resource: expected spec table', 2) end
  local name = spec.name or 'link-resource'
  local snapshot_fn = require_function(spec, 'snapshot')
  local initial_fn = require_function(spec, 'initial')
  local claim_fn = require_function(spec, 'claim')
  local merge_fn = require_function(spec, 'merge')
  local prepare_fn = require_function(spec, 'prepare')
  local commit_fn = spec.commit

  local Class = {}
  Class.__index = Class
  Class.__et_link_resource_class = true
  Class.__et_link_resource_name = name

  function Class.new(...)
    local self = setmetatable({
      __et_link_resource = true,
      __et_resource = true,
      link_name = name,
    }, Class)
    if type(spec.construct) == 'function' then
      spec.construct(self, ...)
    else
      local state = type(spec.state) == 'function' and spec.state(...) or {}
      if type(state) == 'table' then
        for k, v in pairs(state) do self[k] = v end
      elseif state ~= nil then
        self.state = state
      end
    end
    return Link.mark(self)
  end

  function Class:current_version()
    if type(spec.current_version) == 'function' then return spec.current_version(self) end
    return self.version
  end

  function Class:snapshot()
    return snapshot_fn(self)
  end

  function Class:initial(snap, token)
    local ctx = new_context('initial', self, snap, nil, token)
    return status_or_found(initial_fn(self, snap, ctx))
  end

  function Class:claim(snap, fragment, claim, token)
    claim = claim or {}
    local ctx = new_context('claim', self, snap, fragment, token, claim.origin, claim.request or claim.payload or claim)
    return status_or_found(claim_fn(self, snap, fragment, claim, ctx))
  end

  function Class:merge(snap, request, token)
    request = request or {}
    local ctx = new_context('merge', self, snap, request.base, token)
    return status_or_found(merge_fn(self, snap, request, ctx))
  end

  function Class:prepare(fragment, token)
    local ctx = new_context('prepare', self, nil, fragment, token)
    return status_or_found(prepare_fn(self, fragment, ctx))
  end

  function Class:commit(prepared, token)
    if type(commit_fn) == 'function' then
      local ctx = new_context('commit', self, nil, prepared and prepared.fragment, token)
      return status_or_found(commit_fn(self, prepared, ctx))
    end
    return Status.found(true)
  end


  if type(spec.methods) == 'table' then
    for k, v in pairs(spec.methods) do Class[k] = v end
  end

  return Class
end

LinkResource.Context = ContextMethods
Link.resource = LinkResource.define
Link.Context = ContextMethods

return Link
