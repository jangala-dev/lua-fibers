-- Reusable Fibers facilities stay inside the Option algebra until commit.
-- Op:wrap remains public for application participant continuations, but the
-- library implementation must not use it to hide a post-commit causal stage.

local pipe = assert(io.popen("find 'src/fibers' 'tests/support' -type f -name '*.lua' -print", 'r'))
local paths = {}
for path in pipe:lines() do paths[#paths + 1] = path end
assert(pipe:close() ~= false, 'cannot enumerate reusable Fibers implementation/support code')
table.sort(paths)

local violations = {}
for i = 1, #paths do
  local path = paths[i]
  local file = assert(io.open(path, 'r'))
  local line_number = 0
  for line in file:lines() do
    line_number = line_number + 1
    if path ~= 'src/fibers/op.lua' and line:match(':wrap%s*%(') then
      violations[#violations + 1] = path .. ':' .. tostring(line_number) .. ': ' .. line
    end
  end
  file:close()
end

if #violations > 0 then
  io.stderr:write('reusable implementation Op:wrap calls are not permitted:\n')
  for i = 1, #violations do io.stderr:write('  ', violations[i], '\n') end
  os.exit(1)
end

print('Internal Op:wrap audit: ok')
