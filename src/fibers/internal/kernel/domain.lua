-- Incremental blocked-demand indexing and lazy domain alternatives.
--
-- Demands are registered as strands block and removed as they resume.  The
-- index shares interned dependency atoms and the dense Bucket implementation
-- used by pending-request indexing.  Opening a domain does not construct a
-- complete pair or transition frontier.

local IR = require('fibers.internal.kernel.ir')
local Dependencies = require('fibers.internal.kernel.dependencies')

local Bucket = Dependencies.Bucket
local AtomPool = Dependencies.AtomPool
local M = { SMALL_LIMIT = 4 }

local function assign(trail, target, key, value)
  if trail then
    trail:set(target, key, value)
  else
    target[key] = value
  end
end

local Index = {}
Index.__index = Index

local function pool_for(runtime)
  return runtime.dependency_index and runtime.dependency_index.pool or AtomPool.new()
end

function Index.new(runtime)
  return setmetatable({
    runtime = runtime,
    pool = pool_for(runtime),
    buckets = {},
    intents = {},
    exchange_ids = Bucket.new('demand-set', 'exchange'),
    witness_ids = Bucket.new('demand-set', 'witness'),
    transition_atoms = {},
    transition_seen = {},
    accepts_supply = 0,
  }, Index)
end

function Index:atom(kind, object, qualifier)
  return self.pool:intern(kind, object, qualifier)
end

function Index:bucket(atom)
  local bucket = self.buckets[atom]
  if not bucket then
    bucket = Bucket.new('demand', atom, atom.qualifier)
    self.buckets[atom] = bucket
  end
  return bucket
end

local function transition_atom(index, intent, rule)
  local location = intent.program and intent.program.location
  return index:atom('transition', location, rule.enumerable and 'witness' or 'group')
end

function Index:add(intent, trail)
  if trail and trail.current_mark == 0 then
    trail = nil
  end
  assign(trail, self.intents, intent.id, intent)
  if intent.kind == 'exchange' then
    local atom = self:atom('exchange', intent.resource, intent.role)
    assign(trail, intent, 'demand_atom', atom)
    self:bucket(atom):add(intent.id, trail)
    self.exchange_ids:add(intent.id, trail)
    assign(trail, self, 'accepts_supply', self.accepts_supply + 1)
  elseif intent.kind == 'transition' then
    local rule = IR.rule(intent.program)
    local atom = transition_atom(self, intent, rule)
    assign(trail, intent, 'demand_atom', atom)
    local bucket = self:bucket(atom)
    if not self.transition_seen[atom] then
      self.transition_seen[atom] = true
      self.transition_atoms[#self.transition_atoms + 1] = atom
    end
    bucket:add(intent.id, trail)
    if rule.enumerable then
      self.witness_ids:add(intent.id, trail)
    end
    if rule.accepts_supply then
      assign(trail, self, 'accepts_supply', self.accepts_supply + 1)
    end
  end
end

function Index:remove(intent, trail)
  if trail and trail.current_mark == 0 then
    trail = nil
  end
  local atom = intent and intent.demand_atom
  if not atom then
    return
  end
  local bucket = self.buckets[atom]
  if bucket then
    bucket:remove(intent.id, trail)
  end
  if intent.kind == 'exchange' then
    self.exchange_ids:remove(intent.id, trail)
    assign(trail, self, 'accepts_supply', math.max(0, self.accepts_supply - 1))
  else
    local rule = IR.rule(intent.program)
    if rule.enumerable then
      self.witness_ids:remove(intent.id, trail)
    end
    if rule.accepts_supply then
      assign(trail, self, 'accepts_supply', math.max(0, self.accepts_supply - 1))
    end
  end
  assign(trail, self.intents, intent.id, nil)
end

M.Index = Index
function M.new(runtime)
  return Index.new(runtime)
end
function M.add(index, intent, trail)
  return index:add(intent, trail)
end
function M.remove(index, intent, trail)
  return index:remove(intent, trail)
end

local function active(index, id)
  return index.intents[id]
end

local function exchange_compatible(left, right, compatible)
  return left
    and right
    and left.kind == 'exchange'
    and right.kind == 'exchange'
    and left.resource == right.resource
    and left.role ~= right.role
    and compatible(left, right)
end

local function opposite(role)
  return role == 'put' and 'get' or role == 'get' and 'put' or nil
end

local function sorted_ids(bucket)
  return bucket and bucket:ids() or {}
end

local function exchange_summary(index, state, compatible, constrained)
  local count = index.exchange_ids.count
  if count <= 2 then
    local ids = {}
    for i = 1, count do
      ids[i] = index.exchange_ids.items[i]
    end
    table.sort(ids)
    local pair, compatible_count = nil, 0
    if count == 2 then
      local left, right = active(index, ids[1]), active(index, ids[2])
      if exchange_compatible(left, right, compatible) then
        pair, compatible_count = { left = left.id, right = right.id }, 1
      end
    end
    return {
      ids = ids,
      selected = pair and active(index, pair.left) or nil,
      selected_degree = pair and 1 or 0,
      scans = count == 2 and 1 or 0,
      compatible = compatible_count,
      zero_domains = pair and 0 or count,
      symmetry_pruned = 0,
      unique_pair = pair,
    }
  end

  local ids, degree = sorted_ids(index.exchange_ids), {}
  local scans, compatible_count = 0, 0
  for i = 1, #ids do
    local intent = active(index, ids[i])
    if intent then
      local atom = index:atom('exchange', intent.resource, opposite(intent.role))
      local partners = index.buckets[atom]
      if partners then
        partners:each(function(partner_id)
          if intent.id < partner_id then
            local partner = active(index, partner_id)
            scans = scans + 1
            if exchange_compatible(intent, partner, compatible) then
              compatible_count = compatible_count + 1
              degree[intent.id] = (degree[intent.id] or 0) + 1
              degree[partner_id] = (degree[partner_id] or 0) + 1
            end
          end
        end)
      end
    end
  end

  local selected, selected_degree, zero = nil, nil, 0
  if constrained then
    for i = 1, #ids do
      local intent, degree_i = active(index, ids[i]), degree[ids[i]] or 0
      if intent then
        if degree_i == 0 then
          zero = zero + 1
        elseif
          selected_degree == nil
          or degree_i < selected_degree
          or degree_i == selected_degree and intent.id < selected.id
        then
          selected, selected_degree = intent, degree_i
        end
      end
    end
  else
    for i = 1, #ids do
      if not degree[ids[i]] then
        zero = zero + 1
      end
    end
  end
  return {
    ids = ids,
    selected = selected,
    selected_degree = selected_degree or 0,
    scans = scans,
    compatible = compatible_count,
    zero_domains = zero,
    symmetry_pruned = 0,
  }
end

local function first_id(index, atom)
  local bucket = index.buckets[atom]
  if not bucket or bucket.count == 0 then
    return math.huge
  end
  local first = math.huge
  bucket:each(function(id)
    if id < first then
      first = id
    end
  end)
  return first
end

local function active_transition_atoms(index)
  local atoms = {}
  for i = 1, #index.transition_atoms do
    local atom = index.transition_atoms[i]
    local bucket = index.buckets[atom]
    if atom.qualifier == 'group' and bucket and bucket.count > 0 then
      atoms[#atoms + 1] = atom
    end
  end
  table.sort(atoms, function(left, right)
    local a, b = index.buckets[left], index.buckets[right]
    if a.count ~= b.count then
      return a.count < b.count
    end
    local ai, bi = first_id(index, left), first_id(index, right)
    if ai ~= bi then
      return ai < bi
    end
    return left.id < right.id
  end)
  return atoms
end

local function group_for(domain, atom)
  local ids = sorted_ids(domain.index.buckets[atom])
  local intents, serial_only, accepts_supply = {}, true, false
  for i = 1, #ids do
    local intent = active(domain.index, ids[i])
    if intent then
      intents[#intents + 1] = intent
      local rule = IR.rule(intent.program)
      if not rule.serial then
        serial_only, accepts_supply = false, true
      elseif rule.accepts_supply then
        accepts_supply = true
      end
    end
  end
  return {
    key = atom.object,
    atom = atom,
    ids = ids,
    intents = intents,
    serial_only = serial_only,
    accepts_supply = accepts_supply,
  }
end

local EMPTY = {}

local function empty_domain(state, compatible, constrained)
  return {
    state = state,
    compatible_fn = compatible,
    constrained = constrained ~= false,
    exchange = {
      selected_degree = 0,
      scans = 0,
      compatible = 0,
      zero_domains = 0,
      symmetry_pruned = 0,
    },
    small_groups = EMPTY,
    small_witnesses = EMPTY,
    accepts_participant_supply = false,
  }
end

local function small_exchange_domain(state, compatible, constrained, left, right)
  local pair
  if right and exchange_compatible(left, right, compatible) then
    if right.id < left.id then
      left, right = right, left
    end
    pair = { left = left.id, right = right.id }
  end
  local count = right and 2 or left and 1 or 0
  return {
    state = state,
    compatible_fn = compatible,
    constrained = constrained ~= false,
    exchange = {
      selected = pair and left or nil,
      selected_degree = pair and 1 or 0,
      scans = right and 1 or 0,
      compatible = pair and 1 or 0,
      zero_domains = pair and 0 or count,
      symmetry_pruned = 0,
      unique_pair = pair,
    },
    small_groups = EMPTY,
    small_witnesses = EMPTY,
    accepts_participant_supply = count > 0,
  }
end

local function small_domain(state, compatible, constrained)
  local intents = state.intents or EMPTY
  local count = #intents
  if count == 0 then
    return empty_domain(state, compatible, constrained)
  end
  if count <= 2 and intents[1].kind == 'exchange' and (count == 1 or intents[2].kind == 'exchange') then
    return small_exchange_domain(state, compatible, constrained, intents[1], intents[2])
  end

  local exchanges, witnesses, groups = {}, {}, {}
  local accepts_supply = false
  for i = 1, count do
    local intent = intents[i]
    if intent.kind == 'exchange' then
      exchanges[#exchanges + 1] = intent
      accepts_supply = true
    elseif intent.kind == 'transition' then
      local rule = IR.rule(intent.program)
      if rule.enumerable then
        witnesses[#witnesses + 1] = intent
      else
        local location = intent.program.location
        local group
        for j = 1, #groups do
          if groups[j].key == location then
            group = groups[j]
            break
          end
        end
        if not group then
          group = { key = location, ids = {}, intents = {}, serial_only = true, accepts_supply = false }
          groups[#groups + 1] = group
        end
        group.ids[#group.ids + 1] = intent.id
        group.intents[#group.intents + 1] = intent
        if not rule.serial then
          group.serial_only, group.accepts_supply = false, true
        elseif rule.accepts_supply then
          group.accepts_supply = true
        end
      end
      if rule.accepts_supply then
        accepts_supply = true
      end
    end
  end
  table.sort(exchanges, function(left, right)
    return left.id < right.id
  end)
  local degree, scans, compatible_count, unique_pair = {}, 0, 0, nil
  for i = 1, #exchanges do
    for j = i + 1, #exchanges do
      local left, right = exchanges[i], exchanges[j]
      if left.resource == right.resource and left.role ~= right.role then
        scans = scans + 1
        if compatible(left, right) then
          compatible_count = compatible_count + 1
          degree[left.id] = (degree[left.id] or 0) + 1
          degree[right.id] = (degree[right.id] or 0) + 1
          unique_pair = compatible_count == 1 and { left = left.id, right = right.id } or nil
        end
      end
    end
  end
  local selected, selected_degree, zero = nil, nil, 0
  if constrained ~= false then
    for i = 1, #exchanges do
      local intent, n = exchanges[i], degree[exchanges[i].id] or 0
      if n == 0 then
        zero = zero + 1
      elseif
        selected_degree == nil
        or n < selected_degree
        or n == selected_degree and intent.id < selected.id
      then
        selected, selected_degree = intent, n
      end
    end
  else
    for i = 1, #exchanges do
      if not degree[exchanges[i].id] then
        zero = zero + 1
      end
    end
  end
  return {
    state = state,
    compatible_fn = compatible,
    constrained = constrained ~= false,
    small_exchanges = exchanges,
    exchange = {
      selected = selected,
      selected_degree = selected_degree or 0,
      scans = scans,
      compatible = compatible_count,
      zero_domains = zero,
      symmetry_pruned = 0,
      unique_pair = unique_pair,
    },
    small_groups = groups,
    small_witnesses = witnesses,
    accepts_participant_supply = accepts_supply,
  }
end

function M.open(index, state, compatible, constrained)
  if not index then
    return small_domain(state, compatible, constrained)
  end
  constrained = constrained ~= false
  return {
    index = index,
    state = state,
    compatible_fn = compatible,
    constrained = constrained,
    exchange = exchange_summary(index, state, compatible, constrained),
    transition_atoms = active_transition_atoms(index),
    witness_ids = sorted_ids(index.witness_ids),
    accepts_participant_supply = index.accepts_supply > 0,
  }
end

function M.each_group(domain, fn)
  if domain.small_groups then
    for i = 1, #domain.small_groups do
      fn(domain.small_groups[i])
    end
    return
  end
  for i = 1, #domain.transition_atoms do
    fn(group_for(domain, domain.transition_atoms[i]))
  end
end

local function next_exchange(cursor)
  local domain, state, index = cursor.domain, cursor.domain.state, cursor.domain.index
  local exchange = domain.exchange
  if exchange.unique_pair then
    if cursor.unique_done then
      return nil
    end
    cursor.unique_done = true
    return exchange.unique_pair
  end
  local exchanges = domain.small_exchanges
  if exchanges then
    if domain.constrained then
      local selected = exchange.selected
      if not selected then
        return nil
      end
      while cursor.partner <= #exchanges do
        local partner = exchanges[cursor.partner]
        cursor.partner = cursor.partner + 1
        if partner.id ~= selected.id and exchange_compatible(selected, partner, domain.compatible_fn) then
          return { left = selected.id, right = partner.id }
        end
      end
      return nil
    end
    while cursor.left <= #exchanges do
      while cursor.right <= #exchanges do
        local left, right = exchanges[cursor.left], exchanges[cursor.right]
        cursor.right = cursor.right + 1
        if exchange_compatible(left, right, domain.compatible_fn) then
          return { left = left.id, right = right.id }
        end
      end
      cursor.left, cursor.right = cursor.left + 1, cursor.left + 2
    end
    return nil
  end
  if not index then
    return nil
  end
  if domain.constrained then
    local selected = exchange.selected
    if not selected then
      return nil
    end
    if not cursor.partner_ids then
      local atom = index:atom('exchange', selected.resource, opposite(selected.role))
      cursor.partner_ids = sorted_ids(index.buckets[atom])
    end
    while cursor.partner <= #cursor.partner_ids do
      local partner = active(index, cursor.partner_ids[cursor.partner])
      cursor.partner = cursor.partner + 1
      if exchange_compatible(selected, partner, domain.compatible_fn) then
        local key = partner.symmetry_key
        if key ~= nil and state.runtime and state.runtime.certified_symmetry then
          local signature = table.concat({
            type(key),
            tostring(key),
            partner.kind,
            tostring(partner.resource),
            partner.role,
            type(partner.value),
            tostring(partner.value),
          }, ':')
          if cursor.symmetry[signature] then
            exchange.symmetry_pruned = exchange.symmetry_pruned + 1
          else
            cursor.symmetry[signature] = true
            return { left = selected.id, right = partner.id }
          end
        else
          return { left = selected.id, right = partner.id }
        end
      end
    end
    return nil
  end

  while cursor.left <= #exchange.ids do
    local left = active(index, exchange.ids[cursor.left])
    if not cursor.partner_ids then
      local atom = left and index:atom('exchange', left.resource, opposite(left.role))
      cursor.partner_ids = sorted_ids(atom and index.buckets[atom])
      cursor.partner = 1
    end
    while cursor.partner <= #cursor.partner_ids do
      local right = active(index, cursor.partner_ids[cursor.partner])
      cursor.partner = cursor.partner + 1
      if left and right and left.id < right.id and exchange_compatible(left, right, domain.compatible_fn) then
        return { left = left.id, right = right.id }
      end
    end
    cursor.left, cursor.partner_ids = cursor.left + 1, nil
  end
end

function M.unique_exchange(domain)
  if domain.exchange.compatible ~= 1 then
    return nil
  end
  return next_exchange({ domain = domain, partner = 1, left = 1, symmetry = {} })
end

function M.selected_unique_exchange(domain)
  if domain.exchange.selected_degree ~= 1 or not domain.exchange.selected then
    return nil
  end
  return next_exchange({ domain = domain, partner = 1, left = 1, symmetry = {} })
end

function M.cursor(domain)
  return {
    domain = domain,
    phase = 'exchange',
    partner = 1,
    left = 1,
    right = 2,
    symmetry = {},
    witness = 1,
    witness_cursor = nil,
    witness_alternative = 0,
    transition = 1,
    transition_phase = nil,
    transition_single = 1,
    supplier_phase = 1,
    supplier_loaded = false,
  }
end

function M.next(cursor, callbacks)
  local domain = cursor.domain
  while true do
    if cursor.phase == 'exchange' then
      local pair = next_exchange(cursor)
      if pair then
        return { kind = 'exchange', pair = pair, domain = domain.exchange.selected_degree }
      end
      cursor.phase = 'witness'
    elseif cursor.phase == 'witness' then
      local intent
      if domain.small_witnesses then
        intent = domain.small_witnesses[cursor.witness]
      else
        intent = active(domain.index, domain.witness_ids[cursor.witness])
      end
      if not intent then
        cursor.phase = 'transition'
      else
        cursor.witness_cursor = cursor.witness_cursor or callbacks.witness_cursor(intent)
        local alternative = cursor.witness_cursor:next()
        if alternative ~= nil then
          cursor.witness_alternative = cursor.witness_alternative + 1
          return {
            kind = 'witness',
            intent_id = intent.id,
            alternative = alternative,
            alternative_index = cursor.witness_alternative,
          }
        end
        cursor.witness, cursor.witness_cursor, cursor.witness_alternative = cursor.witness + 1, nil, 0
      end
    elseif cursor.phase == 'transition' then
      local atom = domain.transition_atoms and domain.transition_atoms[cursor.transition]
      local group = domain.small_groups and domain.small_groups[cursor.transition]
        or atom and group_for(domain, atom)
      if not group then
        cursor.phase = 'supplier'
      else
        if not cursor.transition_phase then
          cursor.transition_phase = group.serial_only and not group.accepts_supply and 'all'
            or #group.ids > 1 and 'closure'
            or 'single'
          cursor.transition_single = 1
        end
        if cursor.transition_phase == 'all' then
          cursor.transition_phase = 'done'
          return { kind = 'transition', group = group, ids = group.ids, transition_kind = 'all' }
        elseif cursor.transition_phase == 'closure' then
          cursor.transition_phase = 'single'
          return { kind = 'transition', group = group, ids = group.ids, transition_kind = 'closure' }
        elseif cursor.transition_phase == 'single' then
          local id = group.ids[cursor.transition_single]
          if id then
            cursor.transition_single = cursor.transition_single + 1
            return { kind = 'transition', group = group, ids = { id }, transition_kind = 'single' }
          end
          cursor.transition_phase = 'done'
        else
          cursor.transition, cursor.transition_phase = cursor.transition + 1, nil
        end
      end
    elseif cursor.phase == 'supplier' then
      if not cursor.supplier_loaded then
        cursor.supplier_loaded = true
        cursor.supplier = callbacks.supplier()
      end
      if not cursor.supplier then
        cursor.phase = 'done'
      elseif cursor.supplier_phase == 1 then
        cursor.supplier_phase = 2
        return { kind = 'recruit', row = cursor.supplier }
      elseif cursor.supplier_phase == 2 then
        cursor.supplier_phase = 3
        return { kind = 'exclude', row = cursor.supplier }
      else
        cursor.phase = 'done'
      end
    else
      return nil
    end
  end
end

return M
