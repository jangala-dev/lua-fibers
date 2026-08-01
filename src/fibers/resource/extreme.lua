-- Deterministic minimum/maximum selection over finite-map locations.

local Facility = require('fibers.resource.authoring')
local Operation = require('fibers.internal.operation')

local Extreme = {}

local function select_extreme(opts, value)
  local best, rank_field, seq_field = nil, opts.rank_field or 'rank', opts.seq_field or 'seq'
  local maximum = opts.order == 'max'
  for key, entry in pairs(value or {}) do
    if not best then
      best = { key = key, entry = entry }
    else
      local rank, best_rank = entry[rank_field], best.entry[rank_field]
      local better
      if rank ~= best_rank then
        better = maximum and rank > best_rank or not maximum and rank < best_rank
      else
        local seq, best_seq = entry[seq_field] or 0, best.entry[seq_field] or 0
        if seq ~= best_seq then
          better = maximum and seq > best_seq or not maximum and seq < best_seq
        else
          local text, best_text = tostring(key), tostring(best.key)
          better = maximum and text > best_text or not maximum and text < best_text
        end
      end
      if better then
        best = { key = key, entry = entry }
      end
    end
  end
  return best
end

function Extreme.spec(opts)
  assert(opts.order == 'min' or opts.order == 'max', 'extreme selection requires min or max order')
  return Facility.transition({
    location = opts.location,
    group = opts.group,
    demand = opts.demand or 'up',
    accepts_supply = true,
    supplies = 'down',
    writes = true,
    order = opts.transition_order or 0,
    step = function(value, _, _, _, leaf)
      local witness = select_extreme(opts, value)
      if not witness then
        return nil
      end
      return {
        patch = { kind = 'finite_map', ops = { { op = 'take', key = witness.key } } },
        writes = true,
        result = Operation.result_pack(leaf, witness.entry),
      }
    end,
    result = opts.result or Facility.result.value,
  })
end

return Extreme
