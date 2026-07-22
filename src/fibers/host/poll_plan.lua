-- Provider-neutral collection and delivery of readiness interests.

local Host = require('fibers.host')

local PollPlan = {}

local function identity(value)
  return value
end

function PollPlan.readiness(waits, opts)
  opts = opts or {}
  local key_of = opts.key_of or identity
  local fd_of = opts.fd_of
  local records, by_key, by_fd = {}, {}, {}
  local unsupported = false
  local function ensure(source_key)
    local key = key_of(source_key)
    if key == nil then
      unsupported = true
      return nil
    end
    local record = by_key[key]
    if record then
      return record
    end
    record =
      { key = key, fd = fd_of and fd_of(key) or nil, read = false, write = false, waits = {}, poller = {} }
    by_key[key] = record
    if record.fd ~= nil then
      by_fd[record.fd] = record
    end
    records[#records + 1] = record
    return record
  end
  local readiness = Host.readiness_waits(waits)
  for i = 1, #readiness do
    local wait = readiness[i]
    local record = ensure(wait.readiness_key)
    if record then
      record[Host.normalise_readiness_mode(wait.mode)] = true
      record.waits[#record.waits + 1] = wait
    end
  end
  return { records = records, by_key = by_key, by_fd = by_fd, unsupported = unsupported, ensure = ensure }
end

function PollPlan.build(waits, opts)
  local plan = PollPlan.readiness(waits, opts)
  local poller_waits = Host.poller_waits(waits)
  for i = 1, #poller_waits do
    local wait = poller_waits[i]
    local registrations = wait.poller:_host_active()
    for j = 1, #registrations do
      local registration = registrations[j]
      local record = plan.ensure(registration.key)
      if record then
        record[Host.normalise_readiness_mode(registration.mode)] = true
        record.poller[#record.poller + 1] = { wait = wait, registration = registration }
      end
    end
  end
  plan.ensure = nil
  return plan
end

function PollPlan.deliver_waits(rt, record, readable, writable)
  if not record then
    return false
  end
  local delivered = false
  for i = 1, #record.waits do
    local wait = record.waits[i]
    local mode = Host.normalise_readiness_mode(wait.mode)
    if mode == 'write' and writable or mode == 'read' and readable then
      rt:deliver(wait.feed, mode, true)
      delivered = true
    end
  end
  return delivered
end

function PollPlan.deliver(rt, record, readable, writable)
  if not record then
    return false
  end
  local delivered = PollPlan.deliver_waits(rt, record, readable, writable)
  for i = 1, #record.poller do
    local item = record.poller[i]
    local registration = item.registration
    local ready = registration.mode == 'write' and writable or readable
    if ready and item.wait.poller:_host_delivered(registration) then
      Host.deliver_poller_ready(rt, item.wait, registration)
      delivered = true
    end
  end
  return delivered
end

return PollPlan
