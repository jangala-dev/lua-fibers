-- coxpcall.lua

local M = {}

-------------------------------------------------------------------------------
-- Checks if (x)pcall function is coroutine safe
-------------------------------------------------------------------------------
local function isCoroutineSafe(func)
    local co = coroutine.create(function()
        return func(coroutine.yield, function() end)
    end)

    coroutine.resume(co)
    return coroutine.resume(co)
end

-- Fast path: environment already has coroutine-safe pcall/xpcall
if isCoroutineSafe(pcall) and isCoroutineSafe(xpcall) then
    -- No globals; just return plain ones
    M.pcall   = pcall
    M.xpcall  = xpcall
    M.running = coroutine.running
    return M
end

-------------------------------------------------------------------------------
-- Implements xpcall with coroutines
-------------------------------------------------------------------------------

local performResume, handleReturnValue
local oldpcall, oldxpcall = pcall, xpcall
local unpack = rawget(table, "unpack") or _G.unpack
local pack   = rawget(table, "pack") or function(...)
    return { n = select("#", ...), ... }
end
local running = coroutine.running
local coromap = setmetatable({}, { __mode = "k" })

local function id(trace)
    return trace
end

function handleReturnValue(err, co, status, ...)
    if not status then
        -- Error path from coroutine.resume(co, ...)
        if err == id then
            -- pcall semantics: propagate the original error object unchanged
            -- coroutine.resume returns (false, errmsg, ...), so just
            -- pass those “...” through as pcall would.
            return false, ...
        else
            -- xpcall semantics: run the error handler on a traceback
            return false, err(debug.traceback(co, (...)), ...)
        end
    end

    if coroutine.status(co) == 'suspended' then
        return performResume(err, co, coroutine.yield(...))
    else
        return true, ...
    end
end

function performResume(err, co, ...)
    return handleReturnValue(err, co, coroutine.resume(co, ...))
end

local function coxpcall(f, err, ...)
    local current = running()
    if not current then
        -- Not in a coroutine: fall back to normal pcall/xpcall
        if err == id then
            return oldpcall(f, ...)
        else
            if select("#", ...) > 0 then
                local oldf, params = f, pack(...)
                f = function() return oldf(unpack(params, 1, params.n)) end
            end
            return oldxpcall(f, err)
        end
    else
        local res, co = oldpcall(coroutine.create, f)
        if not res then
            local newf = function(...) return f(...) end
            co = coroutine.create(newf)
        end
        coromap[co] = current
        return performResume(err, co, ...)
    end
end

local function corunning(coro)
    if coro ~= nil then
        assert(type(coro) == "thread",
               "Bad argument; expected thread, got: " .. type(coro))
    else
        coro = running()
    end
    while coromap[coro] do
        coro = coromap[coro]
    end
    if coro == "mainthread" then return nil end
    return coro
end

-------------------------------------------------------------------------------
-- Implements pcall with coroutines
-------------------------------------------------------------------------------

local function copcall(f, ...)
    return coxpcall(f, id, ...)
end

M.pcall   = copcall
M.xpcall  = coxpcall
M.running = corunning

return M
