-- Canonical regular-file mode grammar shared by public and native layers.
local Mode = {}
local VALID = {
  r = true, rb = true, w = true, wb = true, a = true, ab = true,
  ['r+'] = true, ['r+b'] = true, ['rb+'] = true,
  ['w+'] = true, ['w+b'] = true, ['wb+'] = true,
  ['a+'] = true, ['a+b'] = true, ['ab+'] = true,
}

function Mode.parse(name)
  if not VALID[name] then return nil end
  local first, plus = name:sub(1, 1), name:find('+', 1, true) ~= nil
  return {
    name = name, read = first == 'r' or plus, write = first ~= 'r' or plus,
    create = first ~= 'r', truncate = first == 'w', append = first == 'a',
  }
end

function Mode.require(name, level)
  name = name or 'r'
  if not VALID[name] then error('invalid regular-file mode ' .. tostring(name), level or 3) end
  return name
end

return Mode
