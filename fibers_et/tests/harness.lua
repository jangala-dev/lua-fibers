-- Small test harness for fibers.
--
-- Goals:
--   * keep tests executable directly with lua/luajit/texlua
--   * provide a uniform aggregate runner
--   * support filtering and verbose/list modes without a framework dependency

local Harness = {}

local unpack_ = table.unpack or unpack

local function now()
  return os.clock and os.clock() or 0
end

local function printf(fmt, ...)
  io.stdout:write(string.format(fmt, ...))
  io.stdout:write('\n')
end

local function normalise_name(test)
  if type(test) == 'table' then
    return test.name or test.path
  end
  return tostring(test)
end

local function normalise_path(test)
  if type(test) == 'table' then
    return test.path or test[1]
  end
  return tostring(test)
end

local function matches_filter(name, filter)
  if not filter or filter == '' then
    return true
  end
  if string.find(name, filter, 1, true) then
    return true
  end
  local ok, found = pcall(string.find, name, filter)
  return ok and found ~= nil
end

function Harness.parse_args(argv, env_prefix)
  argv = argv or arg or {}
  env_prefix = env_prefix or 'FIBERS_TEST'
  local opts = {
    verbose = os.getenv(env_prefix .. '_VERBOSE') == '1',
    list = false,
    filter = os.getenv(env_prefix .. '_FILTER'),
    fail_fast = os.getenv(env_prefix .. '_FAIL_FAST') == '1',
  }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == '-v' or a == '--verbose' then
      opts.verbose = true
    elseif a == '-q' or a == '--quiet' then
      opts.verbose = false
    elseif a == '--list' then
      opts.list = true
    elseif a == '--fail-fast' then
      opts.fail_fast = true
    elseif a == '--filter' or a == '-k' then
      i = i + 1
      opts.filter = argv[i]
    elseif string.sub(a, 1, 9) == '--filter=' then
      opts.filter = string.sub(a, 10)
    elseif string.sub(a, 1, 3) == '-k=' then
      opts.filter = string.sub(a, 4)
    elseif a == '--help' or a == '-h' then
      opts.help = true
    elseif string.sub(a, 1, 1) == '-' then
      opts.unknown = opts.unknown or {}
      opts.unknown[#opts.unknown + 1] = a
    else
      -- Positional argument is a convenience filter.
      opts.filter = opts.filter or a
    end
    i = i + 1
  end
  return opts
end

function Harness.print_help(command)
  printf(
    'usage: %s [--list] [-v|--verbose] [-k PATTERN|--filter PATTERN] [--fail-fast]',
    command or 'lua tests/run_all.lua'
  )
  printf('')
  printf('Filters match literal substrings first, then Lua patterns if literal matching fails.')
  printf('Environment: FIBERS_TEST_VERBOSE=1 FIBERS_TEST_FILTER=PATTERN FIBERS_TEST_FAIL_FAST=1')
end

local function classify_result(ok, result_or_err)
  if not ok then
    return 'fail', result_or_err
  end
  if type(result_or_err) == 'table' then
    local status = result_or_err.status or result_or_err.tag
    if status == 'skip' or status == 'skipped' then
      return 'skip', result_or_err.reason or result_or_err.message or 'skipped'
    elseif status == 'ok' or status == 'pass' or status == true then
      return 'ok', result_or_err.message
    elseif status == 'fail' or status == 'failed' then
      return 'fail', result_or_err.reason or result_or_err.message or 'failed'
    end
  elseif result_or_err == 'skip' or result_or_err == 'skipped' then
    return 'skip', 'skipped'
  end
  return 'ok', result_or_err
end

function Harness.run(tests, opts)
  opts = opts or {}
  local label = opts.label or 'tests'
  local selected = {}

  if opts.help then
    Harness.print_help(opts.command)
    return { status = 'ok', listed = true, total = 0, ok = 0, skipped = 0, failed = 0 }
  end

  for i = 1, #tests do
    local test = tests[i]
    local name = normalise_name(test)
    if matches_filter(name, opts.filter) then
      selected[#selected + 1] = test
    end
  end

  if opts.list then
    for i = 1, #selected do
      printf('%s', normalise_name(selected[i]))
    end
    return { status = 'ok', listed = true, total = #selected, ok = 0, skipped = 0, failed = 0 }
  end

  local counts = { total = #selected, ok = 0, skipped = 0, failed = 0 }
  local results = {}
  local start_all = now()

  printf(
    '%s: running %d test%s%s',
    label,
    #selected,
    #selected == 1 and '' or 's',
    opts.filter and (' matching ' .. tostring(opts.filter)) or ''
  )

  for i = 1, #selected do
    local test = selected[i]
    local name = normalise_name(test)
    local path = normalise_path(test)
    if opts.verbose then
      printf('test %d/%d %s', i, #selected, name)
    end

    local previous = rawget(_G, '_FIBERS_TEST_HARNESS')
    local previous_print = _G.print
    local previous_io_write = io.write
    _G._FIBERS_TEST_HARNESS = true
    if not opts.verbose then
      _G.print = function(...) end
      io.write = function(...) end
    end
    local t0 = now()
    local ok, result_or_err = pcall(dofile, path)
    local elapsed = now() - t0
    _G._FIBERS_TEST_HARNESS = previous
    _G.print = previous_print
    io.write = previous_io_write

    local status, detail = classify_result(ok, result_or_err)
    if status == 'ok' then
      counts.ok = counts.ok + 1
    elseif status == 'skip' then
      counts.skipped = counts.skipped + 1
    else
      counts.failed = counts.failed + 1
    end

    results[#results + 1] =
      { name = name, path = path, status = status, detail = detail, elapsed = elapsed }

    if status == 'ok' then
      printf('ok   %-42s %.3fs', name, elapsed)
    elseif status == 'skip' then
      printf('skip %-42s %s', name, tostring(detail or 'skipped'))
    else
      printf('FAIL %-42s %s', name, tostring(detail))
      if opts.fail_fast then
        break
      end
    end
  end

  local elapsed_all = now() - start_all
  printf(
    '%s: summary: %d ok, %d skipped, %d failed, %d total in %.3fs',
    label,
    counts.ok,
    counts.skipped,
    counts.failed,
    counts.total,
    elapsed_all
  )

  if counts.failed > 0 then
    for i = 1, #results do
      local r = results[i]
      if r.status == 'fail' then
        io.stderr:write(string.format('\n%s failed:\n%s\n', r.name, tostring(r.detail)))
      end
    end
    error(label .. ': failed', 0)
  end

  counts.status = 'ok'
  counts.results = results
  return counts
end

return Harness
