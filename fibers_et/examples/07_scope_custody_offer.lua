package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

-- Negotiated scope custody offer.
--
-- A plain move lets the current owner move an obligation.  A custody offer is
-- stronger: the owner offers the obligation and the receiver must accept it in
-- the same committed world.  The receiver can combine acceptance with its own
-- state changes, so admission, registry updates, and ownership movement happen
-- together or not at all.

local fibers = require('fibers')
local Settlement = require('fibers.internal.settlement')

local function yn(v)
  return v and 'yes' or 'no'
end

local function named(x)
  if type(x) ~= 'table' then
    return tostring(x)
  end
  return x.name or x._fibers_id or tostring(x)
end

local function append_log(log, line)
  return { text = (log.text == '' and line or (log.text .. '\n' .. line)) }
end

local function append_log_op(scalar, line)
  return scalar:read_op():and_then(function(log)
    return scalar:write_op(append_log(log, line))
  end)
end

local request = fibers.Scope.new('request')
local supervisor = fibers.Scope.new('supervisor')
local resume = fibers.Rendezvous.new('resume-session')
local registry = fibers.Scalar.new({ owner = 'request', task = '-' }, 'registry')
local audit = fibers.Scalar.new({ text = '' }, 'audit')

local result = {}
local rt = fibers.Runtime.new()
rt:spawn_raw(function()
  local session = rt:perform(request:spawn_op(function()
    local msg = fibers.perform(resume:get_op())
    return 'session resumed with: ' .. msg
  end, { name = 'session' }))

  result.spawned_owner = rt:perform(request:owns_op(session)) and 'request' or 'unknown'

  -- Without receiver participation, offer_op cannot close its custody-offer rendezvous.
  -- The fallback branch commits and ownership remains with request.
  result.offer_without_accept = rt:perform(request
    :offer_op(session, supervisor)
    :map(function()
      return 'unexpected custody offer'
    end)
    :or_else(fibers.always('no accept; no custody offer')))
  result.request_still_owns = rt:perform(request:owns_op(session))
  result.supervisor_owns_before = rt:perform(supervisor:owns_op(session))

  -- Now the receiver accepts.  Its acceptance is composed with its own registry
  -- and audit updates.  These updates commit iff ownership moves.
  local rows = rt:perform(fibers.tensor({
    request:offer_op(session, supervisor),
    supervisor:accept_op(),
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

  rt:perform(Settlement.retire_item_op(supervisor, session))
  result.supervisor_owns_released = rt:perform(supervisor:owns_op(session))

  rt:perform(request:seal_op())
  rt:perform(supervisor:seal_op())
  result.request_state = rt:perform(request:inspect_op())
  result.supervisor_state = rt:perform(supervisor:inspect_op())
end, 'custody-offer-root')

local st
repeat
  st = rt:run()
until st.tag ~= 'found'

assert(result.accepted.item)
assert(result.request_still_owns == true)
assert(result.supervisor_owns_before == false)
assert(result.request_owns_after == false)
assert(result.supervisor_owns_after == true)
assert(result.registry_after.owner == 'supervisor')
assert(result.await[1] == 'session resumed with: supervisor owns the session')
assert(result.supervisor_owns_released == false)

print('== negotiated scope custody offer ==')
print('spawned task owner:          ' .. result.spawned_owner)
print('offer without accept:        ' .. result.offer_without_accept)
print('request still owns then?     ' .. yn(result.request_still_owns))
print('supervisor owns before?      ' .. yn(result.supervisor_owns_before))
print(
  'custody offer accepted:    '
    .. named(result.accepted.item)
    .. ' from '
    .. named(result.accepted.from)
    .. ' to '
    .. named(result.accepted.to)
)
print('request owns after?          ' .. yn(result.request_owns_after))
print('supervisor owns after?       ' .. yn(result.supervisor_owns_after))
print(
  'registry owner after commit: '
    .. result.registry_after.owner
    .. ' / '
    .. result.registry_after.task
)
print('task await result:            ' .. tostring(result.await[1]))
print('supervisor owns after release? ' .. yn(result.supervisor_owns_released))
print('request sealed?              ' .. yn(result.request_state.sealed))
print('supervisor sealed?           ' .. yn(result.supervisor_state.sealed))
print('request owned count:         ' .. tostring(result.request_state.owned_count))
print('supervisor owned count:      ' .. tostring(result.supervisor_state.owned_count))
print('audit:')
print('  ' .. result.audit_after.text)
