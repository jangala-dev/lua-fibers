-- Compatibility boundary for the observed nixio.poll return forms.

local NixioPoll = {}

local function descriptor_number(value)
  if type(value) == 'number' then
    return value
  end
  if value and type(value.fileno) == 'function' then
    local ok, fd = pcall(value.fileno, value)
    if ok then
      return tonumber(fd)
    end
  end
  return nil
end

local function add_event(nixio, events, mode)
  if events == nil then
    return nixio.poll_flags(mode)
  end
  return nixio.poll_flags(events, mode)
end

local function native_events(nixio, record)
  local events
  if record.read then
    events = add_event(nixio, events, 'in')
  end
  if record.write then
    events = add_event(nixio, events, 'out')
  end
  return events
end

local function decoded_events(nixio, revents)
  local flags = nixio.poll_flags(revents or 0)
  return not not (flags['in'] or flags.hup or flags.err or flags.nval),
    not not (flags.out or flags.err or flags.nval)
end

local function collect(nixio, plan, source, positional, ready, merged)
  local observed = false
  for index, info in pairs(source or {}) do
    if type(info) == 'table' and (info.revents or 0) ~= 0 then
      observed = true
      local fd = descriptor_number(info.fd)
      local record = info._fibers_record or plan.by_key[info.fd] or (fd and plan.by_fd[fd])
      if not record and positional and type(index) == 'number' then
        record = plan.records[index]
      end
      if record then
        local readable, writable = decoded_events(nixio, info.revents)
        local item = merged[record]
        if not item then
          item = { record = record, read = false, write = false }
          merged[record] = item
          ready[#ready + 1] = item
        end
        item.read = item.read or readable
        item.write = item.write or writable
      end
    end
  end
  return observed
end

function NixioPoll.descriptor_number(value)
  return descriptor_number(value)
end

function NixioPoll.run(nixio, plan, timeout_ms)
  local poll_fds = {}
  for i = 1, #plan.records do
    local record = plan.records[i]
    poll_fds[i] = {
      fd = record.key,
      events = native_events(nixio, record),
      _fibers_record = record,
    }
  end

  local nready, returned = nixio.poll(poll_fds, timeout_ms)
  if nready == nil or nready == false then
    return nil, 'interrupted'
  end

  local ready, merged = {}, {}
  if nready > 0 then
    local observed = collect(nixio, plan, poll_fds, true, ready, merged)
    if not observed and type(returned) == 'table' and returned ~= poll_fds then
      collect(nixio, plan, returned, false, ready, merged)
    end
  end
  return ready, nready
end

return NixioPoll
