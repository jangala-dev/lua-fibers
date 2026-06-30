-- Phase: prototype rhythmic lifetime boundary.
--
-- A Phase cycle is a small compound over Scope.  Each named phase has a Scope
-- interval.  Cross-phase custody movement and authority borrowing must be
-- declared on an edge before they can commit.  This keeps phase order from
-- being mere scheduler order: values cross phase boundaries only through named
-- obligations or authority grants.

local Op = require('fibers.atoms.op')
local Runtime = require('fibers.kernel.runtime')
local Scope = require('fibers.scope')
local Protected = require('fibers.kernel.protected')

local Phase = {}
Phase.__index = Phase

local Edge = {}
Edge.__index = Edge

local next_id = 0

local function is_scope(x) return type(x) == 'table' and x._fibers_scope == true end

local function pack(...) return { n = select('#', ...), ... } end
local unpack_ = table.unpack or unpack

local function item_kind(item)
  return item and (item._fibers_obligation_kind or item._fibers_scope_kind or item._fibers_kind_name or item._fibers_id and 'obligation' or nil)
end

local function edge_label_from_record(item, record, opts)
  opts = opts or {}
  if type(opts) == 'string' then return opts end
  if opts.label ~= nil then return opts.label end
  if record then
    if record.role ~= nil then return record.role end
    if type(record.meta) == 'table' then
      if record.meta.label ~= nil then return record.meta.label end
      if record.meta.kind ~= nil then return record.meta.kind end
      if record.meta.role ~= nil then return record.meta.role end
    end
  end
  return item_kind(item)
end

local function set_has(t, label)
  if not t then return false end
  return t['*'] == true or (label ~= nil and t[label] == true)
end

local function edge_for(self, from_name, to_name)
  return self.edges[from_name] and self.edges[from_name][to_name] or nil
end

function Phase.new(name, opts)
  opts = opts or {}
  next_id = next_id + 1
  local id = 'phase-' .. tostring(next_id)
  return setmetatable({
    name = name or id,
    runtime = opts.runtime,
    parent = opts.parent,
    policy = opts.policy,
    order = {},
    declared = {},
    scopes = {},
    edges = {},
    _fibers_id = id,
    _fibers_phase = true,
  }, Phase)
end

function Phase:phase(name, opts)
  if type(name) ~= 'string' then error('Phase:phase expects a name', 2) end
  if not self.declared[name] then self.order[#self.order + 1] = name end
  self.declared[name] = opts or true
  return self
end

function Phase:edge(from_name, to_name, opts)
  if type(from_name) ~= 'string' or type(to_name) ~= 'string' then error('Phase:edge expects phase names', 2) end
  self:phase(from_name)
  self:phase(to_name)
  local edge = setmetatable({
    phase = self,
    from = from_name,
    to = to_name,
    carry_labels = {},
    carry_set = {},
    borrow_labels = {},
    borrow_set = {},
    opts = opts or {},
  }, Edge)
  self.edges[from_name] = self.edges[from_name] or {}
  self.edges[from_name][to_name] = edge
  return edge
end

function Edge:carry(label)
  if label == nil then label = '*' end
  if type(label) ~= 'string' then error('Edge:carry expects a label', 2) end
  self.carry_labels[#self.carry_labels + 1] = label
  self.carry_set[label] = true
  return self
end

function Edge:borrow(label)
  if label == nil then label = '*' end
  if type(label) ~= 'string' then error('Edge:borrow expects a label', 2) end
  self.borrow_labels[#self.borrow_labels + 1] = label
  self.borrow_set[label] = true
  return self
end

function Edge:done()
  return self.phase
end

function Phase:scope(name, opts)
  if type(name) ~= 'string' then error('Phase:scope expects a phase name', 2) end
  self:phase(name)
  local scope = self.scopes[name]
  if scope then return scope end
  opts = opts or {}
  local rt = opts.runtime or self.runtime or Runtime.current()
  local parent = opts.parent
  if parent == nil then parent = self.parent or (Runtime.current_scope and Runtime.current_scope()) end
  scope = Scope.new((self.name or 'phase') .. ':' .. name, {
    runtime = rt,
    parent = parent,
    policy = opts.policy or self.policy or (is_scope(parent) and parent.policy or nil),
  })
  scope.phase_cycle = self
  scope.phase_name = name
  self.scopes[name] = scope
  return scope
end

function Phase:allows_move_op(item, from_name, to_name, opts)
  local edge = edge_for(self, from_name, to_name)
  if not edge then return Op.always(false, nil) end
  return self:scope(from_name):record_op(item):map(function(record)
    local label = edge_label_from_record(item, record, opts)
    return set_has(edge.carry_set, label), label
  end)
end

function Phase:allows_borrow_op(item, from_name, to_name, opts)
  local edge = edge_for(self, from_name, to_name)
  if not edge then return Op.always(false, nil) end
  return self:scope(from_name):record_op(item):map(function(record)
    local label = edge_label_from_record(item, record, opts)
    return set_has(edge.borrow_set, label), label
  end)
end

function Phase:move_op(item, from_name, to_name, opts)
  return self:allows_move_op(item, from_name, to_name, opts):and_then(function(ok)
    if not ok then return Op.never() end
    return self:scope(from_name):move_op(item, self:scope(to_name))
  end)
end

function Phase:borrow_op(from_name, item, to_name, rights, opts)
  opts = opts or {}
  return self:allows_borrow_op(item, from_name, to_name, opts):and_then(function(ok)
    if not ok then return Op.never() end
    opts.borrower = self:scope(to_name)
    return self:scope(from_name):borrow_op(item, rights, opts)
  end)
end

function Phase:run(name, fn, opts)
  if type(fn) ~= 'function' then error('Phase:run expects a function', 2) end
  opts = opts or {}
  local scope = self:scope(name, opts)
  local r = pack(Protected.pcall(function()
    return scope:run(function(s)
      return fn(s, self)
    end)
  end))
  -- A phase scope is one interval.  After it has run, a later invocation starts
  -- a fresh interval; obligations intentionally carried forward must already
  -- have crossed through a declared edge to another open phase scope.
  self.scopes[name] = nil
  if not r[1] then error(r[2], 0) end
  return unpack_(r, 2, r.n)
end

function Phase:open_scopes()
  local out = {}
  for name, scope in pairs(self.scopes) do out[#out + 1] = { name = name, scope = scope } end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

Phase.Edge = Edge
return Phase
