-- Shared Linux epoll host implementation for LuaJIT FFI and cffi.
--
-- Provider-specific modules load ffi/cffi explicitly and pass the provider into
-- this module.  This module does not auto-select an ffi provider.

local Host = require('fibers.host')
local HostError = require('fibers.host.error')
local Family = require('fibers.host.family')
local HostWait = require('fibers.host.wait')
local PollPlan = require('fibers.host.poll_plan')
local FfiNative = require('fibers.host.ffi_native')
local FdCommon = require('fibers.host._fd_ffi_common')

local Common = {}

local function make_unsupported(prefix, reason)
  return Family.unsupported(prefix, reason, { 'new' })
end

local function fd_of(key)
  if type(key) == 'number' then
    return key
  end
  if type(key) == 'string' and tonumber(key) then
    return tonumber(key)
  end
  if type(key) == 'table' then
    if type(key.fd) == 'number' then
      return key.fd
    end
    if type(key.fileno) == 'function' then
      return key:fileno()
    end
  end
  local n = tonumber(key)
  if n then
    return n
  end
  return nil
end

function Common.new(opts)
  opts = opts or {}
  local name = opts.name or 'ffi_linux'
  local prefix = opts.error_prefix or ('fibers.host.' .. name)
  local native = FfiNative.new(opts)
  local ffi, C, tonumber_c = native.ffi, native.C, native.number
  local bit = assert(native.bit, 'bit operations required')
  local fd_provider = FdCommon.new({ name = name .. '_fd', error_prefix = prefix .. '.fd', native = native })
  local socket_provider = require('fibers.host._socket_ffi_common').new({
    error_prefix = prefix .. '.socket',
    native = native,
    fd = fd_provider,
  })
  local resolver_provider = require('fibers.host._resolver_ffi_common').new({
    native = native,
  })
  local resolver_supported = opts.resolver_enabled ~= false and resolver_provider.is_supported()
  local process_provider = require('fibers.host._process_ffi_common').new({
    native = native,
    fd = fd_provider,
    error_prefix = prefix .. '.process',
  })
  local process_supported = process_provider.is_supported()
  local UringProvider = require('fibers.file.uring_provider')
  local AioProbe = require('fibers.file.aio_probe')
  local uring_supported = select(
    1,
    UringProvider.probe({
      ffi = ffi,
      C = C,
      arch = opts.arch or ffi.arch or (rawget(_G, 'jit') and jit.arch),
    })
  )
  local aio_supported = AioProbe.available(ffi, C)

  local ok_cdef, cdef_err = native.cdef([[
      typedef long time_t;
      struct timespec { time_t tv_sec; long tv_nsec; };

      int clock_gettime(int clk_id, struct timespec *tp);
      int nanosleep(const struct timespec *req, struct timespec *rem);

      typedef unsigned char      uint8_t;
      typedef unsigned int       uint32_t;
      typedef unsigned long long uint64_t;

      int epoll_create(int size);
      int epoll_create1(int flags);
      int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event);
      int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout);
      int close(int fd);
      char *strerror(int errnum);
    ]])
  if not ok_cdef then
    opts._cdef_err = cdef_err
  end

  local jit_ = rawget(_G, 'jit')
  local ARCH = opts.arch or ffi.arch or (jit_ and jit_.arch) or 'x64'

  local ok_arch, arch_err = pcall(function()
    if ARCH == 'x64' or ARCH == 'x86' then
      ffi.cdef([[ typedef struct epoll_event { uint8_t raw[12]; } epoll_event; ]])
    elseif ARCH == 'mips' or ARCH == 'mipsel' or ARCH == 'arm64' or ARCH == 'aarch64' then
      ffi.cdef([[ typedef struct epoll_event { uint32_t events; uint64_t data; } epoll_event; ]])
    else
      error('unsupported epoll_event architecture ' .. tostring(ARCH))
    end
  end)
  if not ok_arch then
    return make_unsupported(prefix, arch_err)
  end

  local CLOCK_MONOTONIC = 1
  local EINTR = 4
  local EPERM = 1
  local ENOENT = 2
  local EBADF = 9

  local EPOLL_CLOEXEC = 0x00080000
  local EPOLLIN = 0x00000001
  local EPOLLOUT = 0x00000004
  local EPOLLERR = 0x00000008
  local EPOLLHUP = 0x00000010
  local EPOLLRDHUP = 0x00002000
  local EPOLLONESHOT = bit.lshift(1, 30)

  local EPOLL_CTL_ADD = 1
  local EPOLL_CTL_DEL = 2
  local EPOLL_CTL_MOD = 3

  local RD = bit.bor(EPOLLIN, EPOLLRDHUP)
  local WR = EPOLLOUT
  local ERR = bit.bor(EPOLLERR, EPOLLHUP)

  local get_event, set_event, get_data, set_data
  if ARCH == 'x64' or ARCH == 'x86' then
    get_event = function(ev)
      return ffi.cast('uint32_t*', ev.raw)[0]
    end
    set_event = function(ev, value)
      ffi.cast('uint32_t*', ev.raw)[0] = value
    end
    get_data = function(ev)
      return ffi.cast('uint64_t*', ev.raw + 4)[0]
    end
    set_data = function(ev, value)
      ffi.cast('uint64_t*', ev.raw + 4)[0] = value
    end
  else
    get_event = function(ev)
      return ev.events
    end
    set_event = function(ev, value)
      ev.events = value
    end
    get_data = function(ev)
      return ev.data
    end
    set_data = function(ev, value)
      ev.data = value
    end
  end

  local errno = native.errno
  local strerror = native.strerror

  local function wrap_error(ret)
    local n = tonumber_c(ret)
    if n == -1 then
      local e = errno()
      return nil, strerror(e), e
    end
    return n, nil, nil
  end

  local function read_monotonic()
    local ts = ffi.new('struct timespec[1]')
    local rc = tonumber_c(C.clock_gettime(CLOCK_MONOTONIC, ts))
    if rc ~= 0 then
      error('clock_gettime(CLOCK_MONOTONIC) failed: ' .. strerror(errno()), 2)
    end
    return tonumber_c(ts[0].tv_sec) + tonumber_c(ts[0].tv_nsec) * 1e-9
  end

  local function sleep_seconds(dt)
    dt = tonumber(dt) or 0
    if dt <= 0 then
      return true
    end

    local req = ffi.new('struct timespec[1]')
    local rem = ffi.new('struct timespec[1]')
    local sec = math.floor(dt)
    local nsec = math.floor((dt - sec) * 1e9 + 0.5)
    if nsec >= 1000000000 then
      sec = sec + 1
      nsec = nsec - 1000000000
    end
    req[0].tv_sec = sec
    req[0].tv_nsec = nsec

    while true do
      local rc = tonumber_c(C.nanosleep(req, rem))
      if rc == 0 then
        return true
      end
      local e = errno()
      if e == EINTR then
        req[0].tv_sec = tonumber_c(rem[0].tv_sec)
        req[0].tv_nsec = tonumber_c(rem[0].tv_nsec)
      else
        return nil, 'nanosleep failed: ' .. strerror(e)
      end
    end
  end

  local function epoll_event_size()
    return ffi.sizeof('struct epoll_event')
  end

  local function validate_epoll_event_abi()
    local size = epoll_event_size()
    if (ARCH == 'x64' or ARCH == 'x86') and size ~= 12 then
      return nil,
        'unexpected epoll_event ABI size for ' .. tostring(ARCH) .. ': ' .. tostring(size) .. ' (expected 12)'
    end
    if size < 12 then
      return nil, 'unexpected epoll_event ABI size for ' .. tostring(ARCH) .. ': ' .. tostring(size)
    end
    return true
  end

  local function epoll_create()
    local first_err, first_eno
    local ok_call, ret = pcall(function()
      return C.epoll_create1(EPOLL_CLOEXEC)
    end)
    if ok_call then
      local fd, err, eno = wrap_error(ret)
      if fd then
        return fd
      end
      first_err, first_eno = err, eno
    else
      first_err = tostring(ret)
    end

    local fd, err, eno = wrap_error(C.epoll_create(1))
    if not fd then
      error(err or first_err or ('epoll_create failed: errno ' .. tostring(eno or first_eno)), 2)
    end
    return fd
  end

  local function epoll_ctl(epfd, op, fd, mask, token)
    local ev = nil
    if op ~= EPOLL_CTL_DEL then
      ev = ffi.new('struct epoll_event')
      set_event(ev, mask)
      set_data(ev, assert(token, 'epoll registration token required'))
    end
    return wrap_error(C.epoll_ctl(epfd, op, fd, ev))
  end

  local function epoll_wait(epfd, timeout_ms, maxevents)
    maxevents = math.max(1, tonumber(maxevents) or 1)
    local events = ffi.new('struct epoll_event[?]', maxevents)
    local n = tonumber_c(C.epoll_wait(epfd, events, maxevents, timeout_ms or 0))
    if n == -1 then
      local e = errno()
      if e == EINTR then
        return {}, nil, e
      end
      return nil, strerror(e), e
    end
    local out = {}
    for i = 0, n - 1 do
      out[#out + 1] = {
        token = assert(tonumber_c(get_data(events[i]))),
        mask = assert(tonumber_c(get_event(events[i]))),
      }
    end
    return out, nil, nil
  end

  local function mask_for(modes)
    local mask = 0
    if modes.read then
      mask = bit.bor(mask, RD)
    end
    if modes.write then
      mask = bit.bor(mask, WR)
    end
    if mask ~= 0 then
      mask = bit.bor(mask, EPOLLONESHOT)
    end
    return mask
  end

  local function support_probe()
    if opts._cdef_err then
      return nil, opts._cdef_err
    end
    local ok_abi, abi_err = validate_epoll_event_abi()
    if not ok_abi then
      return nil, abi_err
    end
    local ok_time, time_or_err = pcall(read_monotonic)
    if not ok_time then
      return nil, 'clock_gettime probe failed: ' .. tostring(time_or_err)
    end
    local ok_epoll, epfd_or_err = pcall(epoll_create)
    if not ok_epoll then
      return nil, 'epoll_create probe failed: ' .. tostring(epfd_or_err)
    end
    if epfd_or_err then
      pcall(function()
        C.close(epfd_or_err)
      end)
    end
    return true
  end

  local function create_host(new_opts)
    local ok_abi, abi_err = validate_epoll_event_abi()
    if not ok_abi then
      error(prefix .. ': ' .. tostring(abi_err), 2)
    end
    local maxevents = math.max(1, math.floor(tonumber(new_opts.maxevents) or 64))
    return {
      epfd = epoll_create(),
      maxevents = maxevents,
      active = {},
      epoll_by_token = {},
      next_epoll_token = 0,
      unpollable = {},
      poller_registrations = {},
      poller_by_fd = {},
      transient_fds = {},
      needs_rearm = {},
    }
  end

  local function capabilities()
    local sockets = socket_provider.is_supported()
    return {
      time = true,
      readiness = true,
      fd = fd_provider.is_supported(),
      pipe = fd_provider.is_supported(),
      socket = sockets,
      socket_ipv4 = sockets,
      socket_ipv6 = sockets,
      socket_unix = sockets,
      datagram = sockets,
      datagram_truncation = sockets,
      resolver = resolver_supported,
      resolver_blocking = resolver_supported,
      process = process_supported,
      file = uring_supported or process_supported,
      file_backend = uring_supported and 'io_uring' or (process_supported and 'worker' or nil),
      file_io_uring = uring_supported,
      file_aio_detected = aio_supported,
    }
  end

  local function file_provider(_self, runtime, provider_opts)
    if uring_supported then
      local provider = UringProvider.new(runtime, {
        ffi = ffi,
        C = C,
        fd = fd_provider,
        arch = opts.arch or ffi.arch or (rawget(_G, 'jit') and jit.arch),
        entries = provider_opts and provider_opts.ring_entries,
      })
      if provider and (type(provider.is_supported) ~= 'function' or provider:is_supported()) then
        return provider
      end
    end
    if process_supported then
      return require('fibers.file.worker_provider').new(runtime, provider_opts)
    end
  end

  local function delete_fd(self, fd)
    local active = self.active[fd]
    if not active then
      self.unpollable[fd] = nil
      return true
    end
    local ok, err, eno = epoll_ctl(self.epfd, EPOLL_CTL_DEL, fd)
    self.active[fd] = nil
    self.epoll_by_token[active.token] = nil
    self.unpollable[fd] = nil
    if ok or eno == ENOENT or eno == EBADF then
      return true
    end
    return nil, err or ('epoll_ctl DEL failed for fd ' .. tostring(fd))
  end

  local function delete_withdrawn(self, by_fd)
    local active_to_delete = {}
    for fd in pairs(self.active) do
      if not by_fd[fd] then
        active_to_delete[#active_to_delete + 1] = fd
      end
    end
    for i = 1, #active_to_delete do
      local ok, err = delete_fd(self, active_to_delete[i])
      if not ok then
        return nil, err
      end
    end

    local unpollable_to_delete = {}
    for fd in pairs(self.unpollable) do
      if not by_fd[fd] then
        unpollable_to_delete[#unpollable_to_delete + 1] = fd
      end
    end
    for i = 1, #unpollable_to_delete do
      self.unpollable[unpollable_to_delete[i]] = nil
    end
    return true
  end

  local function register_fd(self, fd, modes)
    if self.unpollable[fd] then
      return true, 'unpollable'
    end
    local mask = mask_for(modes)
    if mask == 0 then
      return true
    end

    self.next_epoll_token = self.next_epoll_token + 1
    local token = self.next_epoll_token
    local previous = self.active[fd]
    local function forget_closed()
      if previous then
        self.epoll_by_token[previous.token] = nil
      end
      self.active[fd] = nil
      self.unpollable[fd] = nil
      return true, 'closed'
    end

    local ok, err, eno = epoll_ctl(self.epfd, EPOLL_CTL_MOD, fd, mask, token)
    if ok then
      if previous then
        self.epoll_by_token[previous.token] = nil
      end
      self.active[fd] = { mask = mask, token = token }
      self.epoll_by_token[token] = { fd = fd, token = token }
      return true
    end
    if eno == EBADF then
      return forget_closed()
    end
    if eno == EPERM then
      if previous then
        self.epoll_by_token[previous.token] = nil
      end
      self.unpollable[fd] = true
      self.active[fd] = nil
      return true, 'unpollable'
    end

    local ok2, err2, eno2 = epoll_ctl(self.epfd, EPOLL_CTL_ADD, fd, mask, token)
    if ok2 then
      if previous then
        self.epoll_by_token[previous.token] = nil
      end
      self.active[fd] = { mask = mask, token = token }
      self.epoll_by_token[token] = { fd = fd, token = token }
      return true
    end
    if eno2 == EBADF then
      return forget_closed()
    end
    if eno2 == EPERM then
      if previous then
        self.epoll_by_token[previous.token] = nil
      end
      self.unpollable[fd] = true
      self.active[fd] = nil
      return true, 'unpollable'
    end

    return nil, err2 or err or ('epoll_ctl failed for fd ' .. tostring(fd))
  end

  local function add_poller_registration(self, wait, change, affected)
    local fd = fd_of(change.key)
    if not fd then
      return nil, 'unsupported-readiness-key'
    end
    local existing = self.poller_registrations[change.id]
    if existing then
      local old_fd = existing.fd
      local old_rec = self.poller_by_fd[old_fd]
      if old_rec then
        old_rec[change.id] = nil
        if next(old_rec) == nil then
          self.poller_by_fd[old_fd] = nil
        end
      end
      affected[old_fd] = true
    end
    local registration = {
      id = change.id,
      generation = change.generation,
      key = change.key,
      mode = change.mode,
      fd = fd,
      poller = wait.poller,
    }
    self.poller_registrations[change.id] = registration
    local rec = self.poller_by_fd[fd]
    if not rec then
      rec = {}
      self.poller_by_fd[fd] = rec
    end
    rec[change.id] = registration
    affected[fd] = true
    return true
  end

  local function remove_poller_registration(self, change, affected)
    local existing = self.poller_registrations[change.id]
    if not existing or existing.generation ~= change.generation then
      return true
    end
    self.poller_registrations[change.id] = nil
    local rec = self.poller_by_fd[existing.fd]
    if rec then
      rec[change.id] = nil
      if next(rec) == nil then
        self.poller_by_fd[existing.fd] = nil
      end
    end
    affected[existing.fd] = true
    return true
  end

  local function apply_poller_changes(self, waits, affected)
    local poller_waits = Host.poller_waits(waits)
    local waits_by_poller = {}
    for i = 1, #poller_waits do
      local wait = poller_waits[i]
      waits_by_poller[wait.poller] = wait
      local changes = wait.poller:_host_changes(self)
      for j = 1, #changes do
        local change = changes[j]
        if change.action == 'reset' then
          local remove = {}
          for id, registration in pairs(self.poller_registrations) do
            if registration.poller == wait.poller then
              remove[#remove + 1] = {
                id = id,
                generation = registration.generation,
              }
            end
          end
          for k = 1, #remove do
            remove_poller_registration(self, remove[k], affected)
          end
        elseif change.action == 'arm' then
          local ok, err = add_poller_registration(self, wait, change, affected)
          if not ok then
            return nil, err
          end
        elseif change.action == 'disarm' or change.action == 'retire' then
          remove_poller_registration(self, change, affected)
        end
      end
    end
    return waits_by_poller
  end

  local function desired_modes(self, fd, transient)
    local modes = {}
    local rec = transient[fd]
    if rec then
      modes.read = rec.read or nil
      modes.write = rec.write or nil
    end
    local poller = self.poller_by_fd[fd]
    if poller then
      for _, registration in pairs(poller) do
        modes[registration.mode] = true
      end
    end
    return modes
  end

  local function block(self, rt, waits, status, _opts)
    if not self.epfd then
      error(prefix .. ': host is closed', 2)
    end
    waits = waits or {}
    local deadline = Host.earliest_deadline(waits)
    local transient_plan = PollPlan.readiness(waits, { key_of = fd_of })
    local transient, unsupported = transient_plan.by_key, transient_plan.unsupported
    local affected = {}
    local stale = {}

    for fd in pairs(self.transient_fds) do
      affected[fd] = true
    end
    local next_transient = {}
    for fd in pairs(transient) do
      affected[fd] = true
      next_transient[fd] = true
    end
    self.transient_fds = next_transient

    local waits_by_poller, poller_err = apply_poller_changes(self, waits, affected)
    if not waits_by_poller then
      unsupported = true
    end
    for fd in pairs(self.needs_rearm) do
      affected[fd] = true
    end
    self.needs_rearm = {}

    for fd in pairs(affected) do
      local modes = desired_modes(self, fd, transient)
      if not modes.read and not modes.write then
        local ok, err = delete_fd(self, fd)
        if not ok then
          error(err, 2)
        end
      else
        local ok, err, class = register_fd(self, fd, modes)
        if not ok then
          error(err, 2)
        end
        if class == 'closed' or err == 'closed' then
          stale[fd] = bit.band(mask_for(modes), bit.bnot(EPOLLONESHOT))
        elseif (class == 'unpollable' or err == 'unpollable') and self.poller_by_fd[fd] then
          unsupported = true
        end
      end
    end

    if unsupported then
      if self.on_unsupported then
        self.on_unsupported(waits, status)
      end
      return nil, poller_err or 'unsupported-readiness-key'
    end

    -- Linux reports EPERM when regular files and certain other descriptors are
    -- added to epoll.  Preserve the direct-readiness contract by treating such
    -- transient waits as immediately serviceable: the subsequent authoritative
    -- host operation is responsible for reporting EOF or an error.  Indexed
    -- poller registrations remain unsupported for these handles because they
    -- are intended for genuinely non-blocking readiness-driven resources.
    local synthetic = stale
    for fd, rec in pairs(transient) do
      if self.unpollable[fd] and not self.poller_by_fd[fd] then
        synthetic[fd] = bit.band(mask_for(rec), bit.bnot(EPOLLONESHOT))
      end
    end

    local have_fd = next(self.active) ~= nil
    local have_synthetic = next(synthetic) ~= nil
    if not have_fd and not have_synthetic then
      return HostWait.block_without_io(self, rt, waits, status, deadline)
    end

    local timeout = Host.timeout_ms(rt, deadline)
    if have_synthetic then
      timeout = 0
    end

    local evmap = synthetic
    local polled = {}
    if have_fd then
      local err
      polled, err = epoll_wait(self.epfd, timeout, self.maxevents)
      if not polled then
        error(err or 'epoll_wait failed', 2)
      end
    end
    for i = 1, #polled do
      local event = polled[i]
      local token_record = self.epoll_by_token[event.token]
      if token_record then
        local active = self.active[token_record.fd]
        if active and active.token == event.token then
          local fd = token_record.fd
          evmap[fd] = bit.bor(evmap[fd] or 0, event.mask)
          self.needs_rearm[fd] = true
        end
      end
    end

    local delivered = false
    for fd, mask in pairs(evmap) do
      local rd = bit.band(mask, bit.bor(RD, ERR)) ~= 0
      local wr = bit.band(mask, bit.bor(WR, ERR)) ~= 0
      if PollPlan.deliver_waits(rt, transient[fd], rd, wr) then
        delivered = true
      end
      local poller = self.poller_by_fd[fd]
      if poller then
        for _, registration in pairs(poller) do
          local ready = registration.mode == 'write' and wr or rd
          local wait = waits_by_poller and waits_by_poller[registration.poller]
          if ready and wait and registration.poller:_host_delivered(registration) then
            Host.deliver_poller_ready(rt, wait, registration)
            delivered = true
          end
        end
      end
    end

    if delivered then
      return true, 'readiness'
    end
    if deadline ~= nil and rt:now() >= deadline then
      return true, 'time'
    end
    return true, 'poll'
  end

  local function close_host(self)
    if self.epfd then
      C.close(self.epfd)
      self.epfd = nil
    end
  end

  return Family.define({
    name = name,
    prefix = prefix,
    family = 'numeric-fd',
    fd = fd_provider,
    socket = socket_provider,
    datagram = socket_provider,
    resolver = resolver_supported and resolver_provider or nil,
    process = process_supported and process_provider or nil,
    is_supported = support_probe,
    support_reason = function()
      local _, reason = support_probe()
      return reason
    end,
    capability_builder = capabilities,
    create = create_host,
    now = read_monotonic,
    sleep = sleep_seconds,
    file_provider = file_provider,
    block = block,
    close = close_host,
    methods = {
      _delete = delete_fd,
      _delete_withdrawn = delete_withdrawn,
      _register = register_fd,
    },
  })
end

Common.unsupported = make_unsupported

return Common
