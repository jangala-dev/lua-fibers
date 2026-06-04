local Op = {}
local OpMethods = {}
OpMethods.__index = OpMethods

local BoundaryMethods = {}
BoundaryMethods.__index = BoundaryMethods


local function pack(...)
  return { n = select('#', ...), ... }
end

local function copy_list(list)
  local out = {}
  for i = 1, #list do out[i] = list[i] end
  return out
end

local function is_et_identity_ref(x)
  return type(x) == 'table' and (
    x.__et_resource == true or
    x.__et_owner == true or
    x.__et_waitset == true or
    x.__et_scope == true or
    x.__et_origin == true or
    x.__et_obligation == true
  )
end

local function copy_descriptor(value, seen)
  local kind = type(value)
  if kind == 'nil' or kind == 'boolean' or kind == 'number' or kind == 'string' then return value end
  if kind ~= 'table' then
    error('descriptor contains unsupported value of type ' .. kind, 3)
  end
  if is_et_identity_ref(value) then return value end
  if getmetatable(value) ~= nil then
    error('descriptor contains unmarked identity table; mark ET resources or use plain data', 3)
  end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local out = {}
  seen[value] = out
  for k, v in pairs(value) do
    out[copy_descriptor(k, seen)] = copy_descriptor(v, seen)
  end
  return out
end

local function new_op(tag, fields)
  fields = fields or {}
  fields.tag = tag
  fields.__et_op = true
  return setmetatable(fields, OpMethods)
end

local function new_boundary(tag, fields)
  fields = fields or {}
  fields.tag = tag
  fields.__et_op = true
  fields.__et_boundary = true
  return setmetatable(fields, BoundaryMethods)
end

function Op.is(x)
  return type(x) == 'table' and x.__et_op == true
end

function Op.is_boundary(x)
  return type(x) == 'table' and x.__et_boundary == true
end

function Op.assert(x, where)
  if not Op.is(x) then error((where or 'Op') .. ': expected transactional operation', 3) end
  return x
end

function Op.always(...)
  return new_op('always', { values = pack(...) })
end

function Op.never()
  return new_op('never')
end

function Op.bind(op, k)
  Op.assert(op, 'bind')
  if Op.is_boundary(op) then error('bind: cannot transactionally sequence after wrap boundary', 2) end
  if type(k) ~= 'function' then error('bind: expected continuation', 2) end
  return new_op('bind', { op = op, k = k })
end

function Op.map(op, f)
  Op.assert(op, 'map')
  if Op.is_boundary(op) then error('map: cannot transactionally map after wrap boundary', 2) end
  if type(f) ~= 'function' then error('map: expected function', 2) end
  return new_op('map', { op = op, f = f })
end

function Op.access(resource, request)
  if type(resource) ~= 'table' then error('access: expected resource', 2) end
  return new_op('access', { resource = resource, request = request })
end

function Op.open_claim(resource, request)
  if type(resource) ~= 'table' then error('open_claim: expected claim-completing resource', 2) end
  return new_op('open_claim', { resource = resource, request = request })
end

function Op.await(resource, request)
  if type(resource) ~= 'table' then error('await: expected external resource', 2) end
  return new_op('await', { resource = resource, request = request })
end

function Op.choice(left, right)
  Op.assert(left, 'choice left')
  Op.assert(right, 'choice right')
  if Op.is_boundary(left) or Op.is_boundary(right) then
    error('choice: boundary transactions cannot be used transactionally', 2)
  end
  return new_op('choice', { left = left, right = right })
end

function Op.tensor(items)
  if type(items) ~= 'table' then error('tensor: expected item list', 2) end
  return new_op('tensor', { items = copy_list(items) })
end

function Op.all(items)
  if type(items) ~= 'table' then error('all: expected item list', 2) end
  return new_op('all', { items = copy_list(items) })
end

function Op.or_else(primary, fallback)
  Op.assert(primary, 'or_else primary')
  Op.assert(fallback, 'or_else fallback')
  if Op.is_boundary(primary) or Op.is_boundary(fallback) then
    error('or_else: boundary transactions cannot be used transactionally', 2)
  end
  return new_op('or_else', { primary = primary, fallback = fallback })
end

function Op.emit(consequence)
  return new_op('emit', { consequence = copy_descriptor(consequence) })
end

function Op.guard(f)
  if type(f) ~= 'function' then error('guard: expected function', 2) end
  return new_op('guard', { f = f })
end

function Op.with_nack(f)
  if type(f) ~= 'function' then error('with_nack: expected function', 2) end
  return new_op('with_nack', { f = f })
end

function Op._nack(ref)
  return new_op('nack', { obligation = ref })
end

function Op.wrap(op, k)
  Op.assert(op, 'wrap')
  if type(k) ~= 'function' then error('wrap: expected function', 2) end
  return new_boundary('wrap', { op = op, wrappers = { k } })
end

function OpMethods:and_then(k) return Op.bind(self, k) end
function OpMethods:map(f) return Op.map(self, f) end
function OpMethods:wrap(k) return Op.wrap(self, k) end
function OpMethods:or_else(fallback) return Op.or_else(self, fallback) end
function OpMethods:choice(right) return Op.choice(self, right) end
function OpMethods:guard() return Op.guard(function() return self end) end
function OpMethods:with_nack()
  local protected = self
  return Op.with_nack(function(_) return protected end)
end

function BoundaryMethods:wrap(k)
  if type(k) ~= 'function' then error('wrap: expected function', 2) end
  local wrappers = copy_list(self.wrappers)
  wrappers[#wrappers + 1] = k
  return new_boundary('wrap', { op = self.op, wrappers = wrappers })
end

function BoundaryMethods:and_then(_)
  error('cannot transactionally sequence after wrap boundary', 2)
end

function BoundaryMethods:map(_)
  error('cannot transactionally map after wrap boundary', 2)
end

Op.OpMethods = OpMethods
Op.BoundaryMethods = BoundaryMethods

return Op
