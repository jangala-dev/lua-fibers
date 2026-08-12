---Buffered byte-plane protocol for RegularFile.
---
---This module installs methods directly onto the RegularFile type. It does not
---add another runtime object: the authoritative state remains the file's Flow,
---Lifetime, Counter and EOF resources.

local Op = require('fibers.op')
local IOError = require('fibers.io.error')
local FlowErrors = require('fibers.resource.flow.errors')
local perform = require('fibers.perform')

local BytePlane = {}
BytePlane.DEFAULT_CHUNK = 16 * 1024
BytePlane.DEFAULT_MAX = 16 * 1024 * 1024

function BytePlane.validate_read_max(opts, level)
  local max = opts and opts.max or BytePlane.DEFAULT_MAX
  level = (level or 1) + 1
  if type(max) ~= 'number' or max < 0 or max ~= math.floor(max) or max == math.huge then
    error('file read max must be a finite non-negative integer', level)
  end
  return max
end

local function count(value, label)
  if type(value) ~= 'number' or value < 0 or value ~= math.floor(value) then
    error(label .. ' expects a non-negative integer', 3)
  end
  return value
end

function BytePlane.closed_error(file, action, reason)
  return IOError.closed('file', action, { path = file._path, reason = reason })
end

function BytePlane.normalise_error(file, action, err)
  if err == nil or IOError.is(err) then return err end
  if err == FlowErrors.CLOSED or err == FlowErrors.BROKEN_PIPE or err == FlowErrors.RETIRED or err == FlowErrors.EOF then
    return BytePlane.closed_error(file, action, err)
  end
  if err == FlowErrors.CAPACITY then
    return IOError.invalid_argument('file', action, {
      path = file._path, message = 'operation exceeds configured buffer capacity',
    })
  end
  if err == FlowErrors.LINE_TOO_LONG or err == FlowErrors.TOO_LARGE then
    return IOError.system('file', action, 'buffered read exceeds configured limit', 'EFBIG', nil, { path = file._path })
  end
  return IOError.normalise(err, { domain = 'file', action = action, path = file._path })
end

local function endpoint(file, side, action)
  local flow = side == 'read' and file._read_flow or file._write_flow
  if not flow then
    return nil, IOError.invalid_argument('file', action, {
      path = file._path, message = 'file is not ' .. (side == 'read' and 'readable' or 'writable'),
    })
  end
  if file._lifetime:_close_requested() then
    return nil, BytePlane.closed_error(file, action)
  end
  return side == 'read' and flow:outlet() or flow:inlet()
end

function BytePlane.invalidate_read_op(file)
  if not file._read_flow then return Op.always(0) end
  return file._read_flow:outlet():_discard_available_op():and_then(Op.guard(function(discarded, discard_err)
    -- Structural closure may retire the private Flow endpoint before a racing
    -- file-close invalidation is elaborated.  At that point the Flow retains no
    -- readable bytes for this file, so there is no rewind debt to record.
    if discarded == nil and discard_err == FlowErrors.RETIRED then discarded = 0 end
    if discarded == nil then
      error('file read invalidation failed: ' .. tostring(discard_err), 0)
    end
    return file._read_generation:bump_op()
      :and_then(file._rewind:add_op(discarded))
      :and_then(file._eof:write_op(false))
      :map(function() return discarded end)
  end))
end

local function eof_fallback(file, op)
  return op:or_else(file._eof:expect_op(true):map(function() return nil, FlowErrors.EOF end))
end

local function write_parts(...)
  local parts = {}
  for i = 1, select('#', ...) do
    local value = select(i, ...)
    if type(value) ~= 'string' and type(value) ~= 'number' then
      error('File:write expects strings or numbers', 3)
    end
    parts[i] = tostring(value)
  end
  return table.concat(parts)
end

function BytePlane.install(RegularFile)
  function RegularFile:read_op(n)
    n = count(n, 'File:read_op')
    if n == 0 then return Op.always('') end
    local outlet, err = endpoint(self, 'read', 'read')
    if not outlet then return Op.always(nil, err) end
    return eof_fallback(self, outlet:read_some_op(n)):map(function(bytes, read_err)
      if bytes ~= nil then return bytes end
      if read_err == FlowErrors.EOF then return '' end
      return nil, BytePlane.normalise_error(self, 'read', read_err)
    end)
  end

  function RegularFile:read_some_op(n) return self:read_op(n) end

  function RegularFile:read_exactly_op(n)
    n = count(n, 'File:read_exactly_op')
    if n == 0 then return Op.always('') end
    local outlet, err = endpoint(self, 'read', 'read_exactly')
    if not outlet then return Op.always(nil, err) end
    return self._eof:read_op():and_then(Op.guard(function(at_eof)
      local read = at_eof and outlet:_take_available_op(n) or outlet:read_exactly_op(n)
      return read:map(function(value, read_err)
        if value ~= nil and #value == n then return value end
        if read_err ~= nil then return nil, BytePlane.normalise_error(self, 'read_exactly', read_err) end
        return nil, IOError.eof('file', 'read_exactly', {
          path = self._path, expected = n, received = #(value or ''),
        })
      end)
    end))
  end

  function RegularFile:read_line_op(keep)
    local outlet, err = endpoint(self, 'read', 'read_line')
    if not outlet then return Op.always(nil, err) end
    local maximum = BytePlane.DEFAULT_MAX
    local line = outlet:read_line_op({ keep_terminator = keep == true, max = maximum })
      :map(function(value, read_err) return 'line', value, read_err end)
    local at_eof = self._eof:expect_op(true)
      :and_then(outlet:_take_all_available_op(maximum))
      :map(function(value, read_err) return 'eof', value, read_err end)
    return line:or_else(at_eof):map(function(source, value, read_err)
      if source == 'eof' then
        if value ~= nil then return value ~= '' and value or nil end
        return nil, BytePlane.normalise_error(self, 'read_line', read_err)
      end
      if value ~= nil then return value end
      if read_err == nil or read_err == FlowErrors.EOF then return nil end
      return nil, BytePlane.normalise_error(self, 'read_line', read_err)
    end)
  end

  function RegularFile:read_all_op(opts)
    if opts and opts.chunk_size ~= nil then
      error('File:read_all_op does not accept chunk_size; configure read_chunk_size when opening the file', 2)
    end
    local maximum = BytePlane.validate_read_max(opts, 2)
    local outlet, err = endpoint(self, 'read', 'read_all')
    if not outlet then return Op.always(nil, err) end

    -- File EOF is a managed cursor fact rather than Flow input closure.  The
    -- two positive terminal facts are therefore independent: max+1 buffered
    -- bytes prove oversize, while EOF permits bounded consumption of everything
    -- retained.  The max+1 branch also supplies the elastic-capacity demand.
    local too_large = outlet:peek_exactly_op(maximum + 1):map(function(value, read_err)
      if value ~= nil then return nil, FlowErrors.TOO_LARGE end
      return nil, read_err
    end)
    local at_eof = self._eof:expect_op(true):and_then(outlet:_take_all_available_op(maximum))
    return Op.choice(too_large, at_eof):map(function(value, read_err)
      if value ~= nil then return value end
      if read_err == FlowErrors.TOO_LARGE then
        return nil, IOError.system('file', 'read_all', 'file exceeds configured maximum', 'EFBIG', nil, {
          path = self._path, max = maximum,
        })
      end
      return nil, BytePlane.normalise_error(self, 'read_all', read_err)
    end)
  end

  function RegularFile:write_op(bytes)
    if type(bytes) ~= 'string' then error('File:write_op expects a string', 2) end
    if bytes == '' then return Op.always(0) end
    local inlet, err = endpoint(self, 'write', 'write')
    if not inlet then return Op.always(nil, err) end
    local limit = self._write_flow._write_limit
    if limit ~= math.huge and #bytes > limit then
      return Op.always(nil, BytePlane.normalise_error(self, 'write', FlowErrors.CAPACITY))
    end
    return inlet:write_op(bytes):and_then(Op.guard(function(n, write_err)
      if n == nil then return Op.always(nil, BytePlane.normalise_error(self, 'write', write_err)) end
      return BytePlane.invalidate_read_op(self)
        :and_then(self._accepted:add_op(n))
        :map(function() return n end)
    end))
  end

  function RegularFile:write_some_op(bytes)
    if type(bytes) ~= 'string' then error('File:write_some_op expects a string', 2) end
    if bytes == '' then return Op.always(0, '') end
    local inlet, err = endpoint(self, 'write', 'write_some')
    if not inlet then return Op.always(nil, bytes, err) end
    return inlet:write_some_op(bytes):and_then(Op.guard(function(n, rest, write_err)
      if n == nil then return Op.always(nil, rest, BytePlane.normalise_error(self, 'write_some', write_err)) end
      if n == 0 then return Op.always(0, rest) end
      return BytePlane.invalidate_read_op(self)
        :and_then(self._accepted:add_op(n))
        :map(function() return n, rest end)
    end))
  end

  function RegularFile:write_all_op(bytes)
    if type(bytes) ~= 'string' then error('File:write_all_op expects a string', 2) end
    if bytes == '' then return Op.always(0) end
    local inlet, err = endpoint(self, 'write', 'write_all')
    if not inlet then return Op.always(nil, err) end
    return inlet:write_all_op(bytes):and_then(Op.guard(function(n, write_err)
      if n == nil then return Op.always(nil, BytePlane.normalise_error(self, 'write_all', write_err)) end
      return BytePlane.invalidate_read_op(self)
        :and_then(self._accepted:add_op(n))
        :map(function() return n end)
    end))
  end

  function RegularFile:write(...)
    return perform(self:write_op(write_parts(...)))
  end
end

return BytePlane
