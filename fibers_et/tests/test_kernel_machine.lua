package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')
local Runtime = require('fibers.kernel.runtime')
local IR = require('fibers.kernel.ir')
local Store = require('fibers.kernel.store')
local Op = require('fibers.atoms.op')
local Scalar = require('fibers.atoms.scalar')

local function eq(a,b,m) if a~=b then error((m or 'assert')..': expected '..tostring(b)..', got '..tostring(a),2) end end
local Kind={name='lazy-witness-test'}
local loc=Store.new_location{name='lazy-witness',merge='machine',domain='plain',value=0}
local opened,next_calls=0,0
local p=IR.witness_transition{
  location=loc,
  cursor=function(state)
    opened=opened+1
    local i=0
    return {next=function()
      i=i+1; next_calls=next_calls+1
      if i==1 then return {value=1,result=Op._pack('first'),writes=true} end
      if i==2 then return {value=2,result=Op._pack('second'),writes=true} end
      return nil
    end}
  end,
}
local resource={_fibers_kind=Kind}
local rt=Runtime.new(); local got
rt:spawn_raw(function() got=rt:perform(Op._resource(resource,Kind,p)) end)
eq(rt:run().tag,'found'); eq(got,'first')
-- One readiness probe and one execution cursor are permitted; neither may
-- enumerate the unused second candidate.
if next_calls > 2 then error('witness cursor was eagerly exhausted: '..next_calls,2) end

-- The trail machine and reference machine must agree on a backtracking world.
local function scenario(machine)
  local r=Runtime.new{machine=machine}; local s=Scalar.new(0); local out
  r:spawn_raw(function()
    out=r:perform(Op.tensor({
      Op.choice(s:write_op(1),s:write_op(2)),
      s:write_op(2),
    }))
  end)
  local st=r:run(); return st.tag,s.value,out and out[1] and out[1][1]
end
local a,b,c=scenario('trail'); local x,y,z=scenario('reference')
eq(a,x); eq(b,y); eq(c,z)
print('tests/test_kernel_machine.lua: ok')
