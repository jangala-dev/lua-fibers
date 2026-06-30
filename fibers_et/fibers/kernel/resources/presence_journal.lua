-- Shared merge/projection helpers for resources that journal keyed presence.
--
-- The journal shape is:
--   values-field        e.g. puts or inserts
--   removes             explicit removals
--   selected_removes    resolver-allocated removals
--   replacements        optional marker: selected/remove then put is replacement
--
-- selected_remove + same-world supply cancels as handoff.  Sequential
-- selected/remove then value is replacement.

local Premise = require('fibers.kernel.premise_helpers')

local Presence = {}

local function clone(v, fn) return fn and fn(v) or v end
local function values(rec, field) return rec[field] end
local function ensure(rec, field, with_replacements)
  rec[field] = rec[field] or {}
  rec.removes = rec.removes or {}
  rec.selected_removes = rec.selected_removes or {}
  if with_replacements then rec.replacements = rec.replacements or {} end
end

function Presence.normalise(rec, field, with_replacements)
  if Premise.map_empty(rec[field]) then rec[field] = nil end
  if with_replacements and Premise.map_empty(rec.replacements) then rec.replacements = nil end
  if Premise.map_empty(rec.removes) then rec.removes = nil end
  if Premise.map_empty(rec.selected_removes) then rec.selected_removes = nil end
end

function Presence.clone_record_maps(rec, field, clone_value, with_replacements)
  local out = {
    removes = Premise.clone_bool_map(rec and rec.removes),
    selected_removes = Premise.clone_bool_map(rec and rec.selected_removes),
  }
  out[field] = Premise.clone_map(rec and rec[field], clone_value)
  if with_replacements then out.replacements = Premise.clone_bool_map(rec and rec.replacements) end
  return out
end

function Presence.merge_seq(dst, src, opts)
  opts = opts or {}
  local field = opts.field or 'puts'
  local conflict = opts.conflict or 'presence-conflict'
  local with_replacements = opts.replacements == true
  ensure(dst, field, with_replacements)

  for k in pairs(src.removes or {}) do
    if values(dst, field)[k] ~= nil then
      values(dst, field)[k] = nil
      if with_replacements then dst.replacements[k] = nil end
      dst.selected_removes[k] = nil
      dst.removes[k] = nil
    else
      dst.selected_removes[k] = nil
      dst.removes[k] = true
    end
  end

  for k in pairs(src.selected_removes or {}) do
    if values(dst, field)[k] ~= nil then
      if with_replacements and dst.replacements[k] then
        dst.selected_removes[k] = true
      else
        values(dst, field)[k] = nil
        if with_replacements then dst.replacements[k] = nil end
      end
    elseif dst.removes[k] or dst.selected_removes[k] then
      return false, conflict
    else
      dst.selected_removes[k] = true
    end
  end

  for k, v in pairs(src[field] or {}) do
    if dst.removes[k] or dst.selected_removes[k] or (with_replacements and src.replacements and src.replacements[k]) then
      if with_replacements then
        dst.replacements[k] = true
      else
        dst.removes[k] = true
        dst.selected_removes[k] = nil
      end
    end
    values(dst, field)[k] = clone(v, opts.clone)
  end

  Presence.normalise(dst, field, with_replacements)
  return true
end

function Presence.merge_par(dst, src, opts)
  opts = opts or {}
  local field = opts.field or 'puts'
  local conflict = opts.conflict or 'presence-conflict'
  local with_replacements = opts.replacements == true
  local equal = opts.equal or function(a, b) return a == b end
  ensure(dst, field, with_replacements)

  for k in pairs(src.removes or {}) do
    if values(dst, field)[k] ~= nil or dst.selected_removes[k] then return false, conflict end
    dst.removes[k] = true
  end

  for k in pairs(src.selected_removes or {}) do
    if dst.removes[k] or dst.selected_removes[k] then return false, conflict end
    if values(dst, field)[k] ~= nil then
      if with_replacements and dst.replacements[k] then
        dst.selected_removes[k] = true
      else
        values(dst, field)[k] = nil
        if with_replacements then dst.replacements[k] = nil end
      end
    else
      dst.selected_removes[k] = true
    end
  end

  for k, v in pairs(src[field] or {}) do
    if dst.selected_removes[k] then
      if with_replacements and src.replacements and src.replacements[k] then
        values(dst, field)[k] = clone(v, opts.clone)
        dst.replacements[k] = true
      else
        dst.selected_removes[k] = nil
      end
    elseif values(dst, field)[k] ~= nil then
      if not equal(values(dst, field)[k], v) then return false, conflict end
    elseif dst.removes[k] and not (src.removes and src.removes[k]) then
      return false, conflict
    else
      values(dst, field)[k] = clone(v, opts.clone)
      if with_replacements and src.replacements and src.replacements[k] then dst.replacements[k] = true end
    end
  end

  Presence.normalise(dst, field, with_replacements)
  return true
end

function Presence.apply_to_entries(entries, rec, field, clone_value)
  for k in pairs(rec.removes or {}) do entries[k] = nil end
  for k in pairs(rec.selected_removes or {}) do entries[k] = nil end
  for k, v in pairs(rec[field] or {}) do entries[k] = clone(v, clone_value) end
end

return Presence
