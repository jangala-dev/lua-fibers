-- Deterministic minimum/maximum selection over finite-map locations.

local Facility = require('fibers.resource.authoring')

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
          error('extreme selection requires unique (rank, sequence) pairs', 2)
        end
      end
      if better then best = { key = key, entry = entry } end
    end
  end
  return best
end

function Extreme.spec(opts)
  assert(opts.order == 'min' or opts.order == 'max', 'extreme selection requires min or max order')
  return Facility.rule.change({
    location = opts.location,
    demand = opts.demand or 'up',
    visibility = 'together',
    supply = 'down',
    step = function(value)
      local witness = select_extreme(opts, value)
      if not witness then return nil end
      local patch = Facility.patch.map_remove(witness.key)
      patch.ops[1].op = 'take'
      return Facility.outcome_result(
        patch,
        opts.result or Facility.result.value,
        witness.entry,
        { location = opts.location, resource = opts.resource }
      )
    end,
  })
end

return Extreme
