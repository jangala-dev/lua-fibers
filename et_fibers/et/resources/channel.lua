local Protocol = require('et.protocol')

local Values = Protocol.Values

local next_id = 0

local function same_open_claim(a, b)
  return a == b or (a and b and a.id ~= nil and a.id == b.id)
end

local function noop_fragment(snap)
  return { base_version = snap.version }
end

local Channel = Protocol.Link.resource {
  name = 'channel',

  construct = function(self, label)
    next_id = next_id + 1
    self.__et_channel = true
    self.id = 'channel-' .. tostring(next_id)
    self.label = label or ('channel-' .. tostring(next_id))
    self.version = 0
  end,

  snapshot = function(self)
    return {
      resource = self,
      version = self.version,
    }
  end,

  initial = function(_self, snap)
    return noop_fragment(snap)
  end,

  claim = function(_self, _snap, _fragment, claim, ctx)
    local kind = claim.kind or 'access'
    local request = claim.request or claim.payload or claim or {}

    if kind ~= 'open_claim' then
      return ctx:fatal('channel only accepts open claims')
    end

    local tag = request.tag or request.role or request[1]
    if tag ~= 'send' and tag ~= 'recv' then
      return ctx:fatal('channel open claim must be send or recv')
    end
    return ctx:open_claim({
      role = tag,
      request = request,
      values = request.values or Values.pack(),
    })
  end,

  merge = function(self, snap, request, ctx)
    if (request or {}).kind ~= 'complete' then return noop_fragment(snap) end

    local out = {}
    local open_claims = (request and request.open_claims) or {}
    for i = 1, #open_claims do
      local a = open_claims[i]
      for j = i + 1, #open_claims do
        local b = open_claims[j]
        if a.resource == self and b.resource == self and a.role ~= b.role then
          local send = a.role == 'send' and a or b
          local recv = a.role == 'recv' and a or b
          if not same_open_claim(send, recv) then
            out[#out + 1] = ctx:match({
              resource = self,
              open_claims = { send, recv },
              assignments = {
                [send.id] = Values.pack(true),
                [recv.id] = send.values or Values.pack(),
              },
              event = {
                tag = 'claim.complete',
                resource = self,
                role = 'channel',
                open_claim_ids = { send.id, recv.id },
              },
            })
          end
        end
      end
    end
    if #out == 0 then return ctx:no_match('channel open claims do not complete') end
    return out
  end,

  prepare = function(self, fragment, ctx)
    if fragment.base_version ~= self.version then
      return ctx:stale({ self }, 'channel fragment base version does not match current version')
    end
    return ctx:prepared({
      resource = self,
      fragment = noop_fragment({ version = self.version }),
      dirty = {},
      consequences = { transaction = {}, resource = {}, obligation = {} },
    })
  end,

  commit = function()
  end,
}

function Channel.is(x)
  return type(x) == 'table' and x.__et_channel == true and x.__et_resource == true
end

function Channel.assert(x, where)
  if not Channel.is(x) then error((where or 'channel') .. ': expected Channel', 3) end
  return x
end

function Channel:put_op(Op, ...)
  return Op.open_claim(self, { tag = 'send', values = Values.pack(...) })
end

function Channel:get_op(Op)
  return Op.open_claim(self, { tag = 'recv' })
end

return Channel
