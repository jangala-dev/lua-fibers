-- Canonical host wait collection, polling plan and delivery.
--
-- A WaitSet scans the runtime's typed waits once.  It records the earliest
-- timer, groups direct readiness waits with reactor poller registrations, and
-- delivers one host observation back through the appropriate external feeds.

local WaitSet = {}

local function finite(value)
  return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

function WaitSet.normalise_mode(mode)
  mode = mode or 'read'
  if mode ~= 'read' and mode ~= 'write' then
    error('readiness mode must be read or write', 2)
  end
  return mode
end

function WaitSet.build(waits)
  waits = waits or {}
  local by_key = {}
  local set = { records = {}, by_poll = {}, by_fd = {}, deadline = nil, unsupported = false }

  local function ensure(key)
    if key == nil then
      set.unsupported = true
      return nil
    end
    local record = by_key[key]
    if record then
      return record
    end
    local poll = type(key) == 'table' and key.poll or key
    local number = type(key) == 'table' and key.number or nil
    if poll == nil then
      set.unsupported = true
      return nil
    end
    record = {
      key = key,
      poll = poll,
      fd = number,
      read = false,
      write = false,
      waits = {},
      poller = {},
    }
    by_key[key] = record
    set.by_poll[poll] = record
    if number ~= nil then
      set.by_fd[number] = record
    end
    set.records[#set.records + 1] = record
    return record
  end

  for i = 1, #waits do
    local wait = waits[i]
    if wait and wait.kind == 'timer' then
      local deadline = wait.deadline
      if finite(deadline) and (set.deadline == nil or deadline < set.deadline) then
        set.deadline = deadline
      end
    elseif wait then
      if wait.kind == 'external' and wait.feed then
        if wait.external_kind == 'readiness' and wait.resource then
          local record = ensure(wait.readiness_key)
          if record then
            record[WaitSet.normalise_mode(wait.mode)] = true
            record.waits[#record.waits + 1] = wait
          end
        elseif wait.external_kind == 'poller' and wait.poller then
          local registrations = wait.poller:_host_active()
          for j = 1, #registrations do
            local registration = registrations[j]
            local record = ensure(registration.key)
            if record then
              record[WaitSet.normalise_mode(registration.mode)] = true
              record.poller[#record.poller + 1] = { wait = wait, registration = registration }
            end
          end
        end
      end
    end
  end
  return set
end

function WaitSet.readiness_waits(waits)
  local out = {}
  for i = 1, #(waits or {}) do
    local wait = waits[i]
    if
      wait
      and wait.kind == 'external'
      and wait.external_kind == 'readiness'
      and wait.resource
      and wait.feed
    then
      out[#out + 1] = wait
    end
  end
  return out
end

function WaitSet.delay_until(runtime, deadline)
  if deadline == nil then
    return nil
  end
  return math.max(0, deadline - runtime:now())
end

function WaitSet.timeout_ms(runtime, set)
  if set.deadline == nil then return -1 end
  return math.max(0, math.ceil((WaitSet.delay_until(runtime, set.deadline) or 0) * 1000))
end

function WaitSet.deliver(record, readable, writable)
  if not record then
    return false
  end
  local delivered = false
  for i = 1, #record.waits do
    local wait = record.waits[i]
    local mode = WaitSet.normalise_mode(wait.mode)
    if mode == 'write' and writable or mode == 'read' and readable then
      wait.feed:set(mode, true)
      delivered = true
    end
  end
  for i = 1, #record.poller do
    local item = record.poller[i]
    local registration = item.registration
    local ready = registration.mode == 'write' and writable or readable
    if ready and item.wait.poller:_host_delivered(registration) then
      item.wait.feed:set(
        registration.id,
        registration.generation,
        registration.mode,
        registration.key
      )
      delivered = true
    end
  end
  return delivered
end

function WaitSet.block_without_io(host, runtime, set)
  if set.deadline ~= nil then
    local delay = WaitSet.delay_until(runtime, set.deadline) or 0
    if delay > 0 then
      local ok, err = host:sleep(delay)
      if not ok then
        error(err, 3)
      end
    end
    return true, 'time'
  end
  return nil, 'unsupported-waits'
end

return WaitSet
