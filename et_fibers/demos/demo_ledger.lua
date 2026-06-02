package.path = './?.lua;../?.lua;./?/init.lua;../?/init.lua;' .. package.path

local core = require('etfcore')
local Op = core.Op
local Runtime = core.Runtime
local Ledger = require('ledger')

-- --------------------------------------------------------------------------
-- Demo 2: Ledger transfer + close as one transaction.
-- --------------------------------------------------------------------------

local function demo_ledger()
  print('--- demo: ledger transfer + close commit event ---')
  local rt = Runtime.new()
  local ledger = Ledger.new({ ticket = 'extent:A' })

  rt:spawn(function()
    local ok = Op.perform(
      ledger:move_op('ticket', 'extent:A', 'extent:B'):and_then(function()
        return ledger:close_op('extent:A', 'moved-out'):and_then(function()
          return Op.emit({ tag = 'user.note', message = 'ledger tx body complete' }):and_then(function()
            return Op.always('transaction-result')
          end)
        end)
      end)
    )
    print('ledger transaction returned:', ok)
  end, 'ledger-tx')

  rt:run()

  print('ledger owner(ticket):', ledger.owners.ticket)
  print('ledger closed(extent:A):', ledger.closed['extent:A'])
  print()
end

demo_ledger()
