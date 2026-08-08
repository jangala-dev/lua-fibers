-- Linux io_uring regular-file provider using raw syscalls and mmap.
--
-- The implementation deliberately uses only the stable 64-byte SQE and
-- 16-byte CQE ABI. It supports the complete version-1 file surface without
-- issuing blocking filesystem calls on the runtime thread.

local Completion = require('fibers.resource.completion')
local IOError = require('fibers.io.error')
local IO = require('fibers.io.facility')
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
local function u64(ffi, p, o)
  return ffi.cast('fibers_u64*', ptr_add(ffi, p, o))
end

local function setup_ring(ffi, C, number, entries, params)
  return tonumber(C.syscall(ffi.cast('long', number), ffi.cast('unsigned int', entries), params))
end

local function enter_ring(ffi, C, number, fd, to_submit)
  return tonumber(
    C.syscall(
      ffi.cast('long', number),
      ffi.cast('int', fd),
      ffi.cast('unsigned int', to_submit),
      ffi.cast('unsigned int', 0),
      ffi.cast('unsigned int', 0),
      ffi.cast('void*', nil),
      ffi.cast('unsigned long', 0)
    )
  )
end

local IORING_OFF_SQ_RING = 0
local IORING_OFF_CQ_RING = 0x08000000
local IORING_OFF_SQES = 0x10000000
local IORING_FEAT_SINGLE_MMAP = 1
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
  local self = setmetatable({
    runtime = runtime,
    ffi = ffi,
    C = C,
    fd_provider = assert(opts.fd),
    setup_nr = setup_nr,
    enter_nr = enter_nr,
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
  local handle, err = self.fd_provider.new(
    fd,
    { host = runtime.host, name = 'file-io-uring', nonblocking = true, cloexec = true }
  )
  if not handle then
    self:shutdown()
    return nil, err
  end
  self.handle = handle
  self.reactor = Reactor.for_runtime(runtime)
  self.completion_entry = self.reactor:callback({
    label = 'file-io-uring-completions',
    mode = 'read',
    handle = handle,
    callback = function(registered_handle)
      if type(registered_handle.clear_readable) == 'function' then
        registered_handle:clear_readable()
      end
      self:_drain()
      return true
    end,
  })
  local registered, register_err = runtime:_perform_current(self.completion_entry:register_op(), nil, true)
  if not registered then
    self.completion_entry = nil
    self:shutdown()
    return nil, register_err
  end
  return self
end

function Provider:is_supported()
  return not self.closed
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
  local head = tonumber(self.sq_head[0])
  local tail = tonumber(self.sq_tail[0])
  local entries = tonumber(self.sq_entries[0])
  if tail - head >= entries then
    self:_drain()
    head = tonumber(self.sq_head[0])
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
  self.sq_array[index] = index
  self.sq_tail[0] = tail + 1
  local req = { id = id, completion = Completion.new():label('file-uring-' .. id), keep = keep }
  self.pending[id] = req
  local submitted = enter_ring(self.ffi, self.C, self.enter_nr, self.fd, 1)
  if not submitted or submitted < 1 then
    self.sq_tail[0] = tail
    self.pending[id] = nil
    local eno = self.ffi.errno and self.ffi.errno() or nil
    return nil, IOError.system('file', 'submit', 'io_uring_enter failed', nil, eno)
  end
  return req
end

function Provider:_drain()
  local head = tonumber(self.cq_head[0])
  local tail = tonumber(self.cq_tail[0])
  local rt = self.runtime
  while head ~= tail do
    local index = head % (tonumber(self.cq_mask[0]) + 1)
    local cqe = ptr_add(self.ffi, self.cqes, index * 16)
    local id = tonumber(u64(self.ffi, cqe, 0)[0])
    local res = tonumber(i32(self.ffi, cqe, 8)[0])
    local req = self.pending[id]
    if req then
      self.pending[id] = nil
      req.keep = nil
      IO.masked_perform(rt, req.completion:publish_success_op(res))
    end
    head = head + 1
  end
  self.cq_head[0] = head
end

function Provider:_await(req)
  self:_drain()
  return perform(req.completion:result_op())
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
  return tonumber(u64(p.ffi, stat, 40)[0])
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
