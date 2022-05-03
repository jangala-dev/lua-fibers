-- Copyright Snabb
-- Copyright Jangala

-- Returns true if x and y are structurally similar (isomorphic).
function equal (x, y)
   if type(x) ~= type(y) then return false end
   if type(x) == 'table' then
      for k, v in pairs(x) do
         if not equal(v, y[k]) then return false end
      end
      for k, _ in pairs(y) do
         if x[k] == nil then return false end
      end
      return true
   elseif type(x) == 'cdata' then
      if x == y then return true end
      if ffi.typeof(x) ~= ffi.typeof(y) then return false end
      local size = ffi.sizeof(x)
      if ffi.sizeof(y) ~= size then return false end
      return C.memcmp(x, y, size) == 0
   else
      return x == y
   end
end

function dump(o)
   if type(o) == 'table' then
      local s = '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         s = s .. '['..k..'] = ' .. dump(v) .. ','
      end
      return s .. '} '
   else
      return tostring(o)
   end
end

return {
   equal = equal,
   dump = dump
}