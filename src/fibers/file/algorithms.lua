-- Provider-neutral whole-file and exact-read algorithms.

local HostError = require('fibers.host.error')

local Algorithms = {}

function Algorithms.read_exactly(read, count, fields)
  local parts, total = {}, 0
  while total < count do
    local bytes, err = read(count - total)
    if bytes == nil then
      return nil, err
    end
    if bytes == '' then
      fields = fields or {}
      fields.expected = count
      fields.received = total
      return nil, HostError.eof('file', 'read_exactly', fields)
    end
    parts[#parts + 1] = bytes
    total = total + #bytes
  end
  return table.concat(parts)
end

function Algorithms.read_all(read, opts)
  opts = opts or {}
  local max = assert(opts.max)
  local chunk = assert(opts.chunk_size)
  local parts, total = {}, 0
  while total < max do
    local bytes, err = read(math.min(chunk, max - total))
    if bytes == nil then
      return nil, err
    end
    if bytes == '' then
      return table.concat(parts)
    end
    parts[#parts + 1] = bytes
    total = total + #bytes
  end

  local extra, err = read(1)
  if extra == nil then
    return nil, err
  end
  if extra ~= '' then
    if opts.restore_probe then
      local restored, restore_err = opts.restore_probe()
      if restored == nil or restored == false then
        return nil, restore_err
      end
    end
    return nil,
      HostError.system(
        'file',
        'read_all',
        'file exceeds configured maximum',
        'EFBIG',
        nil,
        { path = opts.path, max = max }
      )
  end
  return table.concat(parts)
end

function Algorithms.write_all(write, bytes, fields)
  local total = 0
  while total < #bytes do
    local written, err = write(bytes:sub(total + 1))
    if written == nil or written == false then
      return nil, err
    end
    if written <= 0 then
      return nil,
        HostError.system(
          'file',
          'write_all',
          'write made no progress',
          'EIO',
          nil,
          { path = fields and fields.path, written = total }
        )
    end
    total = total + written
  end
  return total
end

return Algorithms
