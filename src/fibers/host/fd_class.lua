-- Static host-handle class for one native descriptor family.

local Handle = require('fibers.host.handle')

local M = {}

function M.define(spec)
  local Fd = {}
  local generation = 0

  function Fd.is_supported()
    return spec.is_supported()
  end

  function Fd.support_reason()
    if Fd.is_supported() then
      return nil
    end
    return spec.support_reason()
  end

  function Fd.new(raw, opts)
    opts = opts or {}
    raw = spec.validate(raw)
    generation = generation + 1
    local detail = spec.describe(raw, generation)
    local handle = Handle.new({
      name = opts.name or detail.name,
      key = opts.key or detail.key,
      handle = raw,
      host = opts.host,
      operations = spec.operations,
    })
    handle.family = spec.family
    handle.generation = generation
    spec.decorate(handle, raw, detail)
    local ok, err, extra = spec.configure(handle, opts)
    if not ok then
      handle:close('descriptor configuration failed')
      return nil, err, extra
    end
    return handle
  end

  function Fd.pipe(opts)
    opts = opts or {}
    local read_raw, write_raw, err, extra = spec.pipe()
    if not read_raw then
      return nil, nil, err, extra
    end
    local reader, read_err = Fd.new(read_raw, {
      host = opts.host,
      name = opts.name and (opts.name .. ':read') or nil,
      nonblocking = opts.nonblocking,
    })
    if not reader then
      spec.close_raw(write_raw)
      return nil, nil, read_err
    end
    local writer, write_err = Fd.new(write_raw, {
      host = opts.host,
      name = opts.name and (opts.name .. ':write') or nil,
      nonblocking = opts.nonblocking,
    })
    if not writer then
      reader:close('paired pipe wrap failed')
      return nil, nil, write_err
    end
    reader.capabilities.write = false
    reader.capabilities.shutdown_write = false
    writer.capabilities.read = false
    writer.capabilities.shutdown_read = false
    return reader, writer
  end

  if spec.extend then
    spec.extend(Fd)
  end
  return Fd
end

return M
