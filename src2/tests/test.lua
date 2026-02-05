local interpreters = {
    'lua',
    'luajit'
}

local tests = {
    'sched2',
    'pulse2',
    'runtime2',
    'op2',
    'channel2'
}

for _, interpreter in ipairs(interpreters) do
    print('**** starting '..interpreter..' tests ****')
    for _, name in ipairs(tests) do
        local code = os.execute(interpreter.." test_"..name..".lua")
        if code ~= 0 then error(interpreter.." test for: "..name.." failed") end
    end
end
