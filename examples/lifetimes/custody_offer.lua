package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Negotiated scope custody offer.
--
-- A plain move lets the current custodian move a consequence.  A custody offer is
-- stronger: the custodian offers the consequence and the receiver must accept it in
-- the same committed world.  The receiver can combine acceptance with its own
-- state changes, so admission, registry updates, and custody movement happens
-- together or not at all.

local fibers = require('fibers')
local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Cell = require('fibers.resource.cell')
local Rendezvous = require('fibers.resource.rendezvous')
local Scope = require('fibers.scope')
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

local function append_log_op(cell, line)
  return cell:read_op():and_then(Op.guard(function(log)
    return cell:write_op(append_log(log, line))
  end))
end

local request = Scope.new('request')
local supervisor = Scope.new('supervisor')
local resume = Rendezvous.new('resume-session')
local registry = Cell.new({ custodian = 'request', task = '-' }, 'registry')
local audit = Cell.new({ text = '' }, 'audit')

local result = {}
local rt = Runtime.new()
rt:spawn_raw(function()
  local session = rt:perform(request:spawn_op(function()
    local msg = fibers.perform(resume:get_op())
    return 'session resumed with: ' .. msg
  end, { name = 'session' }))

  result.spawned_custodian = rt:perform(request:has_custody_op(session)) and 'request' or 'unknown'

  -- Without receiver participation, offer_op cannot close its custody-offer rendezvous.
  -- The fallback branch commits and custody remains with request.
  result.offer_without_accept = rt:perform(request
    :offer_op(session, supervisor)
    :map(function()
      return 'unexpected custody offer'
    end)
    :or_else(Op.always('no accept; no custody offer')))
  result.request_still_has_custody = rt:perform(request:has_custody_op(session))
  result.supervisor_has_custody_before = rt:perform(supervisor:has_custody_op(session))

  -- Now the receiver accepts.  Its acceptance is composed with its own registry
  -- and audit updates.  These updates commit iff custody moves.
  local rows = rt:perform(Op.together({
    request:offer_op(session, supervisor),
    supervisor:accept_op(),
    registry:write_op({ custodian = 'supervisor', task = session.name }),
    append_log_op(audit, 'accepted ' .. session.name .. ' from request into supervisor'),
  }))

  result.accepted = rows[2][1]
  result.request_has_custody_after = rt:perform(request:has_custody_op(session))
  result.supervisor_has_custody_after = rt:perform(supervisor:has_custody_op(session))
  result.registry_after = rt:perform(registry:read_op())
  result.audit_after = rt:perform(audit:read_op())

  rt:perform(resume:put_op('supervisor holds custody of the session'))
  result.await = { rt:perform(session:await_op()) }

  rt:perform(supervisor:close_op(session, 'session complete'))
  result.supervisor_has_custody_after_close = rt:perform(supervisor:has_custody_op(session))

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
assert(result.request_still_has_custody == true)
assert(result.supervisor_has_custody_before == false)
assert(result.request_has_custody_after == false)
assert(result.supervisor_has_custody_after == true)
assert(result.registry_after.custodian == 'supervisor')
assert(result.await[1] == 'session resumed with: supervisor holds custody of the session')
assert(result.supervisor_has_custody_after_close == false)

print('== negotiated scope custody offer ==')
print('spawned task custodian:          ' .. result.spawned_custodian)
print('offer without accept:        ' .. result.offer_without_accept)
print('request still has custody?     ' .. yn(result.request_still_has_custody))
print('supervisor has custody before?      ' .. yn(result.supervisor_has_custody_before))
print(
  'custody offer accepted:    '
    .. named(result.accepted.item)
    .. ' from '
    .. named(result.accepted.from)
    .. ' to '
    .. named(result.accepted.to)
)
print('request has custody after?          ' .. yn(result.request_has_custody_after))
print('supervisor has custody after?       ' .. yn(result.supervisor_has_custody_after))
print(
  'registry custodian after commit: '
    .. result.registry_after.custodian
    .. ' / '
    .. result.registry_after.task
)
print('task await result:            ' .. tostring(result.await[1]))
print('supervisor has custody after close? ' .. yn(result.supervisor_has_custody_after_close))
print('request sealed?              ' .. yn(result.request_state.sealed))
print('supervisor sealed?           ' .. yn(result.supervisor_state.sealed))
print('request custody count:         ' .. tostring(result.request_state.custody_count))
print('supervisor custody count:      ' .. tostring(result.supervisor_state.custody_count))
print('audit:')
print('  ' .. result.audit_after.text)
