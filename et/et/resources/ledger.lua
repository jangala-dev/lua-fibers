local DefaultOp = require('et.op')
local Resource = require('et.resources.protocol')
local Candidate = require('et.algebra.candidate')
local Result = require('et.algebra.result')
local OpPack = DefaultOp._pack

local Ledger = {}
Ledger.__index = Ledger

local LedgerKind = { name = 'ledger' }
local next_id = 0

local function copy_set(src)
  if not src then return nil end
  local out = {}
  for k, v in pairs(src) do out[k] = v end
  return out
end

local function merge_read(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
end

local function read_record(c, ledger)
  local rec = Resource.ensure(c, ledger, LedgerKind)
  rec.read = rec.read or (ledger.version or 0)
  return rec
end

local function transfer_record(c, ledger, to_owner)
  local rec = read_record(c, ledger)
  rec.has_owner = true
  rec.owner = to_owner
  return rec
end

local function close_record(c, ledger, owner)
  local rec = read_record(c, ledger)
  rec.closed = rec.closed or {}
  rec.closed[owner] = true
  rec.closes = rec.closes or {}
  rec.closes[owner] = true
  return rec
end

local function is_closed_in_context(ctx, ledger, owner)
  local overlay = ctx and ctx.overlay
  local rec = overlay and overlay.res and overlay.res[ledger]
  if rec and rec.closed and rec.closed[owner] then return true end
  return ledger.closed and ledger.closed[owner] or false
end

function LedgerKind.clone(rec)
  return {
    kind = LedgerKind,
    read = rec.read,
    has_owner = rec.has_owner,
    owner = rec.owner,
    closed = copy_set(rec.closed),
    closes = copy_set(rec.closes),
  }
end

function LedgerKind.merge_seq(dst, src)
  merge_read(dst, src)
  if src.has_owner then
    dst.has_owner = true
    dst.owner = src.owner
  end
  if src.closed then
    dst.closed = dst.closed or {}
    for owner, val in pairs(src.closed) do dst.closed[owner] = val end
  end
  if src.closes then
    dst.closes = dst.closes or {}
    for owner, val in pairs(src.closes) do dst.closes[owner] = val end
  end
  return true
end

function LedgerKind.merge_par(dst, src)
  merge_read(dst, src)
  if src.has_owner then
    if dst.has_owner and dst.owner ~= src.owner then return false, 'ledger-conflict' end
    dst.has_owner = true
    dst.owner = src.owner
  end
  if src.closed then
    dst.closed = dst.closed or {}
    for owner, val in pairs(src.closed) do dst.closed[owner] = val end
  end
  if src.closes then
    dst.closes = dst.closes or {}
    for owner, val in pairs(src.closes) do dst.closes[owner] = val end
  end
  return true
end

function LedgerKind.project(ledger, rec, query)
  if query == 'owner' then
    if rec and rec.has_owner then return rec.owner, true end
    return ledger.owner, true
  end
  return nil, false
end

function LedgerKind.prepare(ledger, rec, _resolve)
  if rec.read ~= nil and (ledger.version or 0) ~= rec.read then return nil, 'stale' end

  local final_owner = rec.has_owner and rec.owner or ledger.owner

  if rec.closes then
    for owner, val in pairs(rec.closes) do
      if val and owner ~= final_owner then return nil, 'ledger-close-transfer-conflict' end
    end
  end

  if rec.has_owner and ledger.settled_owner ~= nil then return nil, 'ledger-already-settled' end

  local emit_settlement = rec.closes and rec.closes[final_owner] and ledger.settled_owner == nil or false

  if rec.has_owner or rec.closed or emit_settlement then
    return {
      kind = LedgerKind,
      resource = ledger,
      has_owner = rec.has_owner,
      owner = rec.owner,
      closed = copy_set(rec.closed),
      emit_settlement = emit_settlement,
      settlement_owner = final_owner,
    }
  end

  return nil, nil, true
end

function LedgerKind.apply(prepared, log)
  local ledger = prepared.resource

  if prepared.has_owner and ledger.owner ~= prepared.owner then
    ledger.owner = prepared.owner
    ledger.version = (ledger.version or 0) + 1
  end

  if prepared.closed then
    for owner, val in pairs(prepared.closed) do
      if val then ledger.closed[owner] = true end
    end
    ledger.version = (ledger.version or 0) + 1
  end

  if prepared.emit_settlement then
    ledger.settled_owner = prepared.settlement_owner
    log.obligation[#log.obligation + 1] = { kind = 'settlement', owner = prepared.settlement_owner, ledger = ledger }
  end
end

function LedgerKind.eval(ledger, payload, ctx)
  local op = payload.op
  if op == 'owner' then
    local c = Candidate.new(OpPack(Resource.project(ctx, ledger, 'owner')))
    read_record(c, ledger)
    return Result.cands({ c })
  elseif op == 'transfer' then
    if ledger.settled_owner ~= nil then return Result.none() end
    if Resource.project(ctx, ledger, 'owner') ~= payload.from_owner then return Result.none() end
    if is_closed_in_context(ctx, ledger, payload.from_owner) then return Result.none() end
    local c = Candidate.new(OpPack(true))
    transfer_record(c, ledger, payload.to_owner)
    return Result.cands({ c })
  elseif op == 'close' then
    if Resource.project(ctx, ledger, 'owner') ~= payload.owner then return Result.none() end
    local c = Candidate.new(OpPack(true))
    close_record(c, ledger, payload.owner)
    return Result.cands({ c })
  end
  error('unknown ledger operation ' .. tostring(op), 2)
end

function LedgerKind.summary(_payload, out)
  out.resources = true
  out.closed = false
end

function Ledger.new(name, owner)
  next_id = next_id + 1
  return setmetatable({
    name = name or ('ledger-' .. tostring(next_id)),
    owner = owner,
    version = 0,
    closed = {},
    settled_owner = nil,
    _et_id = next_id,
    _et_kind = LedgerKind,
  }, Ledger)
end

function Ledger:owner_op(Op)
  Op = Op or DefaultOp
  return Op._resource(self, LedgerKind, { op = 'owner' })
end

function Ledger:transfer_op(from_owner, to_owner, Op)
  Op = Op or DefaultOp
  return Op._resource(self, LedgerKind, { op = 'transfer', from_owner = from_owner, to_owner = to_owner })
end

function Ledger:close_op(owner, Op)
  Op = Op or DefaultOp
  return Op._resource(self, LedgerKind, { op = 'close', owner = owner })
end

Ledger.Kind = LedgerKind

return Ledger
