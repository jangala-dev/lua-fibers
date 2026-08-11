-- Transactional resource pool with retirement.
--
-- Pool is ordinary Lua composition over Index + Keyed + ClaimSet + Machine + Effect.
-- The v1 pool is deliberately small: fixed resources, exclusive leases,
-- deferred retirement for leased items, and close preventing future add/acquire.
-- Item metadata lives in Keyed; idle membership lives in Index; active leases
-- live in ClaimSet.  Pool state does not duplicate idle/leased status.

local Op = require('fibers.op')
local StateMachine = require('fibers.resource.machine')
local Ready = StateMachine.Ready
local Index = require('fibers.resource.index')
local Keyed = require('fibers.resource.keyed')
local ClaimSet = require('fibers.resource.claim_set')
local Effect = require('fibers.effect')

local Pool = {}
Pool.__index = Pool
local next_id = 0

local RetireKind
RetireKind = Effect.kind({
  name = 'pool.retire',
  key = function(payload)
    return (payload.pool_id or '') .. ':' .. tostring(payload.key)
  end,
  merge = function(a, _b)
    return a
  end,
  prepare = function(_rt, payload)
    return {
      kind = RetireKind,
      key = (payload.pool_id or '') .. ':' .. tostring(payload.key),
      payload = payload,
      discharge = function(rt, entry)
        local p = entry.payload
        if p.retire then
          return p.retire(p.item, p.reason, p.key, p.pool)
        end
        local host = rt.host or {}
        if host.pool_retire then
          return host.pool_retire(p.item, p.reason, p.key, p.pool)
        end
      end,
    }
  end,
})

local function retire_effect(pool, key, item, reason)
  return Effect.of(RetireKind, {
    pool = pool,
    pool_id = pool._fibers_id,
    key = key,
    item = item,
    reason = reason,
    retire = pool.retire,
  })
end

local function item_state(item, retire_on_release, reason)
  return { item = item, retire_on_release = retire_on_release == true, reason = reason }
end

local function retiring_state(state, reason)
  return { item = state.item, retire_on_release = true, reason = reason or state.reason }
end

local CheckOpen = StateMachine.update('pool.check_open', function(open)
    if open == true then
      return Ready.write(true, true)
    end
    return Ready.write(open, false)
end, 100)

local Close = StateMachine.update('pool.close', function()
    return Ready.write(false, true)
end)

local function require_open(pool)
  return pool.open:transition_op(CheckOpen):and_then(Op.guard(function(ok)
    if ok then
      return Op.always(true)
    end
    return Op.never()
  end))
end

function Pool.new(opts)
  opts = opts or {}
  next_id = next_id + 1
  local id = 'pool-' .. tostring(next_id)
  return setmetatable({
    _fibers_id = id,
    open = opts.open or StateMachine.new(true),
    idle = opts.idle or Index.new(),
    items = opts.items or Keyed.new(),
    leases = opts.leases or ClaimSet.new({ lease = {} }),
    retire = opts.retire,
  }, Pool)
end

function Pool:label(...)
  if select('#', ...) == 0 then return self._label end
  local value = select(1, ...)
  if value ~= nil and (type(value) ~= 'string' or value == '') then
    error('Pool:label expects a non-empty string or nil', 2)
  end
  self._label = value
  self.open:label(value and value .. ':open' or nil)
  self.idle:label(value and value .. ':idle' or nil)
  self.items:label(value and value .. ':items' or nil)
  self.leases:label(value and value .. ':leases' or nil)
  return self
end

function Pool:add_op(key, item)
  if key == nil then
    error('pool add requires key', 2)
  end
  return require_open(self):and_then(
    self.items:insert_op(key, item_state(item)):and_then(
      self.idle:insert_op(key, math.huge, key)
    )
  )
end

function Pool:acquire_op(holder)
  if holder == nil then
    error('pool acquire requires holder', 2)
  end
  return require_open(self):and_then(self.idle:pop_first_op():and_then(Op.guard(function(entry)
      local key = entry.value
      return self.items:get_op(key):and_then(Op.guard(function(state)
        if type(state) ~= 'table' then
          return Op.never()
        end
        return self.leases:acquire_op(key, 'lease', holder):map(function()
          return { pool = self, key = key, item = state.item, holder = holder }
        end)
      end))
    end)))
end

function Pool:release_op(lease)
  if type(lease) ~= 'table' then
    error('pool release expects a lease table', 2)
  end
  local key, holder = lease.key, lease.holder
  return self.items:get_op(key):and_then(Op.guard(function(state)
    if type(state) ~= 'table' then
      return Op.never()
    end
    if state.retire_on_release then
      return Op.together({
        self.leases:release_op(key, holder),
        self.items:take_op(key),
        Op.emit(retire_effect(self, key, state.item, state.reason)),
      }):map(function()
        return true
      end)
    end
    return Op.together({
      self.leases:release_op(key, holder),
      self.idle:insert_op(key, math.huge, key),
    }):map(function()
      return true
    end)
  end))
end

function Pool:retire_op(key, reason)
  if key == nil then
    error('pool retire requires key', 2)
  end
  return self.items:get_op(key):and_then(Op.guard(function(state)
    if type(state) ~= 'table' then
      return Op.never()
    end
    local retire_idle = Op.together({
      self.idle:remove_op(key),
      self.items:take_op(key),
      Op.emit(retire_effect(self, key, state.item, reason)),
    }):map(function()
      return true
    end)
    local defer_until_release = self.items:put_op(key, retiring_state(state, reason)):map(function()
      return true
    end)
    return retire_idle:or_else(defer_until_release)
  end))
end

function Pool:close_op(_reason)
  return self.open:transition_op(Close)
end

return Pool
