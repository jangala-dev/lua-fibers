-- Exhaustive premise-resolution result.
--
-- A resolver may produce zero or more current solutions. The accompanying
-- RetryProof records the managed facts under which that enumeration is
-- complete. Proof construction may be deferred because a successful solution
-- does not need exhaustion evidence.

local RetryProof = require('fibers.kernel.retry')

local Resolution = {}

function Resolution.exhaustive(solutions, proof_or_factory)
  local proof, proof_factory
  if type(proof_or_factory) == 'function' then proof_factory = proof_or_factory
  else proof = proof_or_factory end
  return {
    _fibers_resolution = true,
    solutions = solutions or {},
    proof = proof,
    proof_factory = proof_factory,
  }
end

function Resolution.exhaustive_after(solutions, ctx, observations)
  return Resolution.exhaustive(solutions, function()
    for i = 1, #(observations or {}) do
      local obs = observations[i]
      if ctx and ctx.add then ctx:add(obs) end
    end
    return ctx and ctx.proof and ctx:proof() or RetryProof.new()
  end)
end

function Resolution.materialise_proof(value, fallback)
  if not Resolution.is_resolution(value) then return fallback or RetryProof.new() end
  if value.proof then return value.proof end
  local proof
  if value.proof_factory then
    proof = value.proof_factory()
    value.proof_factory = nil
  end
  value.proof = proof or fallback or RetryProof.new()
  return value.proof
end

function Resolution.is_resolution(value)
  return type(value) == 'table' and value._fibers_resolution == true
end

return Resolution
