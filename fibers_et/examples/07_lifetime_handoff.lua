package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

-- Negotiated lifetime handoff.
--
-- A plain reassignment lets the current owner move an obligation.  A handoff is
-- stronger: the owner offers the obligation and the receiver must accept it in
-- the same committed world.  The receiver can combine acceptance with its own
-- state changes, so admission, registry updates, and ownership handoff happen
-- together or not at all.

local fibers = require('fibers')

local function yn(v) return v and 'yes' or 'no' end

local function named(x)
  if type(x) ~= 'table' then return tostring(x) end
  return x.name or x._fibers_id or tostring(x)
end

local function append_log(log, line)
  return { text = (log.text == '' and line or (log.text .. '\n' .. line)) }
end

local function append_log_op(cell, line)
  return cell:read_op():and_then(function(log)
    return cell:write_op(append_log(log, line))
  end)
end

local function event_line(ev)
  local task = ev.task or ev.item
  if ev.type == 'admitted' then
    return string.format('  admitted    %-10s into %s', named(task), named(ev.lifetime))
  elseif ev.type == 'reassigned' then
    return string.format('  reassigned  %-10s from %s to %s', named(task), named(ev.lifetime), named(ev.to_lifetime or ev.to))
  elseif ev.type == 'handoff_received' then
    return string.format('  received    %-10s by %s', named(task), named(ev.lifetime))
  elseif ev.type == 'retired' then
    return string.format('  retired     %-10s from %s', named(task), named(ev.lifetime))
  elseif ev.type == 'closed' then
    return string.format('  closed      %s', named(ev.lifetime))
  elseif ev.type == 'settled' then
    return string.format('  settled     %s', named(ev.lifetime))
  end
  return string.format('  %-11s %s', tostring(ev.type), named(task or ev.lifetime))
end

local request = fibers.Lifetime.new('request')
local supervisor = fibers.Lifetime.new('supervisor')
local resume = fibers.Channel.new('resume-session')
local registry = fibers.Cell.new({ owner = 'request', task = '-' }, 'registry')
local audit = fibers.Cell.new({ text = '' }, 'audit')

local result = {}

local rt = fibers.Runtime.new()
rt:spawn_raw(function()
  local session = rt:perform(request:spawn_op(function()
    local msg = fibers.perform(resume:get_op())
    return 'session resumed with: ' .. msg
  end, { name = 'session' }))

  result.spawned_owner = rt:perform(request:owns_op(session)) and 'request' or 'unknown'

  -- Without receiver participation, offer_handoff_op cannot close its handoff rendezvous.
  -- The fallback branch commits and ownership remains with request.
  result.offer_without_accept = rt:perform(fibers.choice(
    request:offer_handoff_op(session, supervisor):map(function() return 'unexpected handoff' end),
    fibers.always('no accept; no handoff')
  ))
  result.request_still_owns = rt:perform(request:owns_op(session))
  result.supervisor_owns_before = rt:perform(supervisor:owns_op(session))

  -- Now the receiver accepts.  Its acceptance is composed with its own registry
  -- and audit updates.  These updates commit iff ownership moves.
  local rows = rt:perform(fibers.tensor({
    request:offer_handoff_op(session, supervisor),
    supervisor:accept_handoff_op(),
    registry:write_op({ owner = 'supervisor', task = session.name }),
    append_log_op(audit, 'accepted ' .. session.name .. ' from request into supervisor'),
  }))

  result.accepted = rows[2][1]
  result.request_owns_after = rt:perform(request:owns_op(session))
  result.supervisor_owns_after = rt:perform(supervisor:owns_op(session))
  result.registry_after = rt:perform(registry:read_op())
  result.audit_after = rt:perform(audit:read_op())

  rt:perform(resume:put_op('supervisor owns the session'))
  result.await = { rt:perform(session:await_op()) }

  rt:perform(supervisor:retire_op(session))
  result.supervisor_owns_released = rt:perform(supervisor:owns_op(session))

  rt:perform(request:close_op())
  rt:perform(supervisor:close_op())
  rt:perform(request:settle_op())
  rt:perform(supervisor:settle_op())
  result.request_state = rt:perform(request:state_op())
  result.supervisor_state = rt:perform(supervisor:state_op())
end, 'handoff-root')

local st
repeat st = rt:run() until st.tag ~= 'found'

assert(result.accepted.item)
assert(result.request_still_owns == true)
assert(result.supervisor_owns_before == false)
assert(result.request_owns_after == false)
assert(result.supervisor_owns_after == true)
assert(result.registry_after.owner == 'supervisor')
assert(result.await[1] == 'session resumed with: supervisor owns the session')
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
print('task await result:            ' .. tostring(result.await[1]))
print('supervisor owns after release? ' .. yn(result.supervisor_owns_released))
print('request closed?              ' .. yn(result.request_state.sealed))
print('supervisor closed?           ' .. yn(result.supervisor_state.sealed))
print('request settled?             ' .. yn(result.request_state.settled))
print('supervisor settled?          ' .. yn(result.supervisor_state.settled))
print('audit:')
print('  ' .. result.audit_after.text)
print('lifetime facility effects:')
for i, ev in ipairs(rt.published_lifetime or {}) do
  if ev.lifetime then print(event_line(ev)) end
end
