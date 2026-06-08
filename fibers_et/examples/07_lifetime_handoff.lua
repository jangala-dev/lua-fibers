package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

-- Negotiated lifetime handoff.
--
-- A plain transfer lets the current owner move an obligation.  A handoff is
-- stronger: the owner offers the obligation and the receiver must accept it in
-- the same committed world.  The receiver can combine acceptance with its own
-- state changes, so admission, registry updates, and ownership transfer happen
-- together or not at all.

local fibers = require('fibers')

local function yn(v) return v and 'yes' or 'no' end

local function named(x)
  if type(x) ~= 'table' then return tostring(x) end
  return x.name or x._fibers_id or tostring(x)
end

local function append_log(log, line)
  return { text = (log.text == '' and line or (log.text .. '\n' .. line)), _fibers_value = true }
end

local function event_line(ev)
  local task = ev.task or ev.item
  if ev.type == 'task_admitted' then
    return string.format('  admitted    %-10s into %s', named(task), named(ev.lifetime))
  elseif ev.type == 'task_transferred' then
    return string.format('  transferred %-10s from %s to %s', named(task), named(ev.lifetime), named(ev.to_lifetime or ev.to))
  elseif ev.type == 'task_received' then
    return string.format('  received    %-10s by %s', named(task), named(ev.lifetime))
  elseif ev.type == 'task_released' then
    return string.format('  released    %-10s from %s', named(task), named(ev.lifetime))
  elseif ev.type == 'region_sealed' then
    return string.format('  sealed      %s', named(ev.lifetime))
  end
  return string.format('  %-11s %s', tostring(ev.type), named(task or ev.lifetime))
end

local request = fibers.Lifetime.new('request')
local supervisor = fibers.Lifetime.new('supervisor')
local resume = fibers.Channel.new('resume-session')
local registry = fibers.Cell.new({ owner = 'request', task = '-', _fibers_value = true }, 'registry')
local audit = fibers.Cell.new({ text = '', _fibers_value = true }, 'audit')

local result = {}

local rt = fibers.Runtime.new()
rt:spawn_raw(function()
  local session = rt:perform(request:spawn_op(function()
    local msg = fibers.perform(resume:get_op())
    return 'session resumed with: ' .. msg
  end, { name = 'session' }))

  result.spawned_owner = rt:perform(request:owns_op(session)) and 'request' or 'unknown'

  -- Without receiver participation, offer_op cannot close its handoff rendezvous.
  -- The fallback branch commits and ownership remains with request.
  result.offer_without_accept = rt:perform(fibers.choice(
    request:offer_op(session, supervisor):map(function() return 'unexpected handoff' end),
    fibers.always('no accept; no handoff')
  ))
  result.request_still_owns = rt:perform(request:owns_op(session))
  result.supervisor_owns_before = rt:perform(supervisor:owns_op(session))

  -- Now the receiver accepts.  Its acceptance is composed with its own registry
  -- and audit updates.  These updates commit iff ownership moves.
  local rows = rt:perform(fibers.tensor({
    request:offer_op(session, supervisor),
    supervisor:accept_op(),
    registry:set_op({ owner = 'supervisor', task = session.name, _fibers_value = true }),
    audit:update_op(function(log)
      return append_log(log, 'accepted ' .. session.name .. ' from request into supervisor')
    end),
  }))

  result.accepted = rows[2][1]
  result.request_owns_after = rt:perform(request:owns_op(session))
  result.supervisor_owns_after = rt:perform(supervisor:owns_op(session))
  result.registry_after = rt:perform(registry:get_op())
  result.audit_after = rt:perform(audit:get_op())

  rt:perform(resume:put_op('supervisor owns the session'))
  result.join = { rt:perform(session:join_op()) }

  rt:perform(supervisor:release_op(session))
  result.supervisor_owns_released = rt:perform(supervisor:owns_op(session))

  rt:perform(request:seal_op())
  rt:perform(supervisor:seal_op())
  result.request_status = rt:perform(request:status_op())
  result.supervisor_status = rt:perform(supervisor:status_op())
end, 'handoff-root')

local st
repeat st = rt:run() until st.tag ~= 'found'

assert(result.accepted.item)
assert(result.request_still_owns == true)
assert(result.supervisor_owns_before == false)
assert(result.request_owns_after == false)
assert(result.supervisor_owns_after == true)
assert(result.registry_after.owner == 'supervisor')
assert(result.join[1] == 'ok')
assert(result.supervisor_owns_released == false)

print('== negotiated lifetime handoff ==')
print('spawned task owner:          ' .. result.spawned_owner)
print('offer without accept:        ' .. result.offer_without_accept)
print('request still owns then?     ' .. yn(result.request_still_owns))
print('supervisor owns before?      ' .. yn(result.supervisor_owns_before))
print('handoff accepted:            ' .. named(result.accepted.item) .. ' from ' .. named(result.accepted.from) .. ' to ' .. named(result.accepted.to))
print('request owns after?          ' .. yn(result.request_owns_after))
print('supervisor owns after?       ' .. yn(result.supervisor_owns_after))
print('registry owner after commit: ' .. result.registry_after.owner .. ' / ' .. result.registry_after.task)
print('task join result:            ' .. result.join[1] .. ' / ' .. tostring(result.join[2]))
print('supervisor owns after release? ' .. yn(result.supervisor_owns_released))
print('request sealed?              ' .. yn(result.request_status.sealed))
print('supervisor sealed?           ' .. yn(result.supervisor_status.sealed))
print('audit:')
print('  ' .. result.audit_after.text)
print('lifetime facility effects:')
for i, ev in ipairs(rt.published_lifetime or {}) do
  if ev.lifetime then print(event_line(ev)) end
end
