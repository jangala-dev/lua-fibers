-- Compare two CSV outputs produced by performance/suite.lua.
-- Exits non-zero when throughput or proof-search distributions regress beyond
-- the configured thresholds.

local baseline_path, candidate_path = arg[1], arg[2]
local time_threshold = tonumber(arg[3] or os.getenv('FIBERS_PERF_REGRESSION_PERCENT') or '10') or 10
local search_threshold = tonumber(
  arg[4] or os.getenv('FIBERS_PERF_SEARCH_REGRESSION_PERCENT') or '25'
) or 25
if not baseline_path or not candidate_path then
  io.stderr:write(
    'usage: lua performance/compare.lua BASELINE.csv CANDIDATE.csv '
      .. '[TIME_PERCENT] [SEARCH_PERCENT]\n'
  )
  os.exit(2)
end

local function parse_line(line)
  local out, field, quoted = {}, '', false
  local i = 1
  while i <= #line do
    local ch = line:sub(i, i)
    if quoted then
      if ch == '"' and line:sub(i + 1, i + 1) == '"' then
        field = field .. '"'
        i = i + 1
      elseif ch == '"' then
        quoted = false
      else
        field = field .. ch
      end
    elseif ch == '"' then
      quoted = true
    elseif ch == ',' then
      out[#out + 1] = field
      field = ''
    else
      field = field .. ch
    end
    i = i + 1
  end
  out[#out + 1] = field
  return out
end

local function load(path)
  local file = assert(io.open(path, 'rb'))
  local header = parse_line(assert(file:read('*l')))
  local index = {}
  for i = 1, #header do
    index[header[i]] = i
  end
  local function number(values, name)
    local i = index[name]
    return i and tonumber(values[i]) or nil
  end
  local rows = {}
  for line in file:lines() do
    local values = parse_line(line)
    local key = table.concat({ values[index.tier], values[index.group], values[index.name] }, '/')
    rows[key] = {
      us = number(values, 'median_us_per_op'),
      p99_steps = number(values, 'p99_search_steps_upper'),
      max_steps = number(values, 'max_search_steps'),
    }
  end
  file:close()
  return rows
end

local function percent(old, new)
  if old == nil or new == nil then
    return nil
  end
  if old == 0 then
    return new == 0 and 0 or math.huge
  end
  return (new / old - 1) * 100
end

local baseline, candidate = load(baseline_path), load(candidate_path)
local failed = false
print(
  string.format(
    '%-55s %11s %11s %9s %9s %9s %9s',
    'case',
    'base us/op',
    'new us/op',
    'time',
    'base p99<=',
    'new p99<=',
    'search'
  )
)
print(string.rep('-', 123))
local keys = {}
for key in pairs(candidate) do
  keys[#keys + 1] = key
end
table.sort(keys)
for _, key in ipairs(keys) do
  local old, new = baseline[key], candidate[key]
  if old and old.us and new.us then
    local time_change = percent(old.us, new.us) or 0
    local search_change = percent(old.p99_steps, new.p99_steps)
    local time_bad = time_change > time_threshold
    local search_bad = search_change ~= nil and search_change > search_threshold
    if time_bad or search_bad then
      failed = true
    end
    local marker = (time_bad and 'TIME ' or '') .. (search_bad and 'SEARCH' or '')
    print(
      string.format(
        '%-55s %11.3f %11.3f %+8.1f%% %9s %9s %8s %s',
        key,
        old.us,
        new.us,
        time_change,
        tostring(old.p99_steps or ''),
        tostring(new.p99_steps or ''),
        search_change and string.format('%+.1f%%', search_change) or '',
        marker
      )
    )
  else
    print(string.format('%-55s %s', key, old and 'candidate missing timing' or 'new case'))
  end
end
if failed then
  os.exit(1)
end
