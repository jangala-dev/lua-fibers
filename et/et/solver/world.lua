local World = {}

local function closed(combo)
  for i = 1, #combo do
    local c = combo[i]
    if c.endpoints and #c.endpoints > 0 then return false end
    if c.deferred and #c.deferred > 0 then return false end
  end
  return true
end

function World.closed(combo, pref, order)
  if not closed(combo) then return nil end
  return {
    tag = 'world',
    combo = combo,
    pref = pref,
    order = order,
    absence_proved = true,
  }
end

function World.with_absence_proved(w)
  if not w then return nil end
  w.absence_proved = true
  return w
end

function World.is_committable(w)
  return w and w.tag == 'world' and w.absence_proved
end

return World
