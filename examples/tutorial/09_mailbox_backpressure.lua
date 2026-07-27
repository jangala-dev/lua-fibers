package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Mailbox adds bounded buffering, close semantics and explicit full policies.
-- A busy desktop event feed can reject a cosmetic cursor blink without
-- disturbing the save request already waiting.

local fibers = require('fibers')
local Mailbox = require('fibers.mailbox')

local save_ok, blink_ok, blink_reason
local first_event, final_event, closed, close_reason, dropped

fibers.run(function()
  local event_tx, event_rx = Mailbox.reject_newest(1, 'document-events')

  save_ok = event_tx:send('save requested')
  blink_ok, blink_reason = event_tx:send('cursor blink')
  first_event = event_rx:recv()

  assert(event_tx:send('autosave complete'))
  event_tx:close('document closed')

  final_event = event_rx:recv()
  closed, close_reason = event_rx:recv()
  dropped = fibers.perform(event_rx:dropped_op())
end)

assert(save_ok == true)
assert(blink_ok == false and blink_reason == 'full')
assert(first_event == 'save requested' and final_event == 'autosave complete')
assert(closed == nil and close_reason == 'document closed')
assert(dropped == 1)
print('desktop events:', first_event, 'then', final_event, 'rejected cosmetics:', dropped)
