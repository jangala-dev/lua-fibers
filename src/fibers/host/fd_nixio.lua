-- nixio fd HostHandle implementation.
--
-- Optional.  Uses nixio File/Socket objects directly as readiness keys.

local Handle = require('fibers.host.handle')
local Errors = require('fibers.flow.errors')
local HostError = require('fibers.host.error')
local Provider = require('fibers.host.provider')

local function unsupported(reason)
  return Provider.unsupported('fibers.host.fd_nixio', reason, { 'new', 'wrap', 'pipe' })
end

local ok_nixio, nixio = pcall(require, 'nixio')
if not ok_nixio or type(nixio) ~= 'table' then
  return unsupported('nixio module not available')
end

local Fd = {}
Fd.__index = Fd
local next_generation = 0
local open_objects = setmetatable({}, { __mode = 'k' })

local EAGAIN = nixio.const and (nixio.const.EAGAIN or nixio.const.EWOULDBLOCK) or 11
local EWOULDBLOCK = nixio.const and (nixio.const.EWOULDBLOCK or nixio.const.EAGAIN) or EAGAIN

local function norm_msg_eno(a, b)
  if type(a) == 'number' then
    return b, a
  end
  if type(b) == 'number' then
    return a, b
  end
  return a or b, nil
end

local function errstr(prefix, msg, eno)
  if msg and msg ~= '' then
    return tostring(msg)
  end
  if eno then
    local s = nixio.strerror and nixio.strerror(eno)
    return tostring(prefix) .. ': ' .. tostring(s or ('errno ' .. tostring(eno)))
  end
  return tostring(prefix)
end

local function set_nonblocking_obj(obj, value)
  if obj and type(obj.setblocking) == 'function' then
    local ok, a, b = obj:setblocking(value == false)
    if ok ~= nil and ok ~= false then
      return true
    end
    local msg, eno = norm_msg_eno(a, b)
    return nil, errstr('setblocking failed', msg, eno), eno
  end
  return true
end

local function fd_read(self, max)
  max = tonumber(max) or 4096
  if max <= 0 then
    return ''
  end
  local data, a, b = self.obj:read(max)
  if type(data) == 'string' then
    if data == '' then
      return nil, Errors.EOF
    end
    return data
  end
  local msg, eno = norm_msg_eno(a, b)
  eno = eno or (nixio.errno and nixio.errno())
  if eno == EAGAIN or eno == EWOULDBLOCK then
    return nil, 'would_block', eno
  end
  if not eno or eno == 0 then
    return nil, Errors.EOF
  end
  return nil, errstr('read failed', msg, eno), eno
end

local function fd_write(self, bytes)
  if type(bytes) ~= 'string' then
    error('fd write expects bytes', 2)
  end
  if #bytes == 0 then
    return 0
  end
  local n, a, b
  if type(self.obj.write) == 'function' then
    n, a, b = self.obj:write(bytes, 0, #bytes)
  elseif type(self.obj.send) == 'function' then
    n, a, b = self.obj:send(bytes)
  else
    return nil, 'write unsupported'
  end
  if type(n) == 'number' then
    return n
  end
  if n == true then
    return #bytes
  end
  local msg, eno = norm_msg_eno(a, b)
  eno = eno or (nixio.errno and nixio.errno())
  if eno == EAGAIN or eno == EWOULDBLOCK then
    return nil, 'would_block', eno
  end
  return nil, errstr('write failed', msg, eno), eno
end

local function fd_shutdown_read(self, _reason)
  if self.obj and type(self.obj.shutdown) == 'function' then
    pcall(function()
      self.obj:shutdown('rd')
    end)
  end
  return true
end

local function fd_shutdown_write(self, _reason)
  if self.obj and type(self.obj.shutdown) == 'function' then
    pcall(function()
      self.obj:shutdown('wr')
    end)
  end
  return true
end

local function fd_close(self, _reason)
  if self._closed then
    return true
  end
  self._closed = true
  if self.obj then
    open_objects[self.obj] = nil
  end
  if self.obj and type(self.obj.close) == 'function' then
    local ok, a, b = self.obj:close()
    if ok == nil or ok == false then
      local msg, eno = norm_msg_eno(a, b)
      return nil, errstr('close failed', msg, eno), eno
    end
  end
  return true
end

local function fileno(obj)
  if type(obj) == 'number' then
    return obj
  end
  if type(obj) == 'table' or type(obj) == 'userdata' then
    if type(obj.fileno) == 'function' then
      local ok, fd = pcall(function()
        return obj:fileno()
      end)
      if ok and fd then
        return tonumber(fd)
      end
    end
    if type(obj.fd) == 'number' then
      return obj.fd
    end
  end
  return nil
end

function Fd.is_supported()
  return type(nixio.pipe) == 'function'
end

function Fd.support_reason()
  if Fd.is_supported() then
    return nil
  end
  return 'nixio.pipe unavailable'
end

function Fd.new(obj, opts)
  opts = opts or {}
  assert(obj ~= nil, 'nixio handle object required')
  next_generation = next_generation + 1
  local fd = fileno(obj)
  local key = opts.key or { family = 'nixio', handle = obj, generation = next_generation }
  local h = Handle.new({
    name = opts.name
      or (fd and ('nixio-fd-' .. tostring(fd)) or ('nixio-handle-' .. tostring(next_generation))),
    key = key,
    handle = obj,
    host = opts.host,
    read = function(self, max)
      return fd_read(self, max)
    end,
    write = function(self, bytes)
      return fd_write(self, bytes)
    end,
    shutdown_read = function(self, reason)
      return fd_shutdown_read(self, reason)
    end,
    shutdown_write = function(self, reason)
      return fd_shutdown_write(self, reason)
    end,
    close = function(self, reason)
      return fd_close(self, reason)
    end,
    set_nonblocking = function(_self, value)
      return set_nonblocking_obj(obj, value ~= false)
    end,
  })
  h.family = 'nixio'
  h.obj = obj
  open_objects[obj] = true
  h.fd = fd
  h.raw_fd = fd
  h.generation = next_generation
  if opts.nonblocking ~= false then
    local ok, err, eno = h:set_nonblocking(true)
    if not ok then
      h:close('set_nonblocking failed')
      return nil, err, eno
    end
  end
  return h
end

function Fd.open_objects()
  local out = {}
  for obj in pairs(open_objects) do
    out[#out + 1] = obj
  end
  return out
end

function Fd.pipe(opts)
  opts = opts or {}
  local r, w = nixio.pipe()
  if not r or not w then
    return nil, nil, HostError.system('pipe', 'create', 'nixio.pipe failed')
  end
  local rh, rerr = Fd.new(r, {
    host = opts.host,
    name = opts.name and (opts.name .. ':read') or nil,
    nonblocking = opts.nonblocking,
  })
  if not rh then
    pcall(function()
      w:close()
    end)
    return nil, nil, rerr
  end
  local wh, werr = Fd.new(w, {
    host = opts.host,
    name = opts.name and (opts.name .. ':write') or nil,
    nonblocking = opts.nonblocking,
  })
  if not wh then
    rh:close('paired pipe wrap failed')
    return nil, nil, werr
  end
  rh.capabilities.write = false
  rh.capabilities.shutdown_write = false
  wh.capabilities.read = false
  wh.capabilities.shutdown_read = false
  return rh, wh
end

return Fd
