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
local FibersRegion = require('fibers.lifetime.region')
local Phase = require('experiments.phase')

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

  local h = FibersRegion.handle('phase-resource', { kind = 'asset' })
  local render_region, owner_after_input, render_authorised, owner_after_render, undeclared_move
  fibers.run(function()
    frame:run('input', function(input)
      local render = frame:scope('render')
      render_region = render:raw_region()
      fibers.perform(input:admit_op(h))
      undeclared_move = fibers.perform(frame
        :move_op(h, 'input', 'physics', 'asset')
        :map(function()
          return 'moved'
        end)
        :or_else(Op.always('blocked')))
      fibers.perform(frame:move_op(h, 'input', 'render', 'asset'))
    end)
    owner_after_input = h.owner
    frame:run('render', function(render)
      render_authorised = fibers.perform(render:authorise_op(h, 'use')) == h
    end)
    owner_after_render = h.owner
  end)
  assert_eq(undeclared_move, 'blocked', 'phase movement should require a declared edge and carry label')
  assert_eq(owner_after_input, render_region, 'later phase should receive custody moved from input')
  assert_eq(render_authorised, true, 'render phase should authorise the carried resource')
  assert_eq(owner_after_render, nil, 'render phase should settle carried resource on exit')
end

-- Declared borrow crossings grant authority without moving custody.
do
  local frame = Phase.new('frame-borrow'):phase('simulate'):phase('extract')
  frame:edge('simulate', 'extract'):borrow('world_view'):done()

  local world = FibersRegion.handle('phase-world-view', { kind = 'world_view' })
  local owner_after_borrow, read_authorised, write_authorised, undeclared_borrow
  fibers.run(function()
    frame:run('simulate', function(sim)
      fibers.perform(sim:admit_op(world))
      undeclared_borrow = fibers.perform(frame
        :borrow_op('simulate', world, 'render', { 'read' }, 'world_view')
        :map(function()
          return 'borrowed'
        end)
        :or_else(Op.always('blocked')))
      fibers.perform(frame:borrow_op('simulate', world, 'extract', { 'read' }, 'world_view'))
      owner_after_borrow = world.owner
    end)
    frame:run('extract', function(extract)
      read_authorised = fibers.perform(extract:authorise_op(world, 'read')) == world
      write_authorised = fibers.perform(extract
        :authorise_op(world, 'write')
        :map(function()
          return true
        end)
        :or_else(Op.always(false)))
    end)
  end)
  assert_eq(undeclared_borrow, 'blocked', 'phase borrowing should require a declared borrow edge')
  assert_eq(owner_after_borrow ~= nil, true, 'borrow should not move custody out of source phase')
  assert_eq(read_authorised, true, 'declared phase borrow should grant requested authority')
  assert_eq(write_authorised, false, 'declared read borrow should not grant write authority')
end

-- Declared fact crossings copy phase facts without moving custody or authority.
do
  local frame = Phase.new('frame-facts'):phase('input'):phase('simulate')
  frame:edge('input', 'simulate'):fact('commands'):done()

  local carried, blocked, seen
  fibers.run(function()
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
    frame:run('tick', function(scope)
      first = scope
    end)
    frame:run('tick', function(scope)
      second = scope
    end)
  end)
  assert_eq(first ~= second, true, 'phase run should create a fresh interval after settlement')
end

print('tests/test_phase_prototype.lua: ok')
