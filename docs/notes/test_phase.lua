package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local Op = require('fibers.op')
local Lifetime = require('fibers.lifetime')
local Runtime = require('fibers.runtime')
local Phase = dofile('docs/notes/phase.lua')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end

-- Phase is a prototype compound over Scope: a later phase can receive custody
-- before it runs, but only through a declared crossing.
do
  local frame = Phase.new('frame'):phase('input'):phase('render')
  frame:edge('input', 'render'):carry('asset'):done()

  local h = { name = 'phase-resource' }; Lifetime.inert(h, { role = 'asset' })
  local render_lifetime, custodian_after_input, render_authorised, custodian_after_render, undeclared_move
  fibers.run(function()
    frame.runtime = Runtime.current()
    frame:run('input', function(input)
      local render = frame:scope('render')
      render_lifetime = render:lifetime()
      fibers.perform(input:admit_op(h))
      undeclared_move = fibers.perform(frame
        :move_op(h, 'input', 'physics', 'asset')
        :map(function()
          return 'moved'
        end)
        :or_else(Op.always('blocked')))
      fibers.perform(frame:move_op(h, 'input', 'render', 'asset'))
    end)
    custodian_after_input = Lifetime.of(h):current_state().custodian
    frame:run('render', function(render)
      render_authorised = fibers.perform(render:can_op(h, 'use')) == h
    end)
    custodian_after_render = Lifetime.of(h):current_state().custodian
  end)
  assert_eq(undeclared_move, 'blocked', 'phase movement should require a declared edge and carry label')
  assert_eq(custodian_after_input, render_lifetime, 'later phase should receive custody moved from input')
  assert_eq(render_authorised, true, 'render phase should authorise the carried resource')
  assert_eq(custodian_after_render, nil, 'render phase should close carried resource on exit')
end

-- Declared Grant crossings add authority without moving custody.
do
  local frame = Phase.new('frame-grant'):phase('simulate'):phase('extract')
  frame:edge('simulate', 'extract'):grant('world_view'):done()

  local world = { name = 'phase-world-view' }; Lifetime.inert(world, { role = 'world_view', rights = { read = true, write = true } })
  local custodian_after_grant, read_authorised, write_authorised, undeclared_grant
  fibers.run(function(root)
    frame.runtime = Runtime.current()
    fibers.perform(root:admit_op(world))
    frame:run('simulate', function(sim)
      undeclared_grant = fibers.perform(frame
        :grant_op('simulate', world, 'render', { 'read' }, 'world_view')
        :map(function()
          return 'granted'
        end)
        :or_else(Op.always('blocked')))
      fibers.perform(frame:grant_op('simulate', world, 'extract', { 'read' }, 'world_view'))
      custodian_after_grant = Lifetime.of(world):current_state().custodian
    end)
    frame:run('extract', function(extract)
      read_authorised = fibers.perform(extract:can_op(world, 'read')) == world
      write_authorised = fibers.perform(extract
        :can_op(world, 'write')
        :map(function()
          return true
        end)
        :or_else(Op.always(false)))
    end)
  end)
  assert_eq(undeclared_grant, 'blocked', 'phase granting should require a declared Grant edge')
  assert_eq(custodian_after_grant ~= nil, true, 'Grant should not move custody from the parent Lifetime')
  assert_eq(read_authorised, true, 'declared phase Grant should provide requested authority')
  assert_eq(write_authorised, false, 'declared read Grant should not grant write authority')
end

-- Declared fact crossings copy phase facts without moving custody or authority.
do
  local frame = Phase.new('frame-facts'):phase('input'):phase('simulate')
  frame:edge('input', 'simulate'):fact('commands'):done()

  local carried, blocked, seen
  fibers.run(function()
    frame.runtime = Runtime.current()
    frame:run('input', function(_input, ph)
      fibers.perform(ph:put_fact_op('input', 'commands', { jump = true }))
      blocked = fibers.perform(ph:carry_fact_op('commands', 'input', 'render')
        :map(function()
          return 'carried'
        end)
        :or_else(Op.always('blocked')))
      carried = fibers.perform(ph:carry_fact_op('commands', 'input', 'simulate'))
    end)
    frame:run('simulate', function(_sim, ph)
      seen = fibers.perform(ph:get_fact_op('simulate', 'commands'))
    end)
  end)
  assert_eq(blocked, 'blocked', 'fact crossing should require a declared fact edge')
  assert_eq(carried.jump, true, 'carry_fact_op should return the carried fact')
  assert_eq(seen.jump, true, 'later phase should receive the carried fact')
end

-- A phase interval is spent after it runs; running the same named phase again
-- creates a fresh Scope interval.
do
  local frame = Phase.new('frame-fresh'):phase('tick')
  local first, second
  fibers.run(function()
    frame.runtime = Runtime.current()
    frame:run('tick', function(scope)
      first = scope
    end)
    frame:run('tick', function(scope)
      second = scope
    end)
  end)
  assert_eq(first ~= second, true, 'phase run should create a fresh interval after Closure')
end

print('docs/notes/test_phase.lua: ok')
