-- Native-object descriptor family for nixio.

local Errors = require('fibers.flow.errors')
local Family = require('fibers.host.family')
local FdClass = require('fibers.host.fd_class')
local HostError = require('fibers.host.error')

local ok_nixio, nixio = pcall(require, 'nixio')
if not ok_nixio or type(nixio) ~= 'table' then
  return Family.unsupported('fibers.host.fd_nixio', 'nixio module not available')
end

local NixioError = require('fibers.host.nixio_error')
local open_objects = setmetatable({}, { __mode = 'k' })
local EAGAIN = nixio.const and (nixio.const.EAGAIN or nixio.const.EWOULDBLOCK) or 11
local EWOULDBLOCK = nixio.const and (nixio.const.EWOULDBLOCK or nixio.const.EAGAIN) or EAGAIN

local function fileno(object)
  if type(object) == 'number' then
    return object
  end
  if object and type(object.fileno) == 'function' then
    local ok, fd = pcall(object.fileno, object)
    if ok then
      return tonumber(fd)
    end
  end
end

local operations = {}
function operations.read(self, max)
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
  if data == false then
    local _, eno = NixioError.split(a, b)
    return nil, 'would_block', eno
  end
  local no_error, message, eno = NixioError.no_error(a, b)
  if no_error then
    return nil, Errors.EOF
  end
  if eno == EAGAIN or eno == EWOULDBLOCK then
    return nil, 'would_block', eno
  end
  return nil, NixioError.message('read failed', message, eno), eno
end
function operations.write(self, bytes)
  if type(bytes) ~= 'string' then
    error('fd write expects bytes', 2)
  end
  if bytes == '' then
    return 0
  end
  local count, a, b
  if type(self.obj.write) == 'function' then
    count, a, b = self.obj:write(bytes, 0, #bytes)
  elseif type(self.obj.send) == 'function' then
    count, a, b = self.obj:send(bytes)
  else
    return nil, 'write unsupported'
  end
  if type(count) == 'number' then
    return count
  end
  if count == true then
    return #bytes
  end
  local message, eno = NixioError.split(a, b)
  eno = eno or NixioError.current_errno()
  if eno == EAGAIN or eno == EWOULDBLOCK then
    return nil, 'would_block', eno
  end
  return nil, NixioError.message('write failed', message, eno), eno
end
function operations.shutdown_read(self)
  if self.obj and type(self.obj.shutdown) == 'function' then
    pcall(self.obj.shutdown, self.obj, 'rd')
  end
  return true
end
function operations.shutdown_write(self)
  if self.obj and type(self.obj.shutdown) == 'function' then
    pcall(self.obj.shutdown, self.obj, 'wr')
  end
  return true
end
function operations.close(self)
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
      local message, eno = NixioError.split(a, b)
      return nil, NixioError.message('close failed', message, eno), eno
    end
  end
  return true
end
function operations.set_nonblocking(self, value)
  if self.obj and type(self.obj.setblocking) == 'function' then
    local ok, a, b = self.obj:setblocking(value == false)
    if ok ~= nil and ok ~= false then
      return true
    end
    local message, eno = NixioError.split(a, b)
    return nil, NixioError.message('setblocking failed', message, eno), eno
  end
  return true
end

return FdClass.define({
  family = 'nixio',
  operations = operations,
  is_supported = function()
    return type(nixio.pipe) == 'function'
  end,
  support_reason = function()
    return 'nixio.pipe unavailable'
  end,
  validate = function(object)
    return assert(object, 'nixio handle object required')
  end,
  describe = function(object, generation)
    local fd = fileno(object)
    return {
      fd = fd,
      name = fd and ('nixio-fd-' .. tostring(fd)) or ('nixio-handle-' .. tostring(generation)),
      key = { family = 'nixio', handle = object, generation = generation },
    }
  end,
  decorate = function(handle, object, detail)
    handle.obj = object
    handle.fd, handle.raw_fd = detail.fd, detail.fd
    open_objects[object] = true
  end,
  configure = function(handle, opts)
    if opts.nonblocking ~= false then
      return handle:set_nonblocking(true)
    end
    return true
  end,
  pipe = function()
    local reader, writer = nixio.pipe()
    if not reader or not writer then
      return nil, nil, HostError.system('pipe', 'create', 'nixio.pipe failed')
    end
    return reader, writer
  end,
  close_raw = function(object)
    if object and type(object.close) == 'function' then
      pcall(object.close, object)
    end
  end,
  extend = function(Fd)
    function Fd.open_objects()
      local out = {}
      for object in pairs(open_objects) do
        out[#out + 1] = object
      end
      return out
    end
  end,
})
