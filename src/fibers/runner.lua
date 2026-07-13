-- Standalone Runtime runner.
--
-- Runtime:run is the efficient internal driver: it runs ready work until a
-- commit, quiescence, or a pending wait.  This runner adds host blocking around
-- that primitive, so standalone applications can sleep or poll without making
-- the kernel own the event loop.

local Host = require('fibers.host')

local Runner = {}

function Runner.run(rt, opts)
  opts = opts or {}
  local host = opts.host or rt.host
  local run_opts = opts.run
  local max_iterations = opts.max_iterations or opts.max_driver_iterations
  local iterations = 0
  local saw_found = false
  local last_found = nil

  while true do
    iterations = iterations + 1
    if max_iterations and iterations > max_iterations then
      return { tag = 'pending', reason = 'runner iteration budget exhausted' }
    end

    local st = rt:run(run_opts)

    if st and st.tag == 'found' then
      saw_found = true
      last_found = st
    elseif st and st.tag == 'pending' then
      local interests = st.interests or st.waits or {}
      local progressed, reason = Host.block(host, rt, interests, st, opts.host_options)
      if progressed then
        -- Host time or readiness may now make a wait productive.  Re-enter the
        -- efficient Runtime:run path rather than looping over Runtime:step.
      else
        st.host_reason = reason
        st.reason = st.reason or reason
        st.interests, st.waits = interests, interests
        return st
      end
    elseif st and (st.tag == 'idle' or st.tag == 'quiescent') then
      if saw_found then
        return last_found or { tag = 'found', value = true }
      end
      return st
    else
      return st
    end
  end
end

return Runner
