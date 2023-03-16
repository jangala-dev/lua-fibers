-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

-- File events.

local op = require('fibers.op')
local fiber = require('fibers.fiber')
local epoller = require('fibers.epoller')
local sc = require('fibers.utils.syscall')
local file = require('stream.stream.file')

local bit = require('bit32')

local PollIOHandler = {}
local PollIOHandler_mt = { __index=PollIOHandler }
local function new_poll_io_handler()
   return setmetatable(
      { epoll=epoller.new(),
        waiting_for_readable={},   -- sock descriptor => array of task
        waiting_for_writable={} }, -- sock descriptor => array of task
      PollIOHandler_mt)
end

-- These three methods are "blocking handler" methods and are called by
-- lib.stream.file.
function PollIOHandler:init_nonblocking(fd)
   sc.set_nonblock(fd)
end
function PollIOHandler:wait_for_readable(fd)
   self:fd_readable_op(fd):perform()
end
function PollIOHandler:wait_for_writable(fd)
   self:fd_writable_op(fd):perform()
end

local function add_waiter(fd, waiters, task)
   local tasks = waiters[fd]
   if tasks == nil then tasks = {}; waiters[fd] = tasks end
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

function PollIOHandler:fd_readable_op(fd)
   local function try() return false end
   local block = make_block_fn(
      fd, self.waiting_for_readable, self.epoll, epoller.RD)
   return op.new_base_op(nil, try, block)
end

function PollIOHandler:fd_writable_op(fd)
   local function try() return false end
   local block = make_block_fn(
      fd, self.waiting_for_writable, self.epoll, epoller.WR)
   return op.new_base_op(nil, try, block)
end

function PollIOHandler:stream_readable_op(stream)
   local fd = assert(stream.io.fd)
   local function try() return not stream.rx:is_empty() end
   local block = make_block_fn(
      fd, self.waiting_for_readable, self.epoll, epoller.RD)
   return op.new_base_op(nil, try, block)
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
   for i=1,#tasks do
      sched:schedule(tasks[i])
      tasks[i] = nil
   end
end

-- These method is called by the fibers scheduler.
function PollIOHandler:schedule_tasks(sched, now, timeout)
   if timeout == nil then timeout = 0 end
   if timeout >= 0 then timeout = timeout * 1e3 end
   for fd, event in pairs(self.epoll:poll(timeout)) do
      if bit.band(event, epoller.RD + epoller.ERR) ~= 0 then
         local tasks = self.waiting_for_readable[fd]
         schedule_tasks(sched, tasks)
      end
      if bit.band(event, epoller.WR + epoller.ERR) ~= 0 then
         local tasks = self.waiting_for_writable[fd]
         schedule_tasks(sched, tasks)
      end
   end
end

PollIOHandler.wait_for_events = PollIOHandler.schedule_tasks

function PollIOHandler:cancel_tasks_for_fd(fd)
   local function cancel_tasks(waiting)
      local tasks = waiting[fd]
      if tasks ~= nil then
         for i=1,#tasks do tasks[i]:cancel() end
         waiting[fd] = nil
      end
   end
   cancel_tasks(self.waiting_for_readable)
   cancel_tasks(self.waiting_for_writable)
end

function PollIOHandler:cancel_all_tasks()
   for fd,_ in pairs(self.waiting_for_readable) do
      self:cancel_tasks_for_fd(fd)
   end
   for fd,_ in pairs(self.waiting_for_writable) do
      self:cancel_tasks_for_fd(fd)
   end
end

local installed = 0
local installed_poll_handler
local function install_poll_io_handler()
   installed = installed + 1
   if installed == 1 then
      installed_poll_handler = new_poll_io_handler()
      file.set_blocking_handler(installed_poll_handler)
      fiber.current_scheduler:add_task_source(installed_poll_handler)
   end
   return installed_poll_handler
end

local function uninstall_poll_io_handler()
   installed = installed - 1
   if installed == 0 then
      -- file.set_blocking_handler(nil)
      -- FIXME: Remove task source.
      for i,source in ipairs(fiber.current_scheduler.sources) do
         if source == installed_poll_handler then
            table.remove(fiber.current_scheduler.sources, i)
            break
         end
      end
      installed_poll_handler.poll:close()
      installed_poll_handler = nil
   end
end

local function fd_readable_op(fd)
   return assert(installed_poll_handler):fd_readable_op(fd)
end
local function fd_writable_op(fd)
   return assert(installed_poll_handler):fd_writable_op(fd)
end
local function stream_readable_op(stream)
   return assert(installed_poll_handler):stream_readable_op(stream)
end
local function stream_writable_op(stream)
   return assert(installed_poll_handler):stream_writable_op(stream)
end

local function selftest()
   print('selftest: lib.fibers.file')
   local equal = require 'fibers.utils.helper'.equal
   local log = {}
   local function record(x) table.insert(log, x) end

   local handler = new_poll_io_handler()
   file.set_blocking_handler(handler)
   fiber.current_scheduler:add_task_source(handler)

   fiber.current_scheduler:run()
   assert(equal(log, {}))

   local rd, wr = file.pipe()
   local message = "hello, world\n"
   fiber.spawn(function()
                  record('rd-a')
                  local str = rd:read_some_chars()
                  record('rd-b')
                  record(str)
               end)
   fiber.spawn(function()
                  record('wr-a')
                  wr:write(message)
                  record('wr-b')
                  wr:flush()
                  record('wr-c')
               end)

   fiber.current_scheduler:run()
   assert(equal(log, {'rd-a', 'wr-a', 'wr-b', 'wr-c'}))
   fiber.current_scheduler:run()
   assert(equal(log, {'rd-a', 'wr-a', 'wr-b', 'wr-c', 'rd-b', message}))

   print('selftest: ok')

   -- print('REVISED selftest: lib.fibers.file')
   -- local sleep = require "fibers.sleep"

   -- local handler = install_poll_io_handler()
   -- fiber.current_scheduler:add_task_source(handler)

   -- local function main()
   --    local f = assert(io.popen("echo hello; sleep 3; echo world"))
   --    local counter = 0
   --    local loop = true
   --    fiber.spawn(function()
   --       while loop do
   --          fd_readable_op(sc.fileno(f)):perform()
   --          local line = f:read("*l")
   --          if not line then 
   --             assert(counter > 5)
   --             f:close()
   --             loop = false
   --          end
   --       end
   --    end)
   --    while loop do
   --       counter = counter + 1
   --       sleep.sleep(1/3)
   --    end
   -- end
   -- fiber.spawn(function()
   --    main()
   --    fiber.stop()
   -- end)
   -- fiber.main()
   -- print("selftest: ok")
end

return {
   fd_readable_op = fd_readable_op,
   fd_writable_op = fd_writable_op,
   stream_readable_op = stream_readable_op,
   stream_writable_op = stream_writable_op,
   install_poll_io_handler = install_poll_io_handler,
   uninstall_poll_io_handler = uninstall_poll_io_handler,
   selftest = selftest,
}