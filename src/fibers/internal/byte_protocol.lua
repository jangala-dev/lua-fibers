-- Procedural composition of bounded transactional byte operations.
--
-- The callbacks supplied here each perform one honest byte decision. These
-- helpers deliberately live outside the Option algebra: they may perform many
-- decisions in sequence, so they are appropriate for direct convenience
-- methods rather than for `_op` constructors.

local M = {}

local function append(parts, total, value)
  if value == '' then return total end
  parts[#parts + 1] = value
  return total + #value
end

local function joined(parts)
  if #parts == 0 then return '' end
  if #parts == 1 then return parts[1] end
  return table.concat(parts)
end

function M.read_exactly(read_some, count, eof_error)
  local parts, total = {}, 0
  while total < count do
    local value, err = read_some(count - total)
    if value == nil or value == '' then
      return nil, err or eof_error, joined(parts)
    end
    total = append(parts, total, value)
  end
  return joined(parts)
end

function M.read_all(read_some, peek_one, maximum, chunk_size, eof_error, too_large_error)
  local parts, total = {}, 0
  while total < maximum do
    local want = math.min(chunk_size, maximum - total)
    local value, err = read_some(want)
    if value == nil or value == '' then
      if err == nil or err == eof_error then return joined(parts) end
      return nil, err
    end
    total = append(parts, total, value)
  end

  local value, err = peek_one()
  if value ~= nil and value ~= '' then return nil, too_large_error end
  if err == nil or err == eof_error then return joined(parts) end
  return nil, err
end

function M.write_all(write, value, chunk_size)
  local offset, total = 1, 0
  while offset <= #value do
    local chunk = value:sub(offset, offset + chunk_size - 1)
    local written, err = write(chunk)
    if written == nil then return nil, err end
    if type(written) ~= 'number' or written <= 0 or written > #chunk then
      error('byte protocol write made invalid progress', 2)
    end
    offset = offset + written
    total = total + written
  end
  return total
end

return M
