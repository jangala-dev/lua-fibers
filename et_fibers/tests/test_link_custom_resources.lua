return function()
  local Protocol = require('et.protocol')
  local Kernel = require('et.machine.kernel')
  local Op = require('et.op')
  local Runtime = require('et.runtime')

  local Link = Protocol.Link
  local Values = Protocol.Values
  local Result = Kernel.Status

  local function assert_eq(actual, expected, msg)
    if actual ~= expected then error((msg or 'assert_eq') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2) end
  end

  local Tri = Link.resource {
    name = 'tri-completion',
    construct = function(self)
      self.id = 'tri-completion'
      self.version = 0
    end,
    snapshot = function(self) return { resource = self, version = self.version } end,
    initial = function(_self, snap) return { base_version = snap.version } end,
    claim = function(_self, _snap, _fragment, claim, ctx)
      local req = claim.request or claim.payload or claim
      local role = req.tag or req.role
      if role ~= 'a' and role ~= 'b' and role ~= 'c' then return ctx:fatal('tri completion requires role a/b/c') end
      return ctx:open_claim({ role = role, request = req, values = req.values or Values.pack() })
    end,
    merge = function(self, _snap, request, ctx)
      if request.kind ~= 'complete' then return { base_version = request.snapshot.version } end
      local by_role = {}
      for i = 1, #(request.open_claims or {}) do by_role[request.open_claims[i].role] = request.open_claims[i] end
      if not (by_role.a and by_role.b and by_role.c) then return ctx:no_match('tri completion needs a,b,c') end
      return { ctx:match({
        resource = self,
        open_claims = { by_role.a, by_role.b, by_role.c },
        assignments = {
          [by_role.a.id] = Values.pack('A'),
          [by_role.b.id] = Values.pack('B'),
          [by_role.c.id] = Values.pack('C'),
        },
      }) }
    end,
    prepare = function(self, fragment, ctx)
      return ctx:prepared({ resource = self, fragment = fragment or { base_version = self.version }, dirty = {}, consequences = { transaction = {}, resource = {}, obligation = {} } })
    end,
  }
  function Tri:a_op() return Op.open_claim(self, { tag = 'a' }) end
  function Tri:b_op() return Op.open_claim(self, { tag = 'b' }) end
  function Tri:c_op() return Op.open_claim(self, { tag = 'c' }) end

  local function test_three_claim_completion_resource()
    local tri = Tri.new()
    local rt = Runtime.new()
    local a, b, c
    rt:spawn(function() a = rt:perform(tri:a_op()) end, 'tri-a')
    rt:spawn(function() b = rt:perform(tri:b_op()) end, 'tri-b')
    rt:spawn(function() c = rt:perform(tri:c_op()) end, 'tri-c')
    local status = rt:run()
    assert_eq(status.tag, 'found', 'three-way completion commits')
    assert_eq(a, 'A')
    assert_eq(b, 'B')
    assert_eq(c, 'C')
  end

  local Gate = Link.resource {
    name = 'gate-completion',
    construct = function(self)
      self.id = 'gate-completion'
      self.version = 0
      self.open = false
    end,
    snapshot = function(self) return { resource = self, version = self.version, open = self.open } end,
    initial = function(_self, snap) return { base_version = snap.version, open = snap.open, written = false } end,
    claim = function(self, snap, fragment, claim, ctx)
      local kind = claim.kind or 'access'
      local req = claim.request or claim.payload or claim
      if kind == 'open_claim' then
        return ctx:open_claim({ role = req.tag, request = req, values = Values.pack() })
      end
      if fragment.base_version ~= snap.version then return ctx:stale({ self }, 'gate fragment stale') end
      if req.tag == 'open' then return ctx:accept({ base_version = snap.version, open = true, written = true }, true) end
      return ctx:fatal('unknown gate request')
    end,
    merge = function(self, snap, request, ctx)
      if request.kind == 'complete' then
        local left, right
        for i = 1, #(request.open_claims or {}) do
          local c = request.open_claims[i]
          if c.role == 'left' then left = c elseif c.role == 'right' then right = c end
        end
        if not (left and right and snap.open) then return ctx:no_match('gate is not open') end
        return { ctx:match({ resource = self, open_claims = { left, right }, assignments = { [left.id] = Values.pack('L'), [right.id] = Values.pack('R') } }) }
      end
      local fragments = request.fragments or {}
      if request.kind == 'project' then
        local full = fragments[1]
        return full and full.written and full or nil
      end
      return fragments[#fragments] or request.base
    end,
    prepare = function(self, fragment, ctx)
      if fragment and fragment.base_version ~= self.version then return ctx:stale({ self }, 'gate prepare stale') end
      local open = fragment and fragment.written and fragment.open
      return ctx:prepared({
        resource = self,
        fragment = fragment,
        dirty = open and { self } or {},
        consequences = { transaction = {}, resource = {}, obligation = {} },
        apply = function()
          if open then self.open = true; self.version = self.version + 1 end
        end,
      })
    end,
  }
  function Gate:open_op() return Op.access(self, { tag = 'open' }) end
  function Gate:left_op() return Op.open_claim(self, { tag = 'left' }) end
  function Gate:right_op() return Op.open_claim(self, { tag = 'right' }) end

  local function test_completion_dependencies_refresh_when_resource_changes()
    local gate = Gate.new()
    local rt = Runtime.new()
    local l, r, opened
    rt:spawn(function() l = rt:perform(gate:left_op()) end, 'gate-left')
    rt:spawn(function() r = rt:perform(gate:right_op()) end, 'gate-right')
    rt:spawn(function() opened = rt:perform(gate:open_op()) end, 'gate-open')
    local status = rt:run()
    assert_eq(status.tag, 'found', 'gate completion eventually commits')
    assert_eq(opened, true)
    assert_eq(l, 'L')
    assert_eq(r, 'R')
    assert(rt.stats.refreshes > 0, 'claim frontiers refresh after resource changes')
  end

  local function test_bad_link_resource_reports_fatal()
    local bad = Link.mark({ id = 'bad-link', version = 0 })
    local status = Link.snapshot(nil, bad)
    assert_eq(status.tag, 'fatal', 'bad Link resource reports fatal')
  end

  test_three_claim_completion_resource()
  test_completion_dependencies_refresh_when_resource_changes()
  test_bad_link_resource_reports_fatal()
  print('protocol link custom-resource tests: ok')
end
