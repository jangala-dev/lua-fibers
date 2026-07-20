-- Shared versioned waits over Scalar resources.
--
-- A selector returns an Op when its condition is ready, nil to wait for the
-- next version, or nil, false when the condition is permanently unavailable in
-- the current branch. Writable waits declare the complete lifecycle-machine
-- domain because selectors may return transitions on that same Scalar.

local Op = require('fibers.op')

local ScalarWait = {}
local unpack_ = table.unpack or unpack

local function pack(...)
  return { n = select('#', ...), ... }
end

local function footprint(scalar, writable)
  if not writable then
    return Op.dependencies(scalar:snapshot_op(), scalar:changed_op(0))
  end
  return {
    external = true,
    locations = {
      [scalar._location] = {
        read = true,
        write = true,
        wait = true,
        supplies = { any = true },
      },
    },
  }
end

function ScalarWait.select_op(scalar, select, opts)
  opts = opts or {}
  local dependencies = opts.footprint or footprint(scalar, opts.writable == true)
  local function loop()
    return scalar:snapshot_op():and_then(function(snapshot)
      local option, wait = select(snapshot.value)
      if option ~= nil then
        return option
      end
      if wait == false then
        return Op.never()
      end
      return scalar:changed_op(snapshot.version):and_then(loop, dependencies)
    end, dependencies)
  end
  return loop()
end

function ScalarWait.until_op(scalar, predicate, opts)
  return ScalarWait.select_op(scalar, function(value)
    local result = pack(predicate(value))
    if result[1] then
      return Op.always(unpack_(result, 2, result.n))
    end
  end, opts)
end

function ScalarWait.value_op(scalar, predicate, opts)
  return ScalarWait.select_op(scalar, function(value)
    if predicate(value) then
      return Op.always(value)
    end
  end, opts)
end

return ScalarWait
