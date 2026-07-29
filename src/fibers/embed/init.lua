---Portable embedding boundary for Fibers runtimes.

local Application = require('fibers.embed.application')
local Queue = require('fibers.embed.queue')

local Embed = {
  Application = Application,
  Queue = Queue,
  External = require('fibers.embed.external'),
  WaitSet = require('fibers.embed.wait_set'),
  Pure = require('fibers.embed.pure'),
  Manual = require('fibers.embed.manual'),
}

function Embed.prepare(fn, opts)
  return Application.new(fn, opts)
end

function Embed.new_host(opts)
  return Queue.new(opts)
end

return Embed
