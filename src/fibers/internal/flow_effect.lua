-- Internal committed notification for Flow state changes.
--
-- Flow options select this consequence alongside state-changing transitions.
-- The effect is deduplicated per Flow within one committed world and discharged
-- only after resource installation, so speculative and losing transitions do
-- not notify the host reactor.

local Effect = require('fibers.lifetime.effect')

local FlowChangedKind

local function flow_key(payload)
  local flow = payload.flow
  return flow and flow._fibers_id or tostring(flow)
end

FlowChangedKind = Effect.kind({
  name = 'flow_changed',
  order = 90,
  key = flow_key,
  merge = function(a, _b)
    return a
  end,
  validate_payload = function(_kind, payload)
    if type(payload.flow) ~= 'table' or payload.flow._fibers_id == nil then
      return nil,
        {
          kind = 'invalid_effect_payload',
          message = 'flow_changed effect requires a Flow',
        }
    end
    return true
  end,
  prepare = function(_rt, payload)
    return {
      kind = FlowChangedKind,
      key = flow_key(payload),
      payload = payload,
      discharge = function(rt, prepared)
        local reactor = rt.host_reactor
        if reactor and type(reactor._notify_flow_changed) == 'function' then
          reactor:_notify_flow_changed(prepared.payload.flow)
        end
        return true
      end,
    }
  end,
})

local M = {}

function M.changed(flow)
  return Effect.of(FlowChangedKind, { flow = flow })
end

M.Kind = FlowChangedKind
return M
