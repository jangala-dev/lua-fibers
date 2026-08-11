---Small transactional vocabulary shared by host-backed resource lifecycles.

local StateMachine = require('fibers.resource.machine')
local TrustedState = require('fibers.internal.trusted_state')

local HostLifecycle = {}

function HostLifecycle.copy(value)
  local out = {}
  for key, item in pairs(value) do out[key] = item end
  return out
end

function HostLifecycle.enrich_first(current, payload, fields)
  local next_state = current
  for i = 1, #fields do
    local field = fields[i]
    local value = payload[field]
    if value ~= nil and current[field] == nil then
      if next_state == current then next_state = HostLifecycle.copy(current) end
      next_state[field] = value
    end
  end
  return next_state
end

function HostLifecycle.define(spec)
  local Type = { transition_op = StateMachine.transition_op }
  Type.__index = Type
  local prefix = assert(spec.prefix, 'host lifecycle prefix required')
  local Update = spec.update and StateMachine.isolated_update(prefix .. '.update', spec.update)
  local Select = spec.select and StateMachine.isolated_select(prefix .. '.select', spec.select)
  local Query = spec.query and StateMachine.isolated_query(prefix .. '.query', spec.query)

  function Type.new(...) return setmetatable(TrustedState.machine(spec.initial(...)), Type) end

  if Update then function Type:_update_op(payload) return self:transition_op(Update, payload) end end
  if Select then function Type:_select_op(payload) return self:transition_op(Select, payload) end end
  if Query then function Type:_query_op(payload) return self:transition_op(Query, payload) end end
  return Type
end



return HostLifecycle
