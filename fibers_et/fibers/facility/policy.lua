-- Launch policies for the friendly facade.
--
-- A policy is a small, explicit launch-time choice.  It may install a frame
-- that defines how facade operations such as fibers.perform and fibers.spawn
-- behave inside the launched computation.  It is not a generic scoped-values
-- carrier.

local Lifetime = require('fibers.facility.lifetime')
local Interrupt = require('fibers.internal.interrupt')
local Protected = require('fibers.kernel.protected')
local Exit = require('fibers.kernel.exit')

local unpack_ = table.unpack or unpack
local function pack(...) return { n = select('#', ...), ... } end

local Policy = {}

local Raw = {}
Raw.__index = Raw

function Raw:enter(runtime, parent)
  return { policy = self, runtime = runtime, parent = parent, name = self.name }
end

function Raw:run_root(_frame, fn, runtime)
  return fn(runtime)
end

function Raw:perform(frame, op)
  return frame.runtime:perform(op)
end

function Policy.raw()
  return setmetatable({ name = 'raw' }, Raw)
end

local NurseryFrame = {}
NurseryFrame.__index = NurseryFrame

function NurseryFrame:perform(op)
  local token = (self.mask_depth or 0) > 0 and nil or self.interrupt
  return self.runtime:perform(op, { interrupt = token })
end

function NurseryFrame:_child_frame(task)
  return setmetatable({
    policy = self.policy,
    runtime = self.runtime,
    parent = self,
    region = self.region,
    lifetime = self.lifetime,
    children = self.children,
    interrupt = task.interrupt,
    task = task,
    mask_depth = 0,
  }, NurseryFrame)
end

function NurseryFrame:spawn(fn, name)
  local task = self:perform(self.lifetime:spawn_op(fn, {
    name = name,
    frame = function(t) return self:_child_frame(t) end,
  }))
  self.children[#self.children + 1] = task
  return task
end

local function with_mask(frame, fn)
  frame.mask_depth = (frame.mask_depth or 0) + 1
  local r = pack(Protected.pcall(fn))
  frame.mask_depth = frame.mask_depth - 1
  if not r[1] then error(r[2], 0) end
  return unpack_(r, 2, r.n)
end

function NurseryFrame:_owns(task)
  return with_mask(self, function() return self:perform(self.lifetime:owns_op(task)) end)
end

function NurseryFrame:_cancel_owned(reason)
  for i = 1, #self.children do
    local task = self.children[i]
    if self:_owns(task) then with_mask(self, function() self:perform(self.lifetime:request_cancel_op(task, reason)) end) end
  end
end

function NurseryFrame:_join_and_settle_owned()
  local first_bad
  for i = 1, #self.children do
    local task = self.children[i]
    if self:_owns(task) then
      local exit = with_mask(self, function() return self:perform(task:exit_op()) end)
      if Exit.is(exit) and exit.tag == 'failed' and not first_bad then first_bad = exit end
      if self:_owns(task) then with_mask(self, function() self:perform(self.lifetime:retire_op(task)) end) end
    end
  end
  return first_bad
end

local Nursery = {}
Nursery.__index = Nursery

function Nursery:enter(runtime, parent)
  local lifetime = Lifetime.new(self.name or 'nursery')
  return setmetatable({
    policy = self,
    runtime = runtime,
    parent = parent,
    lifetime = lifetime,
    region = lifetime.region,
    children = {},
    interrupt = Interrupt.new((self.name or 'nursery') .. '-root'),
    mask_depth = 0,
  }, NurseryFrame)
end

function Nursery:run_root(frame, fn)
  local results = { Protected.pcall(fn, frame) }
  local ok = table.remove(results, 1)
  with_mask(frame, function() frame:perform(frame.lifetime:close_op()) end)
  if not ok then frame:_cancel_owned(results[1]) end
  local child_bad = frame:_join_and_settle_owned()
  if not ok then error(results[1], 0) end
  if child_bad then error(child_bad.error or child_bad.reason or 'nursery child failed', 0) end
  return unpack_(results, 1, #results)
end

function Policy.nursery(opts)
  opts = opts or {}
  return setmetatable({ name = opts.name or 'nursery' }, Nursery)
end

return Policy
