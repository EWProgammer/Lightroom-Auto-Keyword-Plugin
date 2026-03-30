-- ============================================================================
-- PLUGINSHUTDOWN.LUA
-- Cleanup handler for plugin and Lightroom shutdown
-- ============================================================================

local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local function trim(value)
    if value == nil then return nil end
    local s = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

local function detectWindows()
    local windir = os.getenv and os.getenv("WINDIR")
    if trim(windir) then
        return true
    end

    local osName = os.getenv and os.getenv("OS")
    if osName == "Windows_NT" then
        return true
    end

    local pluginPath = _PLUGIN and _PLUGIN.path or ""
    if type(pluginPath) == "string" and (pluginPath:match("^%a:[/\\]") or pluginPath:find("\\", 1, true)) then
        return true
    end

    return package and package.config and package.config:sub(1, 1) == "\\" or false
end

local function shellQuotePosix(value)
    local s = tostring(value or "")
    s = s:gsub("'", "'\\''")
    return "'" .. s .. "'"
end

local function readTextFile(path)
    local handle = io.open(path, "r")
    if not handle then
        return nil
    end

    local content = handle:read("*a")
    handle:close()
    return content
end

local function cleanupMacOllama()
    local tempDir = LrPathUtils.getStandardFilePath("temp") or "/tmp"
    local pidFile = LrPathUtils.child(tempDir, "lrkw_ollama_started_by_plugin.pid")
    local payload = trim(readTextFile(pidFile))

    if not payload then
        return
    end

    local pid, expectedStart = payload:match("^(%d+)|?(.*)$")
    if not pid then
        pcall(function() os.remove(pidFile) end)
        return
    end

    expectedStart = trim(expectedStart) or ""

    local script = table.concat({
        "pid=" .. shellQuotePosix(pid),
        "expected_start=" .. shellQuotePosix(expectedStart),
        "pid_file=" .. shellQuotePosix(pidFile),
        "if kill -0 \"$pid\" >/dev/null 2>&1; then",
        "  current_command=\"$(ps -p \"$pid\" -o command= 2>/dev/null)\"",
        "  current_start=\"$(ps -p \"$pid\" -o lstart= 2>/dev/null | sed 's/^ *//')\"",
        "  case \"$current_command\" in",
        "    *\"ollama serve\"*)",
        "      if [ -z \"$expected_start\" ] || [ \"$current_start\" = \"$expected_start\" ]; then",
        "        kill \"$pid\" >/dev/null 2>&1 || true",
        "        sleep 2",
        "        kill -0 \"$pid\" >/dev/null 2>&1 && kill -9 \"$pid\" >/dev/null 2>&1 || true",
        "      fi",
        "      ;;",
        "  esac",
        "fi",
        "rm -f \"$pid_file\"",
    }, "\n")

    LrTasks.execute("/bin/sh -lc " .. shellQuotePosix(script))
end

local function cleanupWindowsOllama()
    local tempDir = os.getenv("TEMP") or os.getenv("TMP") or ""
    if not trim(tempDir) then
        return
    end

    local pidFile = tempDir .. "\\lrkw_ollama_started_by_plugin.pid"
    local payload = trim(readTextFile(pidFile))

    if not payload then
        return
    end

    local pid = payload:match("^(%d+)")
    if not pid then
        pcall(function() os.remove(pidFile) end)
        return
    end

    pcall(function()
        LrTasks.execute('tasklist /FI "PID eq ' .. pid .. '" /FO CSV /NH')
    end)

    pcall(function()
        LrTasks.execute('taskkill /PID ' .. pid .. ' /T /F')
    end)

    pcall(function() os.remove(pidFile) end)
end

pcall(function()
    if detectWindows() then
        cleanupWindowsOllama()
    else
        cleanupMacOllama()
    end
end)
