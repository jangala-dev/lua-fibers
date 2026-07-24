local Op = require('fibers.op')
local Facility = require('fibers.resource.authoring')
local Program = require('fibers.internal.kernel.ir')
local Substrate = require('fibers.internal.kernel.ledger')

local Petri = {}
Petri.__index = Petri
local Kind = { name = 'petri' }
local next_net_id = 0

local function copy_array(xs)
  local out = {}
  for i = 1, #(xs or {}) do
    out[i] = xs[i]
  end
  return out
end

local function copy_tokens(tokens)
  local out = {}
  for i = 1, #(tokens or {}) do
    out[i] = tokens[i]
  end
  return out
end

local function materialise_places(s)
  local out = {}
  for place in pairs(s.place_names or {}) do
    out[place] = s.places[place] or {}
  end
  return out
end

local function clone_state(s)
  local parent, depth = s.places, (s.depth or 0) + 1
  if depth > 16 then
    parent, depth = materialise_places(s), 0
  end
  return {
    next_token = s.next_token or 0,
    places = setmetatable({}, { __index = parent }),
    local_places = {},
    place_names = s.place_names,
    depth = depth,
  }
end

local function ensure_place(state, place)
  if not state.local_places[place] then
    rawset(state.places, place, copy_tokens(state.places[place]))
    state.local_places[place] = true
  end
  if not state.place_names[place] then
    local names = {}
    for k in pairs(state.place_names) do
      names[k] = true
    end
    names[place] = true
    state.place_names = names
  end
  return state.places[place]
end

local function snapshot_state(s)
  local out = {}
  for place in pairs(s.place_names or {}) do
    local tokens, ys = s.places[place] or {}, {}
    for i = 1, #tokens do
      ys[i] = tokens[i].value
    end
    out[place] = ys
  end
  return out
end

local function add_token(state, place, value)
  state.next_token = (state.next_token or 0) + 1
  local xs = ensure_place(state, place)
  xs[#xs + 1] = { id = state.next_token, value = value }
end

local function remove_token_ids(state, consumed)
  for place, ids in pairs(consumed) do
    local source, keep = state.places[place] or {}, {}
    for i = 1, #source do
      local token = source[i]
      if not ids[token.id] then
        keep[#keep + 1] = token
      end
    end
    state.local_places[place] = true
    rawset(state.places, place, keep)
  end
end

local function normalise_produced(produced)
  local out = {}
  if not produced then
    return out
  end
  if produced[1] and type(produced[1]) == 'table' and produced[1].place ~= nil then
    for i = 1, #produced do
      local x = produced[i]
      out[#out + 1] = { place = x.place, value = x.value }
    end
    return out
  end
  for place, values in pairs(produced) do
    if type(values) == 'table' and values._petri_single == true then
      out[#out + 1] = { place = place, value = values.value }
    elseif type(values) == 'table' then
      for i = 1, #values do
        out[#out + 1] = { place = place, value = values[i] }
      end
    else
      out[#out + 1] = { place = place, value = values }
    end
  end
  table.sort(out, function(a, b)
    return tostring(a.place) < tostring(b.place)
  end)
  return out
end

function Petri.token(value)
  return { _petri_single = true, value = value }
end

function Petri.new(marking, name)
  next_net_id = next_net_id + 1
  local state = { next_token = 0, places = {}, local_places = {}, place_names = {}, depth = 0 }
  for place, values in pairs(marking or {}) do
    if type(values) ~= 'table' then
      values = { values }
    end
    for i = 1, #values do
      add_token(state, place, values[i])
    end
  end
  local net = setmetatable({
    name = name or ('petri-' .. tostring(next_net_id)),
    _fibers_id = 'petri-' .. tostring(next_net_id),
    _fibers_kind = Kind,
    _state = state,
    version = 0,
  }, Petri)
  net._location = Substrate.new_location({
    name = net.name .. ':marking',
    algebra = 'machine',
    domain = 'plain',
    value = state,
    owner = net,
    apply = function(v, loc)
      net._state = v
      net.version = loc.version
    end,
  })
  return net
end

function Petri:transition(spec)
  assert(type(spec) == 'table', 'Petri transition expects a table')
  assert(spec.supply == nil, 'Petri transition no longer accepts supply; use accepts_supply and supplies')
  local transition = {
    _petri_transition = true,
    net = self,
    name = spec.name or '<transition>',
    inputs = copy_array(spec.inputs or spec.consume or {}),
    guard = spec.guard,
    produce = spec.produce,
    result = spec.result,
    order = spec.order or 0,
    accepts_supply = spec.accepts_supply ~= false,
    supplies = spec.supplies or 'any',
  }
  return transition
end

local function binding_cursor(transition, state, payload)
  local co = coroutine.create(function()
    local inputs, used, bindings, chosen = transition.inputs, {}, {}, {}
    local function emit()
      if transition.guard and not transition.guard(bindings, payload, state) then
        return
      end
      local successor, consumed = clone_state(state), {}
      for i = 1, #chosen do
        local c = chosen[i]
        if c.consume then
          local ids = consumed[c.place] or {}
          consumed[c.place] = ids
          ids[c.token.id] = true
        end
      end
      remove_token_ids(successor, consumed)
      local produced = transition.produce
      if type(produced) == 'function' then
        produced = produced(bindings, payload, state)
      end
      local xs = normalise_produced(produced)
      for i = 1, #xs do
        add_token(successor, xs[i].place, xs[i].value)
      end
      local result
      if transition.result then
        result = Op._pack(transition.result(bindings, payload, successor))
      else
        local copy = {}
        for k, v in pairs(bindings) do
          copy[k] = v
        end
        result = Op._pack(copy)
      end
      coroutine.yield({ value = successor, result = result, writes = true })
    end
    local function search(i)
      if i > #inputs then
        emit()
        return
      end
      local arc, tokens = inputs[i], state.places[inputs[i].place] or {}
      for ti = 1, #tokens do
        local token, consume = tokens[ti], arc.consume ~= false
        if not consume or not used[token.id] then
          local ok = not arc.where or arc.where(token.value, bindings, payload, state) ~= false
          if ok then
            if consume then
              used[token.id] = true
            end
            local old, had = bindings[arc.as], arc.as ~= nil and bindings[arc.as] ~= nil
            if arc.as ~= nil then
              bindings[arc.as] = token.value
            end
            chosen[#chosen + 1] = { place = arc.place, token = token, consume = consume }
            search(i + 1)
            chosen[#chosen] = nil
            if arc.as ~= nil then
              bindings[arc.as] = had and old or nil
            end
            if consume then
              used[token.id] = nil
            end
          end
        end
      end
    end
    if #inputs == 0 then
      emit()
    else
      search(1)
    end
  end)
  return {
    next = function()
      if coroutine.status(co) == 'dead' then
        return nil
      end
      local ok, value = coroutine.resume(co)
      if not ok then
        error(value, 0)
      end
      return value
    end,
  }
end

function Petri:fire_op(transition, payload)
  if type(transition) ~= 'table' or transition._petri_transition ~= true or transition.net ~= self then
    error('Petri fire expects a transition belonging to this net', 2)
  end
  local program = Facility.witness({
    location = self._location,
    group = self._location,
    order = transition.order,
    accepts_supply = transition.accepts_supply,
    supplies = transition.supplies,
    payload = payload or {},
    cursor = function(state, actual_payload)
      return binding_cursor(transition, state, actual_payload)
    end,
  })
  return Facility.op(self, Kind, program)
end

function Petri:put_op(place, value)
  local t = self:transition({
    name = 'put:' .. tostring(place),
    produce = { { place = place, value = value } },
    result = function()
      return true
    end,
  })
  return self:fire_op(t)
end

function Petri:take_op(place, predicate)
  local t = self:transition({
    name = 'take:' .. tostring(place),
    inputs = {
      {
        place = place,
        as = 'value',
        where = predicate and function(v)
          return predicate(v)
        end or nil,
      },
    },
    result = function(b)
      return b.value
    end,
  })
  return self:fire_op(t)
end

function Petri:marking_op()
  return Facility.op(
    self,
    Kind,
    Facility.witness({
      location = self._location,
      accepts_supply = false,
      supplies = 'none',
      cursor = function(state)
        local done = false
        return {
          next = function()
            if done then
              return nil
            end
            done = true
            return { writes = false, result = Op._pack(snapshot_state(state)) }
          end,
        }
      end,
    })
  )
end

function Petri:snapshot()
  return snapshot_state(self._state)
end

Petri.Kind = Kind
return Petri
