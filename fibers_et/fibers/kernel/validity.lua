-- Managed validity capabilities.
--
-- This module is the resource-authoring API for search-valid mutable facts.
-- Resource authors build validity-relevant state out of these capabilities and
-- interact with them through their methods.  Reads record observations
-- automatically when the active context is retaining a cursor or prepared world;
-- writes bump the correct fact stamps automatically.  The transaction solver
-- sees only generation-stamped frontiers and observers.
--
-- Basis and derived capabilities:
--   scalar   one replaceable fact
--   level    keyed boolean facts
--   signal   latched non-consuming fact
--   queue    ordered consuming sequence with empty/head/tail facts
--   clock    deadline frontiers
--   map      keyed membership/value/structure facts
--   set      membership view over map
--   claim    ownership view over map
--   derived  view whose validity is the facts read by its body
--   epoch    conservative opaque fact
--
-- See docs/validity-algebra.md and docs/kernel/validity-authoring.md.

local FrontierKit = require('fibers.kernel.frontier')

local Validity = {}

local function name_part(x) return x == nil and '' or tostring(x) end
local pack_ = table.pack or function(...) return { n = select('#', ...), ... } end
local unpack_ = table.unpack or unpack

local function observe(ctx, frontier)
  if not frontier then return nil end
  if ctx and ctx.observing == false then return frontier.gen or 0 end
  if ctx and ctx.observe_frontier then return ctx:observe_frontier(frontier) end
  return frontier:observe(ctx and ctx.observer or nil)
end

local Scalar = {}
Scalar.__index = Scalar

function Validity.scalar(value, name, opts)
  opts = opts or {}
  return setmetatable({
    kind = 'scalar',
    name = name or 'scalar',
    value = value,
    frontier = FrontierKit.Frontier.new((name or 'scalar') .. ':value'),
    on_set = opts.on_set,
    equal = opts.equal,
  }, Scalar)
end

function Scalar:get(ctx)
  observe(ctx, self.frontier)
  return self.value
end

function Scalar:project()
  return self.value
end

function Scalar:set(value, reason)
  local equal = self.equal or function(a, b) return a == b end
  if equal(self.value, value) then return false end
  self.value = value
  if self.on_set then self.on_set(value) end
  self.frontier:invalidate(reason or 'scalar set')
  return true
end

function Scalar:bump(reason)
  self.frontier:invalidate(reason or 'scalar bump')
end

function Scalar:frontier_for(_kind, _key) return self.frontier end

local Epoch = {}
Epoch.__index = Epoch

function Validity.epoch(name)
  return setmetatable({ kind = 'epoch', name = name or 'epoch', frontier = FrontierKit.Frontier.new((name or 'epoch') .. ':epoch') }, Epoch)
end
function Epoch:observe(ctx) observe(ctx, self.frontier); return self.frontier.gen or 0 end
function Epoch:bump(reason) self.frontier:invalidate(reason or 'epoch bump') end
function Epoch:frontier_for() return self.frontier end

local Queue = {}
Queue.__index = Queue

function Validity.queue(name, opts)
  opts = opts or {}
  return setmetatable({
    kind = 'queue',
    name = name or 'queue',
    items = {},
    head = 1,
    tail = 0,
    on_sync = opts.on_sync,
    frontiers = {
      empty = FrontierKit.Frontier.new((name or 'queue') .. ':empty'),
      head = FrontierKit.Frontier.new((name or 'queue') .. ':head'),
      tail = FrontierKit.Frontier.new((name or 'queue') .. ':tail'),
    },
  }, Queue)
end

function Queue:count()
  local n = (self.tail or 0) - (self.head or 1) + 1
  return n > 0 and n or 0
end

function Queue:sync()
  if self.on_sync then self.on_sync(self) end
end

function Queue:frontier_for(kind, key)
  if kind == 'queue.item' then return self.frontiers.head end
  if kind == 'queue.head' or kind == 'head' then return self.frontiers.head end
  if kind == 'queue.tail' or kind == 'tail' then return self.frontiers.tail end
  if kind == 'queue.empty' or kind == 'empty' then return self.frontiers.empty end
  return self.frontiers.head
end

function Queue:peek(ctx, offset)
  offset = offset or 0
  local idx = (self.head or 1) + offset
  if idx <= (self.tail or 0) then
    observe(ctx, self.frontiers.head)
    return self.items[idx]
  end
  observe(ctx, self.frontiers.empty)
  return nil
end

function Queue:push(value, reason)
  local was_empty = self:count() <= 0
  self.tail = (self.tail or 0) + 1
  self.items[self.tail] = value
  if was_empty then
    self.frontiers.empty:invalidate(reason or 'queue became non-empty')
    self.frontiers.head:invalidate(reason or 'queue head appeared')
  end
  self.frontiers.tail:invalidate(reason or 'queue tail changed')
  self:sync()
end

function Queue:take(n, reason)
  n = n or 1
  if n <= 0 then return false end
  local before = self:count()
  if before < n then return false, 'queue-underflow' end
  for i = 1, n do self.items[(self.head or 1) + i - 1] = nil end
  self.head = (self.head or 1) + n
  if self.head > (self.tail or 0) then
    self.items = {}
    self.head = 1
    self.tail = 0
  end
  self.frontiers.head:invalidate(reason or 'queue head consumed')
  if before > 0 and self:count() <= 0 then self.frontiers.empty:invalidate(reason or 'queue became empty') end
  self:sync()
  return true
end

function Queue:clear(reason)
  self.items = {}; self.head = 1; self.tail = 0
  self.frontiers.head:invalidate(reason or 'queue cleared')
  self.frontiers.tail:invalidate(reason or 'queue cleared')
  self.frontiers.empty:invalidate(reason or 'queue cleared')
  self:sync()
end

local Signal = {}
Signal.__index = Signal

function Validity.signal(name, opts)
  opts = opts or {}
  return setmetatable({
    kind = 'signal',
    name = name or 'signal',
    ready = false,
    value = nil,
    frontier = FrontierKit.Frontier.new((name or 'signal') .. ':state'),
    on_sync = opts.on_sync,
  }, Signal)
end

function Signal:get(ctx)
  observe(ctx, self.frontier)
  if not self.ready then return nil, false end
  return self.value, true
end

function Signal:set(value, reason)
  self.ready = true
  self.value = value
  self.frontier:invalidate(reason or 'signal set')
  if self.on_sync then self.on_sync(self) end
end

function Signal:clear(reason)
  if not self.ready and self.value == nil then return false end
  self.ready = false
  self.value = nil
  self.frontier:invalidate(reason or 'signal cleared')
  if self.on_sync then self.on_sync(self) end
  return true
end
function Signal:frontier_for() return self.frontier end

local Level = {}
Level.__index = Level

function Validity.level(name, opts)
  opts = opts or {}
  return setmetatable({ kind = 'level', name = name or 'level', values = {}, frontiers = {}, on_sync = opts.on_sync }, Level)
end

function Level:frontier_for(_kind, key)
  key = key or 'default'
  local f = self.frontiers[key]
  if not f then
    f = FrontierKit.Frontier.new((self.name or 'level') .. ':' .. name_part(key))
    self.frontiers[key] = f
  end
  return f
end

function Level:get(ctx, key)
  observe(ctx, self:frontier_for(nil, key))
  return self.values[key or 'default'] == true
end

function Level:set(key, value, reason)
  key = key or 'default'
  local old = self.values[key] == true
  local new = value == true
  if old == new then return false end
  if new then self.values[key] = true else self.values[key] = nil end
  self:frontier_for(nil, key):invalidate(reason or 'level set')
  if self.on_sync then self.on_sync(self) end
  return true
end

function Level:clear(key, reason)
  if key == nil then
    for k in pairs(self.values) do self:set(k, false, reason or 'level clear') end
  else
    self:set(key, false, reason or 'level clear')
  end
end


local Map = {}
Map.__index = Map
local PRESENT = {}
local NIL_VALUE = {}

local function encode_value(value) return value == nil and NIL_VALUE or value end
local function decode_value(value) if value == NIL_VALUE then return nil end; return value end
local function value_equal(eq, a, b) return (eq or function(x, y) return x == y end)(decode_value(a), decode_value(b)) end

function Validity.map(name, opts)
  opts = opts or {}
  return setmetatable({
    kind = 'map',
    name = name or 'map',
    values = {},
    present = {},
    size = 0,
    frontiers = {
      structure = FrontierKit.Frontier.new((name or 'map') .. ':structure'),
      membership = {},
      value = {},
    },
    on_sync = opts.on_sync,
    equal = opts.equal,
  }, Map)
end

function Map:membership_frontier(key)
  local f = self.frontiers.membership[key]
  if not f then
    f = FrontierKit.Frontier.new((self.name or 'map') .. ':membership:' .. name_part(key))
    self.frontiers.membership[key] = f
  end
  return f
end

function Map:value_frontier(key)
  local f = self.frontiers.value[key]
  if not f then
    f = FrontierKit.Frontier.new((self.name or 'map') .. ':value:' .. name_part(key))
    self.frontiers.value[key] = f
  end
  return f
end

function Map:frontier_for(kind, key)
  if kind == 'map.value' or kind == 'value' then return self:value_frontier(key) end
  if kind == 'map.membership' or kind == 'membership' or kind == 'contains' then return self:membership_frontier(key) end
  return self.frontiers.structure
end

function Map:contains(ctx, key)
  observe(ctx, self:membership_frontier(key))
  return self.present[key] == PRESENT
end

function Map:get(ctx, key)
  observe(ctx, self:membership_frontier(key))
  if self.present[key] ~= PRESENT then return nil, false end
  observe(ctx, self:value_frontier(key))
  return decode_value(self.values[key]), true
end

function Map:count(ctx)
  observe(ctx, self.frontiers.structure)
  return self.size or 0
end

function Map:pairs(ctx)
  observe(ctx, self.frontiers.structure)
  local values, present = self.values, self.present
  local function iter(_, key)
    local next_key = next(present, key)
    if next_key == nil then return nil end
    return next_key, decode_value(values[next_key])
  end
  return iter, nil, nil
end

function Map:snapshot(ctx)
  observe(ctx, self.frontiers.structure)
  local out = {}
  for key in pairs(self.present) do out[key] = decode_value(self.values[key]) end
  return out
end

function Map:set(key, value, reason)
  local existed = self.present[key] == PRESENT
  local encoded = encode_value(value)
  if existed and value_equal(self.equal, self.values[key], encoded) then return false end
  self.values[key] = encoded
  if not existed then
    self.present[key] = PRESENT
    self.size = (self.size or 0) + 1
    self:membership_frontier(key):invalidate(reason or 'map membership added')
    self.frontiers.structure:invalidate(reason or 'map structure changed')
  end
  self:value_frontier(key):invalidate(reason or 'map value set')
  if self.on_sync then self.on_sync(self) end
  return true
end

function Map:update(key, fn, reason)
  if type(fn) ~= 'function' then error('map update requires a function', 2) end
  local old, present = self:get(nil, key)
  local new_value, keep = fn(old, present)
  if keep == false then return self:remove(key, reason or 'map update remove') end
  return self:set(key, new_value, reason or 'map update')
end

function Map:remove(key, reason)
  if self.present[key] ~= PRESENT then return false end
  self.present[key] = nil
  self.values[key] = nil
  self.size = (self.size or 0) - 1
  self:membership_frontier(key):invalidate(reason or 'map membership removed')
  self:value_frontier(key):invalidate(reason or 'map value removed')
  self.frontiers.structure:invalidate(reason or 'map structure changed')
  if self.on_sync then self.on_sync(self) end
  return true
end

function Map:clear(reason)
  if (self.size or 0) == 0 then return false end
  for key in pairs(self.present) do
    self.present[key] = nil
    self.values[key] = nil
    self:membership_frontier(key):invalidate(reason or 'map cleared')
    self:value_frontier(key):invalidate(reason or 'map cleared')
  end
  self.size = 0
  self.frontiers.structure:invalidate(reason or 'map cleared')
  if self.on_sync then self.on_sync(self) end
  return true
end

local Set = {}
Set.__index = Set

function Validity.set(name, opts)
  return setmetatable({ kind = 'set', name = name or 'set', map = Validity.map((name or 'set') .. ':members', opts) }, Set)
end

function Set:frontier_for(kind, key) return self.map:frontier_for(kind, key) end
function Set:contains(ctx, key) return self.map:contains(ctx, key) end
function Set:add(key, reason) return self.map:set(key, true, reason or 'set add') end
function Set:remove(key, reason) return self.map:remove(key, reason or 'set remove') end
function Set:count(ctx) return self.map:count(ctx) end
function Set:pairs(ctx)
  local iter, state, seed = self.map:pairs(ctx)
  local function members(s, k)
    local key = iter(s, k)
    return key
  end
  return members, state, seed
end
function Set:clear(reason) return self.map:clear(reason or 'set clear') end

local Lease = {}
Lease.__index = Lease

function Validity.lease(name, opts)
  return setmetatable({ kind = 'lease', name = name or 'lease', owners = Validity.map((name or 'lease') .. ':owners', opts) }, Lease)
end

function Lease:frontier_for(kind, key) return self.owners:frontier_for(kind, key) end
function Lease:owner(ctx, key) return self.owners:get(ctx, key) end
function Lease:is_free(ctx, key) return not self.owners:contains(ctx, key) end
function Lease:acquire(key, owner, reason)
  if owner == nil then error('lease holder must not be nil', 2) end
  local current, present = self.owners:get(nil, key)
  if present then
    if current == owner then return true, 'already-owner' end
    return false, 'leased', current
  end
  self.owners:set(key, owner, reason or 'lease acquired')
  return true
end
function Lease:release(key, owner, reason)
  local current, present = self.owners:get(nil, key)
  if not present then return false end
  if owner ~= nil and current ~= owner then return false, 'not-owner' end
  return self.owners:remove(key, reason or 'lease released')
end
function Lease:transfer(key, from_owner, to_owner, reason)
  if to_owner == nil then error('lease transfer target must not be nil', 2) end
  local current, present = self.owners:get(nil, key)
  if not present then return false, 'free' end
  if from_owner ~= nil and current ~= from_owner then return false, 'not-owner' end
  return self.owners:set(key, to_owner, reason or 'lease transferred')
end

local Derived = {}
Derived.__index = Derived

local function replay_observer(ctx, observer)
  if not (ctx and observer and observer.observations) then return end
  for i = 1, #observer.observations do observe(ctx, observer.observations[i].frontier) end
end

local function derived_ctx(parent, observer)
  return {
    observer = observer,
    observing = true,
    observe_frontier = function(self, frontier)
      if frontier then frontier:observe(observer) end
      observe(parent, frontier)
      return frontier and frontier.gen or nil
    end,
    now = parent and parent.now,
    rt = parent and parent.rt,
    overlay = parent and parent.overlay,
    origin = parent and parent.origin,
  }
end

function Validity.derived(fn, name, opts)
  if type(fn) ~= 'function' then error('derived requires a function', 2) end
  opts = opts or {}
  return setmetatable({ kind = 'derived', name = name or 'derived', fn = fn, cache = opts.cache == true, cached = nil, observer = nil }, Derived)
end

function Derived:clear()
  if self.observer and self.observer.dispose then self.observer:dispose() end
  self.observer = nil
  self.cached = nil
end

function Derived:get(ctx, ...)
  if self.cache and self.cached and self.observer and self.observer:validate() then
    replay_observer(ctx, self.observer)
    return unpack_(self.cached, 1, self.cached.n)
  end

  if not self.cache then return self.fn(ctx, ...) end

  local observer = FrontierKit.Observer.new('derived', self)
  local values = pack_(self.fn(derived_ctx(ctx, observer), ...))
  if self.observer and self.observer.dispose then self.observer:dispose() end
  self.observer = observer
  self.cached = values
  return unpack_(values, 1, values.n)
end

function Derived:project(ctx, ...) return self:get(ctx, ...) end
function Derived:frontier_for() return nil end

local Clock = {}
Clock.__index = Clock

function Validity.clock(name)
  return setmetatable({ kind = 'clock', name = name or 'clock', before = {} }, Clock)
end

function Clock:before_frontier(deadline)
  local f = self.before[deadline]
  if not f then
    f = FrontierKit.Frontier.new((self.name or 'clock') .. ':before:' .. tostring(deadline))
    self.before[deadline] = f
  end
  return f
end

function Clock:observe_before(ctx, deadline)
  observe(ctx, self:before_frontier(deadline))
end

function Clock:invalidate_matured(now)
  for deadline, frontier in pairs(self.before) do
    if now >= deadline then
      self.before[deadline] = nil
      frontier:invalidate('clock deadline reached')
    end
  end
end

function Clock:frontier_for(kind, key)
  if kind == 'clock-before' then return self:before_frontier(key) end
  return self:before_frontier(key or 0)
end

Validity.Scalar = Scalar
Validity.Queue = Queue
Validity.Signal = Signal
Validity.Level = Level
Validity.Clock = Clock
Validity.Epoch = Epoch
Validity.Map = Map
Validity.Set = Set
Validity.Lease = Lease
Validity.Derived = Derived

return Validity
