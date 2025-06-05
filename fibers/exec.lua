-- fibers/exec.lua
-- Provides facilities for executing external commands asynchronously using fibers.
local file = require 'fibers.stream.file'
local pollio = require 'fibers.pollio'
local op = require 'fibers.op'
local buffer = require 'string.buffer'
local sc = require 'fibers.utils.syscall'

local io_mappings = {
    stdin = sc.STDIN_FILENO,
    stdout = sc.STDOUT_FILENO,
    stderr = sc.STDERR_FILENO
}

-- Define the command type
local Cmd = {}
Cmd.__index = Cmd -- set metatable

--- Constructor for Cmd.
-- @param name The name or path of the command to execute.
-- @param ... Additional arguments for the command.
-- @return A new Cmd instance.
local function command(name, ...)
    local self = setmetatable({}, Cmd)
    self.path = name
    self.args = {...}
    self.process = {}
    self.pipes = {
        child = {},
        parent = {}
    }
    return self
end

--- Constructor for Cmd taking a `context`.
-- @param ctx The context to run the command under.
-- @param name The name or path of the command to execute.
-- @param ... Additional arguments for the command.
-- @return A new Cmd instance.
local function command_context(ctx, name, ...)
    local cmd = command(name, ...)
    cmd.ctx = ctx
    return cmd
end

--- Sets the command to launch with a different pgid.
-- @param status True if diff pgid desired.
function Cmd:setpgid(status)
    self._setpgid = status
end

function Cmd:_output_collector(pipes)

    local function close_pipes()
        for idx, pipe in ipairs(pipes) do
            pipe:close()
            table.remove(pipes, idx)
        end
    end

    local err = self:start()
    if err then
        close_pipes()
        return nil, err
    end

    local buf = buffer.new()

    while #pipes > 0 do
        local ops = {}

        -- build a read operation for each still-open pipe
        for idx, pipe in ipairs(pipes) do
            ops[#ops + 1] = pipe:read_some_chars_op():wrap(function(chunk)
                if chunk then
                    buf:put(chunk)
                else -- EOF: close and mark for removal
                    pipe:close()
                    table.remove(pipes, idx)
                end
            end)
        end

        ops[#ops + 1] = self.ctx and self.ctx:done_op():wrap(close_pipes)

        op.choice(unpack(ops)):perform()
    end

    return buf:tostring(), self:wait()
end

--- Gets combined stdout + stderr as a single string.
-- @return output string on success, or nil + error on failure
function Cmd:combined_output()
    if self.ctx and self.ctx:err() then return nil, "context cancelled" end

    local pipes = { self:stdout_pipe(), self:stderr_pipe() }
    return self:_output_collector(pipes)
end

--- Gets the output of stdout.
-- @return The output and any error.
function Cmd:output()
    if self.ctx and self.ctx:err() then return nil, "context cancelled" end

    local pipes = { self:stdout_pipe() }
    return self:_output_collector(pipes)
end

--- Starts the command and waits for it to complete.
-- @return Any error.
function Cmd:run()
    local err = self:start()
    return err and err or self:wait()
end

--- Starts the command.
-- @return Any error.
function Cmd:start()
    if self.process.pid then return "process already started" end
    if self.ctx and self.ctx:err() then
        for _, v in pairs(self.pipes.child) do sc.close(v) end
        return "context cancelled"
    end

    local ready_read, ready_write = sc.pipe()
    assert(ready_read and ready_write)

    local pid, err = sc.fork()
    assert(pid ~= nil, err)

    if pid == 0 then -- child
        if self._setpgid then
            local result, err_msg = sc.setpid('p', 0, 0)
            assert(result == 0, err_msg)
        end

        -- pipework
        sc.close(ready_read)
        for k, v in pairs(self.pipes.child) do
            sc.close(self.pipes.parent[k])
            assert(sc.dup2(v, io_mappings[k]))
            sc.close(v)
        end

        sc.close(ready_write)

        local _, execp_err, errno = sc.execp(self.path, self.args) -- will not return unless unsuccessful
        if execp_err then
            sc.exit(errno)                                   -- exit with non-zero status
        end
    end
    -- parent
    self.process.pid = pid
    sc.close(ready_write)
    for _, v in pairs(self.pipes.child) do
        sc.close(v)
    end
    ready_read = file.fdopen(ready_read)
    ready_read:read_some_chars() -- will politely block until child is ready
    ready_read:close()

    local pidfd, pidfd_err = sc.pidfd_open(self.process.pid, 0)
    if not pidfd then return pidfd_err end

    self.process.pidfd = pidfd

    return nil
end

--- Kills the command.
-- @return Any error.
function Cmd:kill()
    if not self.process.pid then return "process not started" end
    if self.process.state then return "process has already completed" end

    local target = self._setpgid and -self.process.pid or self.process.pid
    local res, err, errno = sc.kill(target, sc.SIGKILL)
    assert(res==0 or errno==sc.ESRCH, err)
end

--- Creates a pipe for stdout. Call `:close()` when finished.
-- @return The stdout pipe or an error.
function Cmd:stdout_pipe()
    self.pipes.parent.stdout, self.pipes.child.stdout = sc.pipe()
    assert(self.pipes.parent.stdout and self.pipes.child.stdout)
    return file.fdopen(self.pipes.parent.stdout)
end

--- Creates a pipe for stderr. Call `:close()` when finished.
-- @return The stderr pipe or an error.
function Cmd:stderr_pipe()
    self.pipes.parent.stderr, self.pipes.child.stderr = sc.pipe()
    assert(self.pipes.parent.stderr and self.pipes.child.stderr)
    return file.fdopen(self.pipes.parent.stderr)
end

--- Creates a pipe for stdin. Call `:close()` when finished.
-- @return The stdin pipe or an error.
function Cmd:stdin_pipe()
    self.pipes.child.stdin, self.pipes.parent.stdin = sc.pipe()
    assert(self.pipes.child.stdin and self.pipes.parent.stdin)
    return file.fdopen(self.pipes.parent.stdin)
end


--- Waits for the command to complete.
-- @return The completion status or an error.
function Cmd:wait()
    local ops = { pollio.fd_readable_op(self.process.pidfd) }

    ops[#ops + 1] = self.ctx and self.ctx:done_op():wrap(function()
        self:kill()
        pollio.fd_readable_op(self.process.pidfd):perform()
    end)

    op.choice(unpack(ops)):perform()
    local _, _, status = sc.waitpid(self.process.pid)
    self.process.state = status
    sc.close(self.process.pidfd)
    if status ~= 0 then return status end
end

return {
    command = command,
    command_context = command_context
}
