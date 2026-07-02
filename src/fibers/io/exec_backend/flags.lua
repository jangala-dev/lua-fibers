-- fibers/io/exec_backend/flags.lua
--
-- Shared normalisation for optional process containment flags.  Backends
-- should receive only validated, backend-facing flag values.

---@module 'fibers.io.exec_backend.flags'

local M = {}

local SIGNALS = {
	HUP  = 1,
	INT  = 2,
	QUIT = 3,
	ILL  = 4,
	TRAP = 5,
	ABRT = 6,
	BUS  = 7,
	FPE  = 8,
	KILL = 9,
	USR1 = 10,
	SEGV = 11,
	USR2 = 12,
	PIPE = 13,
	ALRM = 14,
	TERM = 15,
	CHLD = 17,
	CONT = 18,
	STOP = 19,
	TSTP = 20,
	TTIN = 21,
	TTOU = 22,
}

local function normalise_signal(value, field)
	local tv = type(value)
	if tv == 'number' then
		local n = math.floor(value)
		if n == value and n > 0 and n <= 128 then
			return n
		end
		return nil, field .. ': invalid signal number: ' .. tostring(value)
	end

	if tv == 'string' then
		local name = value:upper():gsub('^SIG', '')
		local n = SIGNALS[name]
		if n then
			return n
		end
		return nil, field .. ': unknown signal name: ' .. tostring(value)
	end

	return nil, field .. ': expected signal name or number, got ' .. tv
end

---@param flags table|nil
---@return table|nil flags
---@return string|nil err
function M.normalise(flags)
	if flags == nil then
		return nil, nil
	end
	if type(flags) ~= 'table' then
		return nil, 'exec flags must be a table'
	end

	local out = {}
	for k, v in pairs(flags) do
		out[k] = v
	end

	if out.pdeathsig ~= nil and out.parent_death_signal ~= nil then
		return nil, 'flags.pdeathsig and flags.parent_death_signal are mutually exclusive'
	end

	if out.pdeathsig ~= nil then
		local sig, err = normalise_signal(out.pdeathsig, 'flags.pdeathsig')
		if not sig then
			return nil, err
		end
		out.pdeathsig = sig
	end

	if out.parent_death_signal ~= nil then
		local sig, err = normalise_signal(out.parent_death_signal, 'flags.parent_death_signal')
		if not sig then
			return nil, err
		end
		out.parent_death_signal = sig
	end

	if out.process_group ~= nil then
		if out.process_group ~= true and out.process_group ~= false then
			return nil, 'flags.process_group must be boolean when provided'
		end
		if out.process_group == false then
			out.process_group = nil
		end
	end

	return out, nil
end

M.SIGNALS = SIGNALS

return M
