-- One Nixio provider table.  Opaque Nixio objects are native handles; all
-- Fibers policy is supplied by fibers.host.native.

local NativeError = require('fibers.host.native_error')
local HostError = require('fibers.host.error')

local ok_nixio, nixio = pcall(require, 'nixio')
local ok_fs, fs = pcall(require, 'nixio.fs')
if not ok_nixio or type(nixio) ~= 'table' then
  return { name = 'nixio', family = 'nixio', available = false, reason = 'requires nixio' }
end

local const = nixio.const or {}
local names = {}
for name, value in pairs(const) do
  if type(name) == 'string' and name:match('^E[A-Z0-9_]+$') and type(value) == 'number' then
    names[value] = names[value] or name
  end
end
local native_error =
  NativeError.new({ current_errno = nixio.errno, strerror = nixio.strerror, names = names })
local open_objects = setmetatable({}, { __mode = 'k' })
local support_cache = {}

local function split(a, b)
  local message, number = native_error.split(a, b)
  if number == nil and type(nixio.errno) == 'function' then
    number = tonumber(nixio.errno())
  end
  return message, number
end

local function no_error(a, b)
  if a == nil and b == nil then
    return true
  end
  local message, number = native_error.split(a, b)
  return number == nil
    or number == 0
    or type(message) == 'string' and message:match('^%s*[Ss]uccess%s*$') ~= nil
end

local function fileno(value)
  if type(value) == 'number' then
    return value
  end
  if value and type(value.fileno) == 'function' then
    local ok, result = pcall(value.fileno, value)
    return ok and tonumber(result) or nil
  end
end

local function encode(address)
  local kind = address and (address.kind or address.family)
  if kind == 'inet4' then
    return { family = 'inet', native = { family = 'inet', host = address.host, port = address.port } }
  end
  if kind == 'inet6' then
    if (tonumber(address.scope_id) or 0) ~= 0 or (tonumber(address.flowinfo) or 0) ~= 0 then
      return nil, HostError.unsupported('socket', 'ipv6_scope_or_flowinfo', { address = address })
    end
    return { family = 'inet6', native = { family = 'inet6', host = address.host, port = address.port } }
  end
  if kind == 'unix' then
    return { family = 'unix', native = { family = 'unix', host = address.path } }
  end
  return nil, HostError.invalid_argument('socket', 'address', { address = address })
end

local function native_address(value, port)
  if type(value) == 'table' then
    return value
  end
  if value ~= nil then
    return { host = value, port = port }
  end
  return nil
end

local function decode(value, family, port)
  if type(value) == 'table' then
    if value.kind == 'inet4' or value.kind == 'inet6' or value.kind == 'unix' then
      return value
    end
    family, port, value = value.family or family, value.port or port, value.addr or value.host or value.path
  end
  if family == 'unix' then
    return { kind = 'unix', family = 'unix', path = value }
  end
  if value == nil then
    return nil
  end
  if family == 'inet6' then
    return {
      kind = 'inet6',
      family = 'inet6',
      host = value,
      port = tonumber(port) or 0,
      flowinfo = 0,
      scope_id = 0,
    }
  end
  return { kind = 'inet4', family = 'inet4', host = value, port = tonumber(port) or 0 }
end

local provider = {
  name = 'nixio',
  family = 'nixio',
  capabilities = {
    datagram_truncation = false,
    process_exec_proof = false,
    process_pass_fds = false,
    process_close_fds = 'known',
    process_groups = 'session',
  },
  errors = {
    message = function(number)
      if number and type(nixio.strerror) == 'function' then
        return nixio.strerror(number)
      end
    end,
    name = function(number)
      return names[number]
    end,
    interrupted = { [const.EINTR or 4] = true },
    again = { [const.EAGAIN or 11] = true, [const.EWOULDBLOCK or const.EAGAIN or 11] = true },
    connect_pending = {
      [const.EINPROGRESS or 115] = true,
      [const.EALREADY or 114] = true,
      [const.EAGAIN or 11] = true,
      [const.EWOULDBLOCK or const.EAGAIN or 11] = true,
    },
    connected = { [const.EISCONN or 106] = true },
    message_too_large = { [const.EMSGSIZE or 90] = true },
  },
}

local function uptime()
  local file = io.open('/proc/uptime', 'r')
  if not file then
    return nil
  end
  local line = file:read('*l')
  file:close()
  return line and tonumber(line:match('^%s*(%S+)')) or nil
end

provider.time = {
  now = function()
    return uptime() or nixio.gettime()
  end,
  sleep = function(seconds)
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then
      return true
    end
    local deadline = provider.time.now() + seconds
    repeat
      local remaining = deadline - provider.time.now()
      if remaining <= 0 then
        return true
      end
      local sec = math.floor(remaining)
      local nsec = math.floor((remaining - sec) * 1e9 + 0.5)
      if nsec >= 1000000000 then
        sec, nsec = sec + 1, nsec - 1000000000
      end
      local ok, a, b = nixio.nanosleep(sec, nsec)
      if not ok then
        local message, number = split(a, b)
        if number ~= (const.EINTR or 4) then
          return nil, message or 'nixio.nanosleep failed'
        end
      end
    until false
  end,
}

local function poll_flags(events, mode)
  return events == nil and nixio.poll_flags(mode) or nixio.poll_flags(events, mode)
end

provider.poll = {
  key = function(value)
    -- Native handles are wrapped by the shared descriptor layer as
    -- { family = ..., fd = <opaque native handle>, generation = ... }.
    -- nixio.poll requires the opaque nixio object itself, not the Fibers key.
    if type(value) == 'table' then
      return value.fd or value.handle or value.nixio or value
    end
    return value
  end,
  number = fileno,
  wait = function(plan, timeout)
    local fds = {}
    for i = 1, #plan.records do
      local record, events = plan.records[i]
      if record.read then
        events = poll_flags(events, 'in')
      end
      if record.write then
        events = poll_flags(events, 'out')
      end
      fds[i] = { fd = record.key, events = events, _record = record }
    end
    local count, returned = nixio.poll(fds, timeout)
    if count == nil or count == false then
      return nil, 'poll-interrupted'
    end
    local out, merged = {}, {}
    local function collect(source, positional)
      for index, info in pairs(source or {}) do
        if type(info) == 'table' and (info.revents or 0) ~= 0 then
          local flags = nixio.poll_flags(info.revents)
          local number = fileno(info.fd)
          local record = info._record or plan.by_key[info.fd] or (number and plan.by_fd[number])
          if not record and positional and type(index) == 'number' then
            record = plan.records[index]
          end
          if record then
            local item = merged[record]
            if not item then
              item = { record = record, read = false, write = false }
              merged[record], out[#out + 1] = item, item
            end
            item.read = item.read or not not (flags['in'] or flags.hup or flags.err or flags.nval)
            item.write = item.write or not not (flags.out or flags.err or flags.nval)
          end
        end
      end
    end
    if count > 0 then
      collect(fds, true)
      if #out == 0 and type(returned) == 'table' and returned ~= fds then
        collect(returned, false)
      end
    end
    return out
  end,
}

provider.fd = {
  supported = function()
    return type(nixio.pipe) == 'function'
  end,
  validate = function(value)
    return assert(value, 'nixio handle object required')
  end,
  key = function(value)
    return value
  end,
  number = fileno,
  decorate = function(handle, value)
    handle.obj = value
    open_objects[value] = true
  end,
  read = function(value, maximum)
    local data, a, b = value:read(maximum)
    if type(data) == 'string' then
      return data
    end
    if data == false then
      local message, number = split(a, b)
      return nil, number or (const.EAGAIN or 11), message
    end
    if no_error(a, b) then
      return ''
    end
    local message, number = split(a, b)
    return nil, number, message
  end,
  write = function(value, bytes)
    local count, a, b
    if type(value.write) == 'function' then
      count, a, b = value:write(bytes, 0, #bytes)
    elseif type(value.send) == 'function' then
      count, a, b = value:send(bytes)
    else
      return nil, nil, 'write unsupported'
    end
    if type(count) == 'number' then
      return count
    end
    if count == true then
      return #bytes
    end
    local message, number = split(a, b)
    return nil, number, message
  end,
  shutdown = function(value, mode)
    -- The working Nixio integration treated shutdown as best effort.  Nixio
    -- builds differ in the errors returned for already-closed, anonymous and
    -- non-socket handles, so do not turn those differences into stream errors.
    if value and type(value.shutdown) == 'function' then
      pcall(value.shutdown, value, mode == 'read' and 'rd' or 'wr')
    end
    return true
  end,
  close = function(value)
    open_objects[value] = nil
    if not value or type(value.close) ~= 'function' then
      return true
    end
    local ok, a, b = value:close()
    if ok ~= nil and ok ~= false then
      return true
    end
    local message, number = split(a, b)
    return nil, number, message
  end,
  set_nonblocking = function(value, enabled)
    if not value or type(value.setblocking) ~= 'function' then
      return true
    end
    local ok, a, b = value:setblocking(not enabled)
    if ok ~= nil and ok ~= false then
      return true
    end
    local message, number = split(a, b)
    return nil, number, message
  end,
  pipe = function()
    local reader, writer, a, b = nixio.pipe()
    if reader and writer then
      return reader, writer
    end
    local message, number = split(a, b)
    return nil, nil, number, message
  end,
  extend = function(Fd)
    function Fd.open_objects()
      local out = {}
      for value in pairs(open_objects) do
        out[#out + 1] = value
      end
      return out
    end
  end,
}

local function supports(family, kind)
  local key = family .. ':' .. kind
  if support_cache[key] == nil then
    local ok, value = pcall(nixio.socket, family, kind)
    local supported = ok and value ~= nil and provider.fd.supported()
    if supported and kind == 'stream' then
      supported = type(value.bind) == 'function'
        and type(value.listen) == 'function'
        and type(value.accept) == 'function'
        and type(value.connect) == 'function'
        and type(value.getsockname) == 'function'
        and type(value.getpeername) == 'function'
    elseif supported and kind == 'dgram' then
      supported = type(value.bind) == 'function'
        and type(value.recvfrom) == 'function'
        and type(value.sendto) == 'function'
        and type(value.getsockname) == 'function'
    end
    support_cache[key] = not not supported
    if value then
      pcall(value.close, value)
    end
  end
  return support_cache[key]
end

provider.net = {
  datagram = true,
  reason = 'required Nixio socket operations unavailable',
  supports = function(kind)
    return supports(({ inet4 = 'inet', inet6 = 'inet6', unix = 'unix' })[kind] or kind, 'stream')
  end,
  encode = encode,
  decode = decode,
  is_unix = function(family)
    return family == 'unix'
  end,
  unlink = function(path)
    if path then
      os.remove(path)
    end
  end,
  open = function(family, kind)
    local value, a, b = nixio.socket(family, kind == 'datagram' and 'dgram' or 'stream')
    if value then
      return value
    end
    local message, number = split(a, b)
    return nil, number, message
  end,
  set_option = function(value, level, name, enabled)
    if type(value.setopt) ~= 'function' then
      return true
    end
    local native_name = ({ reuse_address = 'reuseaddr', nodelay = 'nodelay' })[name] or name
    local ok, a, b = value:setopt(level, native_name, enabled and 1 or 0)
    if ok ~= nil and ok ~= false then
      return true
    end
    local message, number = split(a, b)
    return nil, number, message
  end,
  bind = function(value, address)
    local ok, a, b = value:bind(address.host, address.port)
    if ok then
      return true
    end
    local message, number = split(a, b)
    return nil, number, message
  end,
  listen = function(value, backlog)
    local ok, a, b = value:listen(backlog)
    if ok then
      return true
    end
    local message, number = split(a, b)
    return nil, number, message
  end,
  accept = function(value)
    while true do
      local child, a, b = value:accept()
      if child then
        return child, native_address(a, b)
      end
      local message, number = split(a, b)
      if number ~= (const.EINTR or 4) then
        return nil, nil, number, message
      end
    end
  end,
  connect = function(value, address)
    local ok, a, b = value:connect(address.host, address.port)
    if ok then
      return true
    end
    local message, number = split(a, b)
    return nil, number, message
  end,
  socket_error = function(value)
    if type(value.getopt) ~= 'function' then
      return 0
    end
    local result, a, b = value:getopt('socket', 'error')
    if result ~= nil then
      return tonumber(result) or 0
    end
    local message, number = split(a, b)
    return number, message
  end,
  query = function(value, peer)
    -- Keep the calls in separate branches.  Nixio returns address and port as
    -- separate values; routing the calls through `and/or` collapses the second
    -- return in Lua and silently turns ephemeral listener ports into zero.
    local address, port
    if peer then
      address, port = value:getpeername()
    else
      address, port = value:getsockname()
    end
    if address == nil then
      return nil
    end
    if type(address) == 'table' then
      return address
    end
    return { host = address, port = port }
  end,
  receive = function(value, maximum)
    local requested = math.max(0, math.floor(tonumber(maximum) or 65535))
    local limit = math.min(requested, tonumber(const.buffersize) or 8192)
    local data, peer, port = value:recvfrom(limit)
    if data ~= nil then
      if type(data) ~= 'string' then
        return nil, nil, nil, const.EPROTO, 'nixio recvfrom returned non-string data'
      end
      return data, native_address(peer, port), { truncation_unknown = true, receive_limit = limit }
    end
    local message, number = split(peer, port)
    return nil, nil, nil, number, message
  end,
  send = function(value, data, address)
    local count, a, b = value:sendto(data, address.host, address.port, 0, #data)
    if count ~= nil and count ~= false then
      return count == true and #data or tonumber(count) or #data
    end
    local message, number = split(a, b)
    return nil, number, message
  end,
  prime = function(handle)
    handle:mark_readable()
    handle:mark_writable()
  end,
}

provider.resolver = {
  supported = function()
    return type(nixio.getaddrinfo) == 'function'
  end,
  reason = 'Nixio getaddrinfo unavailable',
  query = function(endpoint, opts)
    local requested = opts.family or endpoint.family_hint
    local family = requested == 'inet4' and 'inet' or requested == 'inet6' and 'inet6' or 'any'
    local records, a, b = nixio.getaddrinfo(endpoint.host, family, tostring(endpoint.service))
    if records then
      return records
    end
    local message, number = split(a, b)
    return nil, number, message
  end,
  records = pairs,
  address = function(value, service)
    if type(value) ~= 'table' then
      return nil
    end
    local address =
      decode(value.address or value.addr or value.host, value.family, value.port or value.service)
    if address and address.port == 0 then
      address.port = tonumber(service) or 0
    end
    return address
  end,
}

provider.process = function(Fd)
  local Reaper = require('fibers.host.process_reaper')
  local function supported()
    if not ok_fs or type(fs) ~= 'table' then
      return false, 'requires nixio.fs'
    end
    local required = {
      fork = nixio.fork,
      waitpid = nixio.waitpid,
      exece = nixio.exece,
      pipe = nixio.pipe,
      open = nixio.open,
      dup = nixio.dup,
      kill = nixio.kill,
      chdir = nixio.chdir,
      getenv = nixio.getenv,
      setsid = nixio.setsid,
      access = fs.access,
      stat = fs.stat,
    }
    for name, value in pairs(required) do
      if type(value) ~= 'function' then
        return false, 'required Nixio process function unavailable: ' .. name
      end
    end
    return Fd.is_supported()
  end
  local function wait(pid, nonblocking)
    while true do
      local got, how, value
      if nonblocking then
        got, how, value = nixio.waitpid(pid, 'nohang')
      else
        got, how, value = nixio.waitpid(pid)
      end
      if got == false or got == 0 then
        return { kind = 'running' }
      end
      if got == nil then
        if no_error(how, value) and nonblocking then
          return { kind = 'running' }
        end
        local message, number = split(how, value)
        if number ~= (const.EINTR or 4) then
          return nil, number, message
        end
      elseif how == 'exited' then
        return { kind = 'exited', code = value }
      elseif how == 'killed' or how == 'signaled' or how == 'signalled' then
        return { kind = 'signalled', signal = value }
      elseif how == 'stopped' then
        return { kind = 'stopped' }
      else
        return nil, const.EINVAL, 'unexpected wait status ' .. tostring(how)
      end
    end
  end
  return Reaper.new({
    name = 'nixio',
    Fd = Fd,
    signals = {
      hup = const.SIGHUP,
      int = const.SIGINT,
      quit = const.SIGQUIT,
      kill = const.SIGKILL,
      usr1 = const.SIGUSR1,
      usr2 = const.SIGUSR2,
      pipe = const.SIGPIPE,
      alrm = const.SIGALRM,
      term = const.SIGTERM,
      chld = const.SIGCHLD,
      cont = const.SIGCONT,
      stop = const.SIGSTOP,
    },
    supported = supported,
    message = provider.errors.message,
    name_of = provider.errors.name,
    enoent = const.ENOENT,
    buffer_size = tonumber(const.buffersize) or 512,
    interrupted = function(number)
      return number == (const.EINTR or 4)
    end,
    again = function(number)
      return number == (const.EAGAIN or 11) or number == (const.EWOULDBLOCK or const.EAGAIN or 11)
    end,
    no_error = function(number, message)
      return number == nil
        or number == 0
        or type(message) == 'string' and message:match('^%s*[Ss]uccess%s*$') ~= nil
    end,
    close = provider.fd.close,
    read = provider.fd.read,
    write = function(value, bytes, offset)
      return provider.fd.write(value, bytes:sub((offset or 0) + 1))
    end,
    set_blocking = function(value, blocking)
      if type(value.setblocking) ~= 'function' then
        return true
      end
      local ok, a, b = value:setblocking(blocking)
      if ok ~= nil and ok ~= false then
        return true
      end
      local message, number = split(a, b)
      return nil, number, message
    end,
    environment = function()
      local value, a, b = nixio.getenv()
      if value then
        return value
      end
      local message, number = split(a, b)
      return nil, number, message
    end,
    getcwd = nixio.getcwd,
    stat = function(path)
      local kind, a, b = fs.stat(path, 'type')
      if kind then
        return kind
      end
      local message, number = split(a, b)
      return nil, number, message
    end,
    access = function(path)
      local ok = fs.access(path, 'f', 'x')
      return not not ok
    end,
    pipe = provider.fd.pipe,
    fork = function()
      local pid, a, b = nixio.fork()
      if pid ~= nil then
        return pid
      end
      local message, number = split(a, b)
      return nil, number, message
    end,
    wait = wait,
    exec = function(path, argv, env)
      local args = {}
      for i = 2, #argv do
        args[#args + 1] = tostring(argv[i])
      end
      return nixio.exece(path, args, env)
    end,
    exit = os.exit,
    chdir = function(path)
      local ok, a, b = nixio.chdir(path)
      if ok then
        return true
      end
      local _, number = split(a, b)
      return nil, number
    end,
    setsid = function()
      local ok, a, b = nixio.setsid()
      if ok then
        return true
      end
      local _, number = split(a, b)
      return nil, number
    end,
    stdio = {
      targets = { stdin = nixio.stdin, stdout = nixio.stdout, stderr = nixio.stderr },
      stdout = nixio.stdout,
      same = function(a, b)
        return a == b
      end,
      duplicate = function(source, target)
        local value, a, b = nixio.dup(source, target)
        if value then
          return true
        end
        local message, number = split(a, b)
        return nil, number, message
      end,
      open_null = function(which)
        local value, a, b = nixio.open('/dev/null', which == 'stdin' and 'r' or 'w')
        if value then
          return value
        end
        local message, number = split(a, b)
        return nil, number, message
      end,
    },
    open_objects = Fd.open_objects,
    number = provider.fd.number,
    kill = function(pid, number)
      local ok, a, b = nixio.kill(pid, number)
      if ok then
        return true
      end
      local message, errno = split(a, b)
      return nil, errno, message
    end,
  })
end

provider.is_supported = function()
  return provider.fd.supported()
    and type(nixio.gettime) == 'function'
    and type(nixio.nanosleep) == 'function'
    and type(nixio.poll) == 'function'
    and type(nixio.poll_flags) == 'function'
end

return provider
