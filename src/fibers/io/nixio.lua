-- One Nixio binding.  Opaque Nixio objects are native handles; all
-- Fibers policy is supplied by fibers.io.posix.

local Posix = require('fibers.io.posix')
local NativeError = require('fibers.io.native_error')
local IOError = require('fibers.io.error')
local Address = require('fibers.net.address')

local ok_nixio, nixio = pcall(require, 'nixio')
local ok_fs, fs = pcall(require, 'nixio.fs')
if not ok_nixio or type(nixio) ~= 'table' then
  return Posix.unavailable('fibers.io.nixio', 'requires nixio')
end

local const = nixio.const or {}
local names = NativeError.names(const)
local native_error = NativeError.new({
  current_errno = nixio.errno, strerror = nixio.strerror, names = names, false_is_error = true,
})
local open_objects = setmetatable({}, { __mode = 'k' })

local function list_open_objects()
  local out = {}
  for value in pairs(open_objects) do
    out[#out + 1] = value
  end
  return out
end
local support_cache = {}

local split = native_error.split
local native_result = native_error.result
local native_status = native_error.status

local function no_error(a, b)
  if a == nil and b == nil then
    return true
  end
  local message, number = native_error.split(a, b)
  return number == nil
    or number == 0
    or type(message) == 'string' and message:match('^%s*[Ss]uccess%s*$') ~= nil
end

local fileno = NativeError.number

local function normalise_address(address)
  local ok, value = pcall(Address.validate, address, 'socket address')
  if ok then
    return value
  end
  return nil, IOError.invalid_argument('socket', 'address', { address = address })
end

local function encode(address)
  local value, err = normalise_address(address)
  if not value then
    return nil, err
  end
  if value.kind == 'inet4' then
    return { family = 'inet', native = { family = 'inet', host = value.host, port = value.port } }
  end
  if value.kind == 'inet6' then
    if value.scope_id ~= 0 or value.flowinfo ~= 0 then
      return nil, IOError.unsupported('socket', 'ipv6_scope_or_flowinfo', { address = value })
    end
    return { family = 'inet6', native = { family = 'inet6', host = value.host, port = value.port } }
  end
  return { family = 'unix', native = { family = 'unix', host = value.path } }
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
    if Address.is_numeric(value) then
      return Address.validate(value)
    end
    family, port, value = value.family or family, value.port or port, value.addr or value.host or value.path
  end
  if family == 'unix' then
    return Address.decode_unix(value)
  end
  if value == nil then
    return nil
  end
  if family == 'inet6' then
    return Address.ipv6(value, tonumber(port) or 0)
  end
  return Address.ipv4(value, tonumber(port) or 0)
end

local binding = {
  name = 'nixio',
  family = 'nixio',
  features = {
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

binding.time = {
  now = function()
    return uptime() or nixio.gettime()
  end,
  sleep = function(seconds)
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then
      return true
    end
    local deadline = binding.time.now() + seconds
    repeat
      local remaining = deadline - binding.time.now()
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

binding.poll = {
  poll_value = function(value)
    -- Native handles are wrapped by the shared descriptor layer as
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
      fds[i] = { fd = record.poll, events = events, _record = record }
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
          local record = info._record or plan.by_poll[info.fd] or (number and plan.by_fd[number])
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

binding.fd = {
  supported = function()
    return type(nixio.pipe) == 'function'
  end,
  validate = function(value)
    return assert(value, 'nixio handle object required')
  end,
  poll_value = function(value)
    return value
  end,
  number = fileno,
  opened = function(_, value)
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
  supports_shutdown = function(value)
    return value ~= nil and type(value.shutdown) == 'function'
  end,
  supports_close = function(value)
    return value ~= nil and type(value.close) == 'function'
  end,
  supports_nonblocking = function(value)
    return value ~= nil and type(value.setblocking) == 'function'
  end,
  shutdown = function(value, mode)
    if not value or type(value.shutdown) ~= 'function' then
      error('nixio descriptor does not support shutdown', 2)
    end
    return native_status(value:shutdown(mode == 'read' and 'rd' or 'wr'))
  end,
  close = function(value)
    if not value or type(value.close) ~= 'function' then
      error('nixio descriptor does not support close', 2)
    end
    local ok, a, b = value:close()
    if ok ~= nil and ok ~= false then
      open_objects[value] = nil
      return true
    end
    local message, number = split(a, b)
    return nil, number, message
  end,
  set_nonblocking = function(value, enabled)
    if not value or type(value.setblocking) ~= 'function' then
      error('nixio descriptor does not support nonblocking mode', 2)
    end
    return native_status(value:setblocking(not enabled))
  end,
  pipe = function()
    local reader, writer, a, b = nixio.pipe()
    if reader and writer then
      return reader, writer
    end
    local message, number = split(a, b)
    return nil, nil, number, message
  end,
}

local function supports(family, kind)
  local key = family .. ':' .. kind
  if support_cache[key] == nil then
    local ok, value = pcall(nixio.socket, family, kind)
    local supported = ok and value ~= nil and binding.fd.supported()
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

binding.net = {
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
    return native_result(nixio.socket(family, kind == 'datagram' and 'dgram' or 'stream'))
  end,
  set_option = function(value, level, name, enabled)
    if type(value.setopt) ~= 'function' then
      return true
    end
    local native_name = ({ reuse_address = 'reuseaddr', nodelay = 'nodelay' })[name] or name
    return native_status(value:setopt(level, native_name, enabled and 1 or 0))
  end,
  bind = function(value, address) return native_status(value:bind(address.host, address.port)) end,
  listen = function(value, backlog) return native_status(value:listen(backlog)) end,
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
  connect = function(value, address) return native_status(value:connect(address.host, address.port)) end,
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

binding.resolver = {
  supported = function()
    return type(nixio.getaddrinfo) == 'function'
  end,
  reason = 'Nixio getaddrinfo unavailable',
  query = function(_host, endpoint, opts)
    local requested = opts.family or endpoint.family_hint
    local family = requested == 'inet4' and 'inet' or requested == 'inet6' and 'inet6' or 'any'
    return native_result(nixio.getaddrinfo(endpoint.host, family, tostring(endpoint.service)))
  end,
  records = pairs,
  address = function(value, service)
    if type(value) ~= 'table' then
      return nil
    end
    local address =
      decode(value.address or value.addr or value.host, value.family, value.port or value.service)
    if address and address.port == 0 then
      return Address.with_port(address, tonumber(service) or 0)
    end
    return address
  end,
}

binding.process = function(Fd)
  local Reaper = require('fibers.io.process_reaper')
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
    message = binding.errors.message,
    name_of = binding.errors.name,
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
    close = binding.fd.close,
    read = binding.fd.read,
    write = function(value, bytes, offset)
      return binding.fd.write(value, bytes:sub((offset or 0) + 1))
    end,
    set_blocking = function(value, blocking)
      if type(value.setblocking) ~= 'function' then
        return true
      end
      return native_status(value:setblocking(blocking))
    end,
    environment = function() return native_result(nixio.getenv()) end,
    getcwd = nixio.getcwd,
    stat = function(path) return native_result(fs.stat(path, 'type')) end,
    access = function(path)
      local ok = fs.access(path, 'f', 'x')
      return not not ok
    end,
    pipe = binding.fd.pipe,
    fork = function() return native_result(nixio.fork()) end,
    wait = wait,
    exec = function(path, argv, env)
      local args = {}
      for i = 2, #argv do
        args[#args + 1] = tostring(argv[i])
      end
      return nixio.exece(path, args, env)
    end,
    exit = os.exit,
    chdir = function(path) return native_status(nixio.chdir(path)) end,
    setsid = function() return native_status(nixio.setsid()) end,
    stdio = {
      targets = { stdin = nixio.stdin, stdout = nixio.stdout, stderr = nixio.stderr },
      stdout = nixio.stdout,
      same = function(a, b)
        return a == b
      end,
      duplicate = function(source, target)
        return native_status(nixio.dup(source, target))
      end,
      open_null = function(which)
        return native_result(nixio.open('/dev/null', which == 'stdin' and 'r' or 'w'))
      end,
    },
    open_objects = list_open_objects,
    number = binding.fd.number,
    kill = function(pid, number) return native_status(nixio.kill(pid, number)) end,
  })
end

binding.is_supported = function()
  return binding.fd.supported()
    and type(nixio.gettime) == 'function'
    and type(nixio.nanosleep) == 'function'
    and type(nixio.poll) == 'function'
    and type(nixio.poll_flags) == 'function'
end

return Posix.define(binding)
