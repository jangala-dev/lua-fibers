-- tests/test_io-backend_families.lua
--
-- Cycles the relevant fibers.io tests across the supported backend families.
-- Each family is run in a fresh Lua process. This is necessary because the
-- selector modules are cached in package.loaded after first use.

print('testing: fibers.io backend families')

local function split_csv(s)
	local out = {}
	for item in tostring(s):gmatch('[^,%s]+') do
		table.insert(out, item)
	end
	return out
end

local function shell_quote(s)
	s = tostring(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function command_ok(a, b, c)
	-- Lua 5.1/LuaJIT: os.execute returns a numeric status, usually 0 on success.
	-- Lua 5.2+: returns true/nil plus exit metadata.
	if type(a) == 'boolean' then
		return a, c or 0
	end
	if type(a) == 'number' then
		return a == 0, a
	end
	return false, tostring(a)
end

if os.getenv('LUA_FIBERS_SKIP_BACKEND_FAMILIES') == '1' then
	print('skip - fibers.io backend families: LUA_FIBERS_SKIP_BACKEND_FAMILIES=1')
	return
end

local families = split_csv(os.getenv('LUA_FIBERS_BACKEND_FAMILIES') or 'ffi,posix,nixio')
local lua = os.getenv('LUA') or (arg and arg[-1]) or 'lua'

assert(#families > 0, 'no backend families selected')

for _, family in ipairs(families) do
	local cmd = table.concat({
		shell_quote(lua),
		shell_quote('test_io_backend_family_child.lua'),
		'--family',
		shell_quote(family),
	}, ' ')
	print(('running backend family subprocess: %s'):format(family))
	local ok, code = command_ok(os.execute(cmd))
	assert(ok, ('backend family %s failed; command=%s status=%s'):format(
		family, cmd, tostring(code)))
end

print('fibers.io backend family tests passed')
