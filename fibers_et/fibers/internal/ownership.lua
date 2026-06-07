-- Internal ownership record used by Region and owned handles such as Task.

local Ownership = {}

local Kind = { name = 'ownership' }

function Kind.clone(rec)
  return { kind = Kind, read = rec.read, owner_set = rec.owner_set, owner = rec.owner }
end

function Kind.merge_seq(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  if src.owner_set then dst.owner_set = true; dst.owner = src.owner end
  return true
end

function Kind.merge_par(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  if src.owner_set then
    if dst.owner_set and dst.owner ~= src.owner then return false, 'owner-conflict' end
    dst.owner_set = true
    dst.owner = src.owner
  end
  return true
end

function Kind.project(item, rec, query)
  if query ~= 'owner' then return nil, false end
  if rec and rec.owner_set then return rec.owner, true end
  return item.owner, true
end

function Kind.prepare(item, rec, _resolve)
  if rec.read ~= nil and (item.owner_version or 0) ~= rec.read then return nil, 'stale' end
  if rec.owner_set then return { kind = Kind, resource = item, owner = rec.owner } end
  return nil, nil, true
end

function Kind.apply(prepared, _log)
  local item = prepared.resource
  item.owner = prepared.owner
  item.owner_version = (item.owner_version or 0) + 1
end

Ownership.Kind = Kind
return Ownership
