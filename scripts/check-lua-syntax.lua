local errors = {}

for i = 1, #arg do
  local path = arg[i]
  local chunk, message = loadfile(path)
  if not chunk then
    errors[#errors + 1] = path .. ': ' .. tostring(message)
  end
end

if #errors > 0 then
  io.stderr:write('Lua syntax errors:\n')
  for i = 1, #errors do
    io.stderr:write('  ', errors[i], '\n')
  end
  os.exit(1)
end

print('Lua script syntax: ok (' .. tostring(#arg) .. ' files)')
