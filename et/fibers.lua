-- Convenience entry point for the fibers runtime.
-- Direct modules such as fibers.op and fibers.runtime remain public.

local M = {}

M.Op = require('fibers.op')
M.Runtime = require('fibers.runtime')

M.Channel = require('fibers.resources.channel')
M.Cell = require('fibers.resources.cell')
M.Ledger = require('fibers.resources.ledger')
M.Event = require('fibers.resources.event')

M.ConsequenceKind = require('fibers.consequence.kind')
M.ConsequenceSet = require('fibers.consequence.set')

return M
