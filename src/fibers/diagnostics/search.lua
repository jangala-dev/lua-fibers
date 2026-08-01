-- Optional boundary instrumentation for proof search and runtime activity.
--
-- The semantic kernel reports only search start and finish summaries. Detailed
-- counters are kept here so diagnostics cannot shape speculative state or add
-- bookkeeping to individual search branches.

local Instrumentation = {}
Instrumentation.__index = Instrumentation

local function copy_map(source)
  local out = {}
  for key, value in pairs(source or {}) do out[key] = value end
  return out
end

local function copy_array(source)
  local out = {}
  for i = 1, #(source or {}) do
    local value = source[i]
    out[i] = type(value) == 'table' and copy_map(value) or value
  end
  return out
end

local function default_clock()
  return os and type(os.clock) == 'function' and os.clock() or 0
end

local function histogram_bucket(value)
  if value == nil then return 'nil' end
  if value <= 0 then return '0' end
  local upper = 1
  while upper < value do upper = upper * 2 end
  if upper == 1 then return '1' end
  return tostring(math.floor(upper / 2) + 1) .. '-' .. tostring(upper)
end

local function normalise_options(options)
  return options == true and {} or type(options) == 'table' and options or {}
end

function Instrumentation.new(options)
  options = normalise_options(options)
  return setmetatable({
    clock = type(options.clock) == 'function' and options.clock or default_clock,
    counters = {},
    maxima = {},
    histograms = {},
    slow_searches = {},
    slow_search_limit = math.max(0, math.floor(options.slow_search_limit or 16)),
    search_serial = 0,
    active_searches = setmetatable({}, { __mode = 'k' }),
  }, Instrumentation)
end

function Instrumentation:inc(name, amount)
  self.counters[name] = (self.counters[name] or 0) + (amount or 1)
  return self.counters[name]
end

function Instrumentation:max(name, value)
  local old = self.maxima[name]
  if old == nil or value > old then self.maxima[name] = value end
  return value
end

function Instrumentation:observe(name, value)
  local histogram = self.histograms[name]
  if not histogram then
    histogram = {}
    self.histograms[name] = histogram
  end
  local bucket = histogram_bucket(value)
  histogram[bucket] = (histogram[bucket] or 0) + 1
  return value
end

function Instrumentation:begin_search(search, meta)
  self.search_serial = self.search_serial + 1
  self:inc('searches')
  meta = meta or {}
  local started = self.clock()
  self.active_searches[search] = {
    id = self.search_serial,
    started = started,
    active_started = started,
    active_elapsed = 0,
    focus = meta.focus,
    pending = meta.pending or 0,
    total_pending = meta.total_pending or meta.pending or 0,
    component_size = meta.component_size or meta.pending or 0,
    component_dynamic = meta.component_dynamic or 0,
    component_global = meta.component_global == true,
  }
end

function Instrumentation:resume_search(search)
  local record = self.active_searches[search]
  if record and not record.active_started then record.active_started = self.clock() end
end

function Instrumentation:pause_search(search)
  local record = self.active_searches[search]
  if record and record.active_started then
    record.active_elapsed = (record.active_elapsed or 0) + self.clock() - record.active_started
    record.active_started = nil
  end
end


local function retain_slow_search(self, search)
  if self.slow_search_limit <= 0 then return end
  local row = copy_map(search)
  row.started, row.active_started, row.active_elapsed = nil, nil, nil
  local searches = self.slow_searches
  searches[#searches + 1] = row
  table.sort(searches, function(left, right)
    if (left.search_steps or 0) ~= (right.search_steps or 0) then
      return (left.search_steps or 0) > (right.search_steps or 0)
    end
    return (left.elapsed or 0) > (right.elapsed or 0)
  end)
  while #searches > self.slow_search_limit do searches[#searches] = nil end
end

function Instrumentation:finish_search(key, outcome, summary)
  local search = self.active_searches[key]
  if not search then return end
  for name, value in pairs(summary or {}) do search[name] = value end
  self:pause_search(key)
  self.active_searches[key] = nil
  search.outcome = outcome or 'retry'
  search.elapsed = search.active_elapsed or 0

  self:inc('search_' .. search.outcome)
  self:inc('search_calls', search.search_steps or 0)
  self:inc('component_roots_total', search.component_size or 0)
  self:inc('frontier_roots_total', search.total_pending or 0)
  self:inc('component_roots_excluded', math.max(0, (search.total_pending or 0) - (search.component_size or 0)))
  if search.component_global then self:inc('component_global_searches') end

  self:max('component_size', search.component_size or 0)
  self:max('search_steps_per_search', search.search_steps or 0)
  self:max('participants_per_candidate', search.participants or 0)
  self:observe('component_size_per_search', search.component_size or 0)
  self:observe('search_steps_per_search', search.search_steps or 0)
  self:observe('participants_per_candidate', search.participants or 0)
  self:observe(
    'component_fraction_percent',
    (search.total_pending or 0) > 0 and (search.component_size or 0) * 100 / search.total_pending or 0
  )
  self:inc('search_cpu_ns', math.floor(search.elapsed * 1000000000 + 0.5))
  self:observe('search_cpu_us_per_search', search.elapsed * 1000000)
  retain_slow_search(self, search)
end

function Instrumentation:report()
  local histograms = {}
  for name, values in pairs(self.histograms) do histograms[name] = copy_map(values) end
  return {
    counters = copy_map(self.counters),
    maxima = copy_map(self.maxima),
    histograms = histograms,
    slow_searches = copy_array(self.slow_searches),
  }
end

function Instrumentation:reset()
  self.counters, self.maxima, self.histograms, self.slow_searches = {}, {}, {}, {}
  self.search_serial = 0
  self.active_searches = setmetatable({}, { __mode = 'k' })
end

return Instrumentation
