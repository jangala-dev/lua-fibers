-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

-- File events.

local op = require 'fibers.op'
local runtime = require 'fibers.runtime'
local epoll = require 'fibers.epoll'
local sc = require 'fibers.utils.syscall'
local bit = rawget(_G, "bit") or require 'bit32'

local perform = require 'fibers.performer'.perform

local PollIOHandler = {}
PollIOHandler.__index = PollIOHandler

local function new_poll_io_handler()
    return setmetatable(
        {
            epoll = epoll.new(),
            waiting_for_readable = {}, -- sock descriptor => array of task
            waiting_for_writable = {}
        },                         -- sock descriptor => array of task
        PollIOHandler)
end

function PollIOHandler:init_nonblocking(fd)
    sc.set_nonblock(fd)
end

local function add_waiter(fd, waiters, task)
    local tasks = waiters[fd]
    if tasks == nil then
        tasks = {}; waiters[fd] = tasks
    end
    table.insert(tasks, task)
end

local function make_block_fn(fd, waiting, poll, events)
    return function(suspension, wrap_fn)
        local task = suspension:complete_task(wrap_fn)
        -- local fd = sc.fileno(fd)
        add_waiter(fd, waiting, task)
        poll:add(fd, events)
    end
end

function PollIOHandler:task_on_readable(fd, task)
    add_waiter(fd, self.waiting_for_readable, task)
    self.epoll:add(fd, epoll.RD)
end

function PollIOHandler:task_on_writable(fd, task)
    add_waiter(fd, self.waiting_for_writable, task)
    self.epoll:add(fd, epoll.WR)
end

function PollIOHandler:fd_readable_op(fd)
    local function try() return false end
    local block = make_block_fn(
        fd, self.waiting_for_readable, self.epoll, epoll.RD)
    return op.new_primitive(nil, try, block)
end

function PollIOHandler:fd_writable_op(fd)
    local function try() return false end
    local block = make_block_fn(
        fd, self.waiting_for_writable, self.epoll, epoll.WR)
    return op.new_primitive(nil, try, block)
end

function PollIOHandler:stream_readable_op(stream)
    local fd = assert(stream.io.fd)
    local function try() return not stream.rx:is_empty() end
    local block = make_block_fn(
        fd, self.waiting_for_readable, self.epoll, epoll.RD)
    return op.new_primitive(nil, try, block)
end

-- A stream_writable_op is the same as fd_writable_op, as a stream's
-- buffer is never left full -- any stream method that fills the buffer
-- flushes it directly.  Knowing something about the buffer state
-- doesn't tell us anything useful.
function PollIOHandler:stream_writable_op(stream)
    local fd = assert(stream.io.fd)
    return self:fd_writable_op(fd)
end

local function schedule_tasks(sched, tasks)
    -- It's possible for tasks to be nil, as an IO error will notify for
    -- both readable and writable, and maybe we only have tasks waiting
    -- for one side.
    if tasks == nil then return end
    for i = 1, #tasks do
        sched:schedule(tasks[i])
        tasks[i] = nil
    end
end

-- These method is called by the fibers scheduler.
function PollIOHandler:schedule_tasks(sched, _, timeout)
    if timeout == nil then timeout = 0 end
    if timeout >= 0 then timeout = timeout * 1e3 end
    for fd, event in pairs(self.epoll:poll(timeout)) do
        if bit.band(event, epoll.RD + epoll.ERR) ~= 0 then
            schedule_tasks(sched, self.waiting_for_readable[fd])
            self.waiting_for_readable[fd] = nil
        end
        if bit.band(event, epoll.WR + epoll.ERR) ~= 0 then
            schedule_tasks(sched, self.waiting_for_writable[fd])
            self.waiting_for_writable[fd] = nil
        end
        local mask = 0
        if self.waiting_for_readable[fd] ~= nil then mask = bit.bor(mask, epoll.RD) end
        if self.waiting_for_writable[fd] ~= nil then mask = bit.bor(mask, epoll.WR) end
        if mask ~= 0 then self.epoll:add(fd, mask) end
    end
end

PollIOHandler.wait_for_events = PollIOHandler.schedule_tasks

function PollIOHandler:cancel_tasks_for_fd(fd)
    local function cancel_tasks(waiting)
        local tasks = waiting[fd]
        if tasks ~= nil then
            for i = 1, #tasks do tasks[i]:cancel() end
            waiting[fd] = nil
        end
    end
    cancel_tasks(self.waiting_for_readable)
    cancel_tasks(self.waiting_for_writable)
end

function PollIOHandler:cancel_all_tasks()
    for fd, _ in pairs(self.waiting_for_readable) do
        self:cancel_tasks_for_fd(fd)
    end
    for fd, _ in pairs(self.waiting_for_writable) do
        self:cancel_tasks_for_fd(fd)
    end
end

local installed = 0
local installed_poll_handler
local function install_poll_io_handler()
    installed = installed + 1
    if installed == 1 then
        installed_poll_handler = new_poll_io_handler()
        -- file.set_blocking_handler(installed_poll_handler)
        runtime.current_scheduler:add_task_source(installed_poll_handler)
    end
    return installed_poll_handler
end

local function uninstall_poll_io_handler()
    installed = installed - 1
    if installed == 0 then
        -- file.set_blocking_handler(nil)
        -- FIXME: Remove task source.
        for i, source in ipairs(runtime.current_scheduler.sources) do
            if source == installed_poll_handler then
                table.remove(runtime.current_scheduler.sources, i)
                break
            end
        end
        installed_poll_handler.epoll:close()
        installed_poll_handler = nil
    end
end

local function init_nonblocking(fd)
    return assert(installed_poll_handler):init_nonblocking(fd)
end
local function fd_readable_op(fd)
    return assert(installed_poll_handler):fd_readable_op(fd)
end
local function fd_readable(fd)
    return perform(fd_readable_op(fd))
end
local function fd_writable_op(fd)
    return assert(installed_poll_handler):fd_writable_op(fd)
end
local function fd_writable(fd)
    return perform(fd_writable_op(fd))
end
local function stream_readable_op(stream)
    return assert(installed_poll_handler):stream_readable_op(stream)
end
local function stream_writable_op(stream)
    return assert(installed_poll_handler):stream_writable_op(stream)
end

return {
    init_nonblocking = init_nonblocking,
    fd_readable_op = fd_readable_op,
    fd_readable = fd_readable,
    fd_writable_op = fd_writable_op,
    fd_writable = fd_writable,
    stream_readable_op = stream_readable_op,
    stream_writable_op = stream_writable_op,
    install_poll_io_handler = install_poll_io_handler,
    uninstall_poll_io_handler = uninstall_poll_io_handler
}
