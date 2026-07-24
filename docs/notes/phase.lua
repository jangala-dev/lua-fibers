-- Phase: prototype rhythmic lifetime boundary.
--
-- A Phase cycle is a small compound over Scope.  Each named phase has a Scope
-- interval.  Cross-phase movement is explicit:
--   * carry(label) permits custody movement
--   * borrow(label) permits authority borrowing
--   * fact(label) permits fact propagation
-- Labels are declared on edges and supplied at the crossing site.  Phase does
-- not infer labels from records or metadata.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Scope = require('fibers.scope')
local Protected = require('fibers.internal.protected')
local Keyed = require('fibers.resource.keyed')

local Phase = {}
Phase.__index = Phase

local Edge = {}
Edge.__index = Edge

local next_id = 0

local function is_scope(x)
  return type(x) == 'table' and x._fibers_scope == true
end

local function pack(...)
  return { n = select('#', ...), ... }
end
local unpack_ = table.unpack or unpack

local function crossing_label(opts, method)
  if type(opts) == 'string' then
    return opts
  end
  if type(opts) == 'table' and opts.label ~= nil then
    return opts.label
  end
  error(method .. ' requires an explicit crossing label', 3)
end

local function set_has(t, label)
  return t['*'] == true or t[label] == true
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
    facts = {},
    edges = {},
    _fibers_id = id,
  }, Phase)
end

function Phase:phase(name, opts)
  if type(name) ~= 'string' then
    error('Phase:phase expects a name', 2)
  end
  if not self.declared[name] then
    self.order[#self.order + 1] = name
  end
  self.declared[name] = opts or true
  return self
end

function Phase:edge(from_name, to_name, opts)
  if type(from_name) ~= 'string' or type(to_name) ~= 'string' then
    error('Phase:edge expects phase names', 2)
  end
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
    fact_labels = {},
    fact_set = {},
    opts = opts or {},
  }, Edge)
  self.edges[from_name] = self.edges[from_name] or {}
  self.edges[from_name][to_name] = edge
  return edge
end

function Edge:carry(label)
  if label == nil then
    label = '*'
  end
  if type(label) ~= 'string' then
    error('Edge:carry expects a label', 2)
  end
  self.carry_labels[#self.carry_labels + 1] = label
  self.carry_set[label] = true
  return self
end

function Edge:borrow(label)
  if label == nil then
    label = '*'
  end
  if type(label) ~= 'string' then
    error('Edge:borrow expects a label', 2)
  end
  self.borrow_labels[#self.borrow_labels + 1] = label
  self.borrow_set[label] = true
  return self
end

function Edge:fact(label)
  if label == nil then
    label = '*'
  end
  if type(label) ~= 'string' then
    error('Edge:fact expects a label', 2)
  end
  self.fact_labels[#self.fact_labels + 1] = label
  self.fact_set[label] = true
  return self
end

function Edge:done()
  return self.phase
end

function Phase:scope(name, opts)
  if type(name) ~= 'string' then
    error('Phase:scope expects a phase name', 2)
  end
  self:phase(name)
  local scope = self.scopes[name]
  if scope then
    return scope
  end
  opts = opts or {}
  local rt = opts.runtime or self.runtime or Runtime.current()
  local parent = opts.parent
  if parent == nil then
    parent = self.parent or (Runtime.current_scope and Runtime.current_scope())
  end
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

function Phase:facts_for(name)
  if type(name) ~= 'string' then
    error('Phase:facts_for expects a phase name', 2)
  end
  self:phase(name)
  local facts = self.facts[name]
  if not facts then
    facts = Keyed.new({}, (self.name or 'phase') .. ':' .. name .. ':facts')
    self.facts[name] = facts
  end
  return facts
end

function Phase:put_fact_op(name, label, value)
  if type(label) ~= 'string' then
    error('Phase:put_fact_op expects a fact label', 2)
  end
  return self:facts_for(name):put_op(label, value)
end

function Phase:get_fact_op(name, label)
  if type(label) ~= 'string' then
    error('Phase:get_fact_op expects a fact label', 2)
  end
  return self:facts_for(name):get_op(label)
end

function Phase:peek_fact_op(name, label)
  if type(label) ~= 'string' then
    error('Phase:peek_fact_op expects a fact label', 2)
  end
  return self:facts_for(name):peek_op(label)
end

function Phase:allows_move_op(_item, from_name, to_name, opts)
  local edge = edge_for(self, from_name, to_name)
  if not edge then
    return Op.always(false, nil)
  end
  local label = crossing_label(opts, 'Phase:allows_move_op')
  return Op.always(set_has(edge.carry_set, label), label)
end

function Phase:allows_borrow_op(_item, from_name, to_name, opts)
  local edge = edge_for(self, from_name, to_name)
  if not edge then
    return Op.always(false, nil)
  end
  local label = crossing_label(opts, 'Phase:allows_borrow_op')
  return Op.always(set_has(edge.borrow_set, label), label)
end

function Phase:allows_fact_op(label, from_name, to_name)
  if type(label) ~= 'string' then
    error('Phase:allows_fact_op expects a fact label', 2)
  end
  local edge = edge_for(self, from_name, to_name)
  if not edge then
    return Op.always(false, label)
  end
  return Op.always(set_has(edge.fact_set, label), label)
end

function Phase:move_op(item, from_name, to_name, opts)
  return self:allows_move_op(item, from_name, to_name, opts):and_then(function(ok)
    if not ok then
      return Op.never()
    end
    return self:scope(from_name):move_op(item, self:scope(to_name))
  end)
end

function Phase:borrow_op(from_name, item, to_name, rights, opts)
  local label = crossing_label(opts, 'Phase:borrow_op')
  local borrow_opts = type(opts) == 'table' and opts or { label = label }
  return self:allows_borrow_op(item, from_name, to_name, label):and_then(function(ok)
    if not ok then
      return Op.never()
    end
    borrow_opts.borrower = self:scope(to_name)
    return self:scope(from_name):borrow_op(item, rights, borrow_opts)
  end)
end

function Phase:carry_fact_op(label, from_name, to_name)
  return self:allows_fact_op(label, from_name, to_name):and_then(function(ok)
    if not ok then
      return Op.never()
    end
    return self:facts_for(from_name):get_op(label):and_then(function(value)
      return self:facts_for(to_name):put_op(label, value):map(function()
        return value
      end)
    end)
  end)
end

function Phase:run(name, fn, opts)
  if type(fn) ~= 'function' then
    error('Phase:run expects a function', 2)
  end
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
  self.facts[name] = nil
  if not r[1] then
    error(r[2], 0)
  end
  return unpack_(r, 2, r.n)
end

Phase.Edge = Edge
return Phase
