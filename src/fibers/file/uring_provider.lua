-- Linux io_uring regular-file provider using raw syscalls and mmap.
--
-- The implementation deliberately uses only the stable 64-byte SQE and
-- 16-byte CQE ABI. It supports the complete version-1 file surface without
-- issuing blocking filesystem calls on the runtime thread.

local Signal = require('fibers.resource.signal')
local IOError = require('fibers.io.error')
local External = require('fibers.embed.external')
local Reactor = require('fibers.io.reactor')
local perform = require('fibers.perform')

local Provider = {}
Provider.__index = Provider
local Backend = {}
Backend.__index = Backend
local cdef_done = setmetatable({}, { __mode = 'k' })

local function syscall_numbers(arch)
  if arch == 'x64' or arch == 'x86' or arch == 'arm64' or arch == 'aarch64' then
    return 425, 426
  end
  return nil
end

local function cdef(ffi)
  if cdef_done[ffi] then
    return true
  end
  local ok, err = pcall(function()
    ffi.cdef([[
      typedef unsigned char fibers_u8;
      typedef unsigned short fibers_u16;
      typedef unsigned int fibers_u32;
      typedef signed int fibers_i32;
      typedef signed long long fibers_i64;
      typedef unsigned long fibers_uintptr;
      typedef unsigned long long fibers_u64;
      struct fibers_io_sqring_offsets {
        fibers_u32 head, tail, ring_mask, ring_entries, flags, dropped, array, resv1;
        fibers_u64 user_addr;
      };
      struct fibers_io_cqring_offsets {
        fibers_u32 head, tail, ring_mask, ring_entries, overflow, cqes, flags, resv1;
        fibers_u64 user_addr;
      };
      struct fibers_io_uring_params {
        fibers_u32 sq_entries, cq_entries, flags, sq_thread_cpu, sq_thread_idle,
          features, wq_fd, resv[3];
        struct fibers_io_sqring_offsets sq_off;
        struct fibers_io_cqring_offsets cq_off;
      };
      long syscall(long number, ...);
      void *mmap(void *, unsigned long, int, int, int, long);
      int munmap(void *, unsigned long);
      int close(int);
      char *strerror(int);
      fibers_u32 __atomic_load_4(const volatile void *, int);
      void __atomic_store_4(volatile void *, fibers_u32, int);
    ]])
  end)
  if ok then
    cdef_done[ffi] = true
  end
  return ok, err
end

local function ptr_add(ffi, ptr, offset)
  return ffi.cast('fibers_u8*', ptr) + tonumber(offset)
end
local function u8(ffi, p, o)
  return ffi.cast('fibers_u8*', ptr_add(ffi, p, o))
end
local function u32(ffi, p, o)
  return ffi.cast('volatile fibers_u32*', ptr_add(ffi, p, o))
end
local function i32(ffi, p, o)
  return ffi.cast('fibers_i32*', ptr_add(ffi, p, o))
end
local function i64(ffi, p, o)
  return ffi.cast('fibers_i64*', ptr_add(ffi, p, o))
end
local function u64(ffi, p, o)
  return ffi.cast('fibers_u64*', ptr_add(ffi, p, o))
end

-- cffi-lua represents unsigned 64-bit scalars as userdata and tonumber()
-- returns nil for them. Values which Fibers needs as Lua integers are within
-- the signed 64-bit range, so read the same ABI bits through an i64 view.
local function i64_number(ffi, p, o)
  return tonumber(i64(ffi, p, o)[0])
end

local ATOMIC_ACQUIRE, ATOMIC_RELEASE = 2, 3

local function atomic_u32(ffi, arch)
  if type(ffi.load) == 'function' then
    local loaded, atomic = pcall(ffi.load, 'atomic')
    if not loaded then loaded, atomic = pcall(ffi.load, 'libatomic.so.1') end
    if loaded then
      local symbols = pcall(function()
        return atomic.__atomic_load_4, atomic.__atomic_store_4
      end)
      if symbols then
        return {
          library = atomic,
          load_acquire = function(ptr)
            return tonumber(atomic.__atomic_load_4(ptr, ATOMIC_ACQUIRE))
          end,
          store_release = function(ptr, value)
            atomic.__atomic_store_4(ptr, value, ATOMIC_RELEASE)
          end,
        }
      end
    end
  end

  -- x86 TSO plus volatile ring indices is sufficient for the acquire/release
  -- relations used by the io_uring rings. Weak-memory targets require a real
  -- atomic primitive; without one the provider is disabled and the host falls
  -- back to the worker backend.
  if arch == 'x64' or arch == 'x86' then
    return {
      load_acquire = function(ptr) return tonumber(ptr[0]) end,
      store_release = function(ptr, value) ptr[0] = value end,
    }
  end
  return nil, 'libatomic is required for io_uring ring ordering on ' .. tostring(arch)
end

local function setup_ring(ffi, C, number, entries, params)
  return tonumber(C.syscall(ffi.cast('long', number), ffi.cast('unsigned int', entries), params))
end

local function enter_ring(ffi, C, number, fd, to_submit, min_complete, flags)
  return tonumber(
    C.syscall(
      ffi.cast('long', number),
      ffi.cast('int', fd),
      ffi.cast('unsigned int', to_submit or 0),
      ffi.cast('unsigned int', min_complete or 0),
      ffi.cast('unsigned int', flags or 0),
      ffi.cast('void*', nil),
      ffi.cast('unsigned long', 0)
    )
  )
end

local IORING_OFF_SQ_RING = 0
local IORING_OFF_CQ_RING = 0x08000000
local IORING_OFF_SQES = 0x10000000
local IORING_FEAT_SINGLE_MMAP = 1
local IORING_ENTER_GETEVENTS = 1
local PROT_READ, PROT_WRITE = 1, 2
local MAP_SHARED = 1
local AT_FDCWD = -100
local AT_EMPTY_PATH = 0x1000

local OP_FSYNC = 3
local OP_OPENAT = 18
local OP_CLOSE = 19
local OP_STATX = 21
local OP_READ = 22
local OP_WRITE = 23
local OP_RENAMEAT = 35
local OP_UNLINKAT = 36
local OP_MKDIRAT = 37

local O_RDONLY = 0
local O_WRONLY = 1
local O_RDWR = 2
local O_CREAT = 64
local O_EXCL = 128
local O_TRUNC = 512
local O_APPEND = 1024
local O_CLOEXEC = 0x80000

local function mode_flags(mode, opts)
  local flags
  if mode == 'r' or mode == 'rb' then
    flags = O_RDONLY
  elseif mode == 'w' or mode == 'wb' then
    flags = O_WRONLY + O_CREAT + O_TRUNC
  elseif mode == 'a' or mode == 'ab' then
    flags = O_WRONLY + O_CREAT + O_APPEND
  elseif mode == 'r+' or mode == 'r+b' or mode == 'rb+' then
    flags = O_RDWR
  elseif mode == 'w+' or mode == 'w+b' or mode == 'wb+' then
    flags = O_RDWR + O_CREAT + O_TRUNC
  elseif mode == 'a+' or mode == 'a+b' or mode == 'ab+' then
    flags = O_RDWR + O_CREAT + O_APPEND
  end
  if flags and opts and opts.exclusive then
    flags = flags + O_EXCL
  end
  return flags and (flags + O_CLOEXEC), mode and mode:sub(1, 1) == 'a'
end

local function errno_message(self, eno)
  local ptr = self.C.strerror(eno)
  return ptr ~= nil and self.ffi.string(ptr) or ('errno ' .. tostring(eno))
end
local function result_error(self, action, res, fields)
  local eno = -tonumber(res)
  return IOError.system('file', action, errno_message(self, eno), nil, eno, fields)
end
local function path_buffer(ffi, path)
  local buf = ffi.new('char[?]', #path + 1)
  ffi.copy(buf, path, #path)
  return buf
end

local function map(self, size, offset)
  local p = self.C.mmap(nil, size, PROT_READ + PROT_WRITE, MAP_SHARED, self.fd, offset)
  local failed = self.ffi.cast('void*', -1)
  if p == nil or p == failed then
    return nil
  end
  return p
end

function Provider.probe(opts)
  opts = opts or {}
  local ffi, C = opts.ffi, opts.C
  if not ffi or not C then
    return false, 'ffi unavailable'
  end
  local ok_cdef, cdef_err = cdef(ffi)
  if not ok_cdef then
    return false, tostring(cdef_err)
  end
  local arch = opts.arch or ffi.arch or (rawget(_G, 'jit') and jit.arch)
  local setup = select(1, syscall_numbers(arch))
  if not setup then
    return false, 'unsupported architecture'
  end
  local atomics, atomic_err = atomic_u32(ffi, arch)
  if not atomics then return false, atomic_err end
  local params = ffi.new('struct fibers_io_uring_params[1]')
  local fd = setup_ring(ffi, C, setup, 2, params)
  if fd and fd >= 0 then
    C.close(fd)
    return true
  end
  local eno = ffi.errno and ffi.errno() or nil
  return false, eno and ('io_uring_setup errno ' .. tostring(eno)) or 'io_uring_setup failed'
end

function Provider.new(runtime, opts)
  opts = opts or {}
  local ffi, C = assert(opts.ffi), assert(opts.C)
  local ok_cdef, cdef_err = cdef(ffi)
  if not ok_cdef then
    return nil, tostring(cdef_err)
  end
  local arch = opts.arch or ffi.arch or (rawget(_G, 'jit') and jit.arch)
  local setup_nr, enter_nr = syscall_numbers(arch)
  if not setup_nr then
    return nil, 'unsupported io_uring architecture'
  end
  local atomics, atomic_err = atomic_u32(ffi, arch)
  if not atomics then return nil, atomic_err end
  local self = setmetatable({
    ffi = ffi,
    C = C,
    fd_provider = assert(opts.fd),
    setup_nr = setup_nr,
    enter_nr = enter_nr,
    atomics = atomics,
    pending = {},
    next_id = 0,
    closed = false,
    name = 'io_uring',
  }, Provider)
  local params = ffi.new('struct fibers_io_uring_params[1]')
  local entries = opts.entries or 64
  local fd = setup_ring(ffi, C, setup_nr, entries, params)
  if not fd or fd < 0 then
    return nil, 'io_uring_setup failed'
  end
  self.fd = fd
  self.params = params
  local p = params[0]
  local sq_size = tonumber(p.sq_off.array) + tonumber(p.sq_entries) * 4
  local cq_size = tonumber(p.cq_off.cqes) + tonumber(p.cq_entries) * 16
  if tonumber(p.features) % (IORING_FEAT_SINGLE_MMAP * 2) >= IORING_FEAT_SINGLE_MMAP then
    local size = math.max(sq_size, cq_size)
    local base = map(self, size, IORING_OFF_SQ_RING)
    if not base then
      C.close(fd)
      return nil, 'io_uring SQ/CQ mmap failed'
    end
    self.sq_ring, self.cq_ring, self.sq_map_size, self.cq_map_size = base, base, size, 0
  else
    self.sq_ring = map(self, sq_size, IORING_OFF_SQ_RING)
    self.cq_ring = map(self, cq_size, IORING_OFF_CQ_RING)
    self.sq_map_size, self.cq_map_size = sq_size, cq_size
    if not self.sq_ring or not self.cq_ring then
      if self.sq_ring then
        C.munmap(self.sq_ring, sq_size)
      end
      if self.cq_ring then
        C.munmap(self.cq_ring, cq_size)
      end
      C.close(fd)
      return nil, 'io_uring ring mmap failed'
    end
  end
  self.sqes_size = tonumber(p.sq_entries) * 64
  self.sqes = map(self, self.sqes_size, IORING_OFF_SQES)
  if not self.sqes then
    self:shutdown()
    return nil, 'io_uring SQE mmap failed'
  end
  self.sq_head = u32(ffi, self.sq_ring, p.sq_off.head)
  self.sq_tail = u32(ffi, self.sq_ring, p.sq_off.tail)
  self.sq_mask = u32(ffi, self.sq_ring, p.sq_off.ring_mask)
  self.sq_entries = u32(ffi, self.sq_ring, p.sq_off.ring_entries)
  self.sq_array = u32(ffi, self.sq_ring, p.sq_off.array)
  self.cq_head = u32(ffi, self.cq_ring, p.cq_off.head)
  self.cq_tail = u32(ffi, self.cq_ring, p.cq_off.tail)
  self.cq_mask = u32(ffi, self.cq_ring, p.cq_off.ring_mask)
  self.cqes = ptr_add(ffi, self.cq_ring, p.cq_off.cqes)
  local handle, err = self.fd_provider.new(fd, {
    host = runtime.host,
    nonblocking = true,
    cloexec = true,
  })
  if not handle then
    self:shutdown()
    return nil, err
  end
  self.handle = handle
  self.reactor = Reactor.for_runtime(runtime)
  return self
end

function Provider:is_supported()
  return not self.closed
end

local function completion_entry_live(entry)
  return entry ~= nil and not entry.retired
end

function Provider:_retire_completion_entry_if_idle(reason)
  if next(self.pending) ~= nil then return true end
  local entry = self.completion_entry
  if not completion_entry_live(entry) then
    self.completion_entry = nil
    return true
  end
  local ok, err = perform(entry:retire_op(reason or 'io_uring idle'))
  if self.completion_entry == entry then self.completion_entry = nil end
  return ok, err
end

function Provider:_retire_completion_entry_direct_if_idle(reason)
  if next(self.pending) ~= nil then return true end
  local entry = self.completion_entry
  if not completion_entry_live(entry) then
    self.completion_entry = nil
    return true
  end
  -- Reactor callbacks cannot perform. Direct retirement is safe here because
  -- the reactor task is itself executing and will observe the now-empty entry
  -- set before it waits again.
  local ok, err = self.reactor:_retire_entry(entry, reason or 'io_uring idle')
  if self.completion_entry == entry then self.completion_entry = nil end
  return ok, err
end

function Provider:_ensure_completion_entry()
  if completion_entry_live(self.completion_entry) then return true end

  local entry
  entry = self.reactor:callback({
    label = 'file-io-uring-completions',
    mode = 'read',
    handle = self.handle,
    callback = function(registered_handle)
      if type(registered_handle.clear_readable) == 'function' then
        registered_handle:clear_readable()
      end
      local drained = self:_drain()
      if drained == 0 then
        -- Ring-fd readiness may report pending io_uring task-work before a CQE
        -- is visible. Entering with GETEVENTS and min_complete=0 is non-blocking
        -- and gives the kernel the required completion-side transition.
        local flushed, flush_err = self:_flush_completions()
        if not flushed then return nil, flush_err end
        self:_drain()
      end
      local retired, retire_err = self:_retire_completion_entry_direct_if_idle()
      if not retired then return nil, retire_err end
      return true
    end,
  })
  self.completion_entry = entry
  local runtime = self.reactor.runtime
  local registered, register_err = runtime:_perform_current(entry:register_op(), nil, true)
  if not registered then
    self.completion_entry = nil
    return nil, register_err
  end
  return true
end
function Provider:shutdown()
  if self.closed then
    return true
  end
  self.closed = true
  if self.completion_entry and not self.completion_entry.retired then
    self.reactor:_retire_entry(self.completion_entry, 'io_uring closed')
  end
  self.completion_entry = nil
  if self.handle then
    self.handle:close('io_uring closed')
    self.handle = nil
  elseif self.fd then
    self.C.close(self.fd)
  end
  if self.sqes then
    self.C.munmap(self.sqes, self.sqes_size)
  end
  if self.sq_ring then
    self.C.munmap(self.sq_ring, self.sq_map_size)
  end
  if self.cq_ring and self.cq_ring ~= self.sq_ring and self.cq_map_size > 0 then
    self.C.munmap(self.cq_ring, self.cq_map_size)
  end
  return true
end

function Provider:_submit(setup, keep)
  if self.closed then
    return nil, IOError.closed('file', 'submit')
  end
  -- The kernel publishes khead after consuming SQ entries. Acquire it before
  -- deciding whether this userspace producer has room for another SQE.
  local head = self.atomics.load_acquire(self.sq_head)
  local tail = tonumber(self.sq_tail[0])
  local entries = tonumber(self.sq_entries[0])
  if tail - head >= entries then
    self:_drain()
    head = self.atomics.load_acquire(self.sq_head)
    tail = tonumber(self.sq_tail[0])
    if tail - head >= entries then
      return nil, IOError.system('file', 'submit', 'io_uring submission queue is full', 'EBUSY')
    end
  end
  local index = tail % (tonumber(self.sq_mask[0]) + 1)
  local sqe = ptr_add(self.ffi, self.sqes, index * 64)
  self.ffi.fill(sqe, 64)
  self.next_id = self.next_id + 1
  local id = self.next_id
  setup(sqe, id)
  u64(self.ffi, sqe, 32)[0] = id

  -- Do not keep an idle ring registered with the host reactor. Registration is
  -- created only for an actual pending request, so provider caching cannot keep
  -- an otherwise quiescent runtime alive.
  local watching, watch_err = self:_ensure_completion_entry()
  if not watching then return nil, watch_err end

  -- CQ delivery originates in the reactor's non-yielding host-callback phase.
  -- Use an externally fed Signal as the boundary rather than publishing a
  -- Completion from that callback (which would enter Fibers scheduling).
  local req = { id = id, signal = Signal.new():label('file-uring-' .. id), keep = keep }
  self.pending[id] = req
  self.sq_array[index] = index
  -- Publish the SQE and array entry before advancing ktail. This mirrors the
  -- release store used by liburing and is required on weak-memory targets.
  self.atomics.store_release(self.sq_tail, tail + 1)
  local submitted = enter_ring(self.ffi, self.C, self.enter_nr, self.fd, 1, 0, 0)
  if not submitted or submitted < 1 then
    self.atomics.store_release(self.sq_tail, tail)
    self.pending[id] = nil
    local eno = self.ffi.errno and self.ffi.errno() or nil
    local failure = IOError.system('file', 'submit', 'io_uring_enter failed', nil, eno)
    local retired, retire_err = self:_retire_completion_entry_if_idle('io_uring submit failed')
    if not retired then
      return nil, IOError.with_cleanup(
        failure, 'file', 'submit',
        'io_uring submission failed and completion watcher cleanup was incomplete',
        { retire_err }
      )
    end
    return nil, failure
  end
  return req
end

function Provider:_flush_completions()
  local entered = enter_ring(
    self.ffi, self.C, self.enter_nr, self.fd, 0, 0, IORING_ENTER_GETEVENTS
  )
  if entered == nil or entered < 0 then
    local eno = self.ffi.errno and self.ffi.errno() or nil
    return nil, IOError.system(
      'file', 'completion', 'io_uring completion flush failed', nil, eno
    )
  end
  return true
end

-- Drain is safe in both ordinary Fibers execution and the reactor's
-- non-yielding callback phase: it performs only ring reads and authorised
-- external Signal delivery. It must not call perform or masked_perform.
function Provider:_drain()
  local head = tonumber(self.cq_head[0])
  -- The kernel publishes CQEs before advancing ktail. Match liburing's
  -- acquire load here so CQE reads cannot move before observing that tail.
  local tail = self.atomics.load_acquire(self.cq_tail)
  local drained = 0
  while head ~= tail do
    local index = head % (tonumber(self.cq_mask[0]) + 1)
    local cqe = ptr_add(self.ffi, self.cqes, index * 16)
    -- user_data contains Fibers-generated positive request IDs. Read it as
    -- signed 64-bit so both LuaJIT FFI and cffi-lua convert it to a Lua integer.
    local id = i64_number(self.ffi, cqe, 0)
    local res = tonumber(i32(self.ffi, cqe, 8)[0])
    if id == nil or res == nil then
      error(IOError.protocol('file', 'completion', 'io_uring CQE could not be converted to Lua integers', {
        user_data = tostring(i64(self.ffi, cqe, 0)[0]),
        result = tostring(i32(self.ffi, cqe, 8)[0]),
      }), 0)
    end
    local req = self.pending[id]
    if not req then
      error(IOError.protocol('file', 'completion', 'io_uring returned an unknown request id', {
        request_id = id,
        result = res,
      }), 0)
    end
    self.pending[id] = nil
    req.keep = nil
    External.unsafe_deliver(req.signal, res)
    head = head + 1
    drained = drained + 1
  end
  -- Release the consumed head only after every CQE has been read. This keeps
  -- the kernel from reusing a slot before userspace has finished consuming it.
  self.atomics.store_release(self.cq_head, head)
  return drained
end

function Provider:_await(req)
  self:_drain()
  local retired, retire_err = self:_retire_completion_entry_if_idle()
  if not retired then return nil, retire_err end
  local result = perform(req.signal:wait_op())
  retired, retire_err = self:_retire_completion_entry_if_idle()
  if not retired then return nil, retire_err end
  return result
end

local function set_common(self, sqe, opcode, fd)
  u8(self.ffi, sqe, 0)[0] = opcode
  i32(self.ffi, sqe, 4)[0] = fd or -1
end
local function set_ptr(self, sqe, offset, ptr)
  u64(self.ffi, sqe, offset)[0] = self.ffi.cast('fibers_uintptr', ptr)
end

function Provider:open(path, mode, opts)
  local flags, append = mode_flags(mode, opts)
  if not flags then
    return nil, IOError.invalid_argument('file', 'open', { path = path, mode = mode })
  end
  local pbuf = path_buffer(self.ffi, path)
  local req, err = self:_submit(function(sqe)
    set_common(self, sqe, OP_OPENAT, AT_FDCWD)
    set_ptr(self, sqe, 16, pbuf)
    u32(self.ffi, sqe, 24)[0] = opts and opts.permissions or 420
    u32(self.ffi, sqe, 28)[0] = flags
  end, { pbuf })
  if not req then
    return nil, err
  end
  local res = self:_await(req)
  if res < 0 then
    return nil, result_error(self, 'open', res, { path = path })
  end
  local backend = setmetatable(
    { provider = self, fd = res, path = path, position = 0, append = append, closed = false },
    Backend
  )
  if append then
    local size, size_err = backend:_size()
    if size == nil then
      backend:close('append-size probe failed')
      return nil, size_err
    end
    backend.position = size
  end
  return backend
end

function Backend:read(count)
  if self.closed then
    return nil, IOError.closed('file', 'read', { path = self.path })
  end
  local p = self.provider
  local buf = p.ffi.new('fibers_u8[?]', math.max(count, 1))
  local offset = self.position
  local req, err = p:_submit(function(sqe)
    set_common(p, sqe, OP_READ, self.fd)
    u64(p.ffi, sqe, 8)[0] = offset
    set_ptr(p, sqe, 16, buf)
    u32(p.ffi, sqe, 24)[0] = count
  end, { buf })
  if not req then
    return nil, err
  end
  local res = p:_await(req)
  if res < 0 then
    return nil, result_error(p, 'read', res, { path = self.path })
  end
  self.position = self.position + res
  return res == 0 and '' or p.ffi.string(buf, res)
end
function Backend:write(bytes)
  if self.closed then
    return nil, IOError.closed('file', 'write', { path = self.path })
  end
  local p = self.provider
  local buf = p.ffi.new('fibers_u8[?]', math.max(#bytes, 1))
  p.ffi.copy(buf, bytes, #bytes)
  local offset = self.position
  local req, err = p:_submit(function(sqe)
    set_common(p, sqe, OP_WRITE, self.fd)
    u64(p.ffi, sqe, 8)[0] = offset
    set_ptr(p, sqe, 16, buf)
    u32(p.ffi, sqe, 24)[0] = #bytes
  end, { buf })
  if not req then
    return nil, err
  end
  local res = p:_await(req)
  if res < 0 then
    return nil, result_error(p, 'write', res, { path = self.path })
  end
  self.position = self.position + res
  return res
end
function Backend:_size()
  local p = self.provider
  local empty = path_buffer(p.ffi, '')
  local stat = p.ffi.new('fibers_u8[256]')
  local req, err = p:_submit(function(sqe)
    set_common(p, sqe, OP_STATX, self.fd)
    set_ptr(p, sqe, 16, empty)
    u32(p.ffi, sqe, 24)[0] = 0x200
    u32(p.ffi, sqe, 28)[0] = AT_EMPTY_PATH
    set_ptr(p, sqe, 8, stat)
  end, { empty, stat })
  if not req then
    return nil, err
  end
  local res = p:_await(req)
  if res < 0 then
    return nil, result_error(p, 'stat', res, { path = self.path })
  end
  -- statx.stx_size is unsigned in the kernel ABI, but Fibers positions must
  -- fit in the host Lua integer domain. cffi-lua does not tonumber() uint64 cdata,
  -- so read the same bits through a signed 64-bit view and reject overflow.
  local size = i64_number(p.ffi, stat, 40)
  if size == nil or size < 0 then
    return nil, IOError.protocol('file', 'stat', 'file size exceeds Lua integer range', {
      path = self.path,
    })
  end
  return size
end
function Backend:seek(whence, offset)
  local base = 0
  if whence == 'cur' then
    base = self.position
  elseif whence == 'end' then
    local size, err = self:_size()
    if not size then
      return nil, err
    end
    base = size
  end
  local next_pos = base + offset
  if next_pos < 0 then
    return nil, IOError.invalid_argument('file', 'seek', { path = self.path, offset = offset })
  end
  self.position = next_pos
  return next_pos
end
function Backend:flush()
  return true
end
function Backend:sync(data_only)
  local p = self.provider
  local req, err = p:_submit(function(sqe)
    set_common(p, sqe, OP_FSYNC, self.fd)
    u32(p.ffi, sqe, 28)[0] = data_only and 1 or 0
  end)
  if not req then
    return nil, err
  end
  local res = p:_await(req)
  if res < 0 then
    return nil, result_error(p, 'sync', res, { path = self.path, data_only = data_only })
  end
  return true
end
function Backend:close(reason)
  if self.closed then
    return true
  end
  local p = self.provider
  local req, err = p:_submit(function(sqe)
    set_common(p, sqe, OP_CLOSE, self.fd)
  end)
  if not req then
    return nil, err
  end
  local res = p:_await(req)
  self.closed = true
  if res < 0 then
    return nil, result_error(p, 'close', res, { path = self.path, reason = reason })
  end
  return true
end

function Provider:_path_op(action, opcode, path, other, opts)
  local p1 = path_buffer(self.ffi, path)
  local p2 = other and path_buffer(self.ffi, other) or nil
  local req, err = self:_submit(function(sqe)
    set_common(self, sqe, opcode, AT_FDCWD)
    set_ptr(self, sqe, 16, p1)
    if opcode == OP_RENAMEAT then
      set_ptr(self, sqe, 8, p2)
      i32(self.ffi, sqe, 24)[0] = AT_FDCWD
    elseif opcode == OP_MKDIRAT then
      u32(self.ffi, sqe, 24)[0] = opts and opts.permissions or 493
    else
      u32(self.ffi, sqe, 28)[0] = 0
    end
  end, { p1, p2 })
  if not req then
    return nil, err
  end
  local res = self:_await(req)
  if res < 0 then
    return nil, result_error(self, action, res, { path = path, to = other })
  end
  return true
end
function Provider:rename(from, to, opts)
  return self:_path_op('rename', OP_RENAMEAT, from, to, opts)
end
function Provider:unlink(path, opts)
  return self:_path_op('unlink', OP_UNLINKAT, path, nil, opts)
end
function Provider:mkdir(path, opts)
  return self:_path_op('mkdir', OP_MKDIRAT, path, nil, opts)
end
function Provider:mkdir_p(path, opts)
  local absolute = path:sub(1, 1) == '/'
  local current = absolute and '/' or ''
  for part in path:gmatch('[^/]+') do
    current = (current == '' or current == '/') and (current .. part) or (current .. '/' .. part)
    local ok, err = self:mkdir(current, opts)
    if not ok and not (IOError.is(err, 'system') and tonumber(err.number) == 17) then
      return nil, err
    end
  end
  return true
end

Provider.Backend = Backend
return Provider
