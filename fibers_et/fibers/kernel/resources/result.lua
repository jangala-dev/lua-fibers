-- Result of asking a resource primitive to participate in a transaction.
-- A resource is ready with one proposal, opens a premise, or returns a
-- proof-carrying retry.  Incomplete search is represented by the solver, not by
-- resource results.

local RetryProof = require('fibers.kernel.retry')

local Result = {}

function Result.ready(proposal)
  if proposal == nil then error('Result.ready requires a proposal', 2) end
  return { status = 'ready', proposal = proposal }
end

function Result.premise(request)
  if request == nil then error('Result.premise requires a request', 2) end
  return { status = 'premise', premise = request }
end

function Result.retry(proof)
  if not RetryProof.is_retry_proof(proof) then proof = RetryProof.new(proof) end
  return { status = 'retry', proof = proof }
end

function Result.permanent(reason)
  return Result.retry(RetryProof.permanent(reason))
end

function Result.from(result)
  if type(result) ~= 'table' then error('resource eval must return a Result', 2) end
  local status = result.status
  if status ~= 'ready' and status ~= 'premise' and status ~= 'retry' then
    error('unknown resource result status: ' .. tostring(status), 2)
  end
  return result
end

return Result
