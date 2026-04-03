-- ============================================================================
-- PLUGININIT.LUA (STABLE VERSION)
-- ============================================================================

local LrTasks = import 'LrTasks'
local UpdateCore = require 'PluginUpdateCore'

-- ============================================================================
-- HELPERS
-- ============================================================================

local function trim(value)
    if value == nil then return nil end
    local s = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

local function isWindows()
    local windir = os.getenv and os.getenv("WINDIR")
    local osName = os.getenv and os.getenv("OS")
    return windir ~= nil or osName == "Windows_NT"
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

-- ============================================================================
-- CLEANUP OLD OLLAMA (SAFE)
-- ============================================================================

local function cleanupOldOllama()
    local tempDir
    local pidFile

    if isWindows() then
        tempDir = os.getenv("TEMP") or os.getenv("TMP") or ""
        if not trim(tempDir) then return end
        pidFile = tempDir .. "\\lrkw_ollama_started_by_plugin.pid"
    else
        pidFile = "/tmp/lrkw_ollama_started_by_plugin.pid"
    end

    local content = trim(readFile(pidFile))
    if not content then return end

    local pid = content:match("^(%d+)")
    if not pid then
        pcall(function() os.remove(pidFile) end)
        return
    end

    -- Kill ONLY stale process
    if isWindows() then
        os.execute('taskkill /PID ' .. pid .. ' /T /F >nul 2>&1')
    else
        os.execute('kill ' .. pid .. ' 2>/dev/null')
    end

    -- Remove PID file
    pcall(function() os.remove(pidFile) end)
end

-- ============================================================================
-- RUN CLEANUP (SAFE + NON-BLOCKING)
-- ============================================================================

LrTasks.startAsyncTask(function()
    pcall(cleanupOldOllama)
end)

-- ============================================================================
-- UPDATE CHECK (UNCHANGED)
-- ============================================================================

LrTasks.startAsyncTask(function()
    UpdateCore.runStartupAutoCheck()
end)
