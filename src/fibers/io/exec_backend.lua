--
-- Backend selector for process management.
-- Prefers pidfd where available, then the luaposix reaper/sentinel
-- backend, then nixio.  The older SIGCHLD backend remains available
-- as an explicitly required module, but is not selected automatically.
--
---@module 'fibers.io.exec_backend'

---@class ExecProcSpec
---@field argv   string[]
---@field env    table<string,string|nil>|nil
---@field cwd    string|nil
---@field flags  table|nil            # optional process flags; supports setsid, pdeathsig, parent_death_signal and process_group
---@field stdin  ExecStreamConfig
---@field stdout ExecStreamConfig
---@field stderr ExecStreamConfig

--- Backend module interface.
---@class ExecBackendModule
---@field is_supported fun(): boolean
---@field start fun(spec: ExecProcSpec): ProcHandle|nil, string|nil

---@type string[]
local candidates = {
	'fibers.io.exec_backend.pidfd', -- Linux pidfd backend
	'fibers.io.exec_backend.posix_reaper', -- luaposix reaper/sentinel backend
	'fibers.io.exec_backend.nixio', -- nixio reaper/sentinel backend
}

---@type ExecBackendModule|nil
local chosen

for _, name in ipairs(candidates) do
	local ok, mod = pcall(require, name)
	if ok and type(mod) == 'table' and mod.is_supported and mod.is_supported() then
		---@cast mod ExecBackendModule
		chosen = mod
		break
	end
end

if not chosen then
	error('fibers.io.exec_backend: no suitable process backend available on this platform')
end

---@return ExecBackendModule
return chosen
