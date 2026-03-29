-- ============================================================================
-- PLUGINUPDATECORE.LUA
-- Plugin Update Checking and Installation Core
-- ============================================================================
-- This module handles checking for new plugin versions on GitHub and
-- providing installation instructions or automated downloads. It supports
-- both automatic startup checks and manual checks via menu. Includes
-- version comparison logic and error handling for network issues.
-- ============================================================================

-- Import Lightroom SDK libraries
local LrDialogs = import 'LrDialogs'
local LrHttp = import 'LrHttp'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'
local LrShell = import 'LrShell'
local LrTasks = import 'LrTasks'

-- ============================================================================
-- GITHUB REPOSITORY CONFIGURATION
-- ============================================================================

local UpdateCore = {}

-- GitHub repository details for checking updates
local REPO_OWNER = "EWProgammer"
local REPO_NAME = "Lightroom-Auto-Keyword-Plugin"
local DEFAULT_BRANCH = "main"

-- URL to fetch Info.lua file from GitHub
local RAW_INFO_URL = "https://raw.githubusercontent.com/" .. REPO_OWNER .. "/" .. REPO_NAME .. "/" .. DEFAULT_BRANCH .. "/AutoKeyword.lrplugin/Info.lua"

-- URL to download entire branch as ZIP
local BRANCH_ZIP_URL = "https://github.com/" .. REPO_OWNER .. "/" .. REPO_NAME .. "/archive/refs/heads/" .. DEFAULT_BRANCH .. ".zip"

-- GitHub Releases page for manual downloads
local RELEASES_URL = "https://github.com/" .. REPO_OWNER .. "/" .. REPO_NAME .. "/releases"

-- GitHub API endpoint for latest release
local GITHUB_API_LATEST_RELEASE = "https://api.github.com/repos/" .. REPO_OWNER .. "/" .. REPO_NAME .. "/releases/latest"

-- Get plugin preferences for tracking last check time
local prefs = LrPrefs.prefsForPlugin()

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

--- Removes leading and trailing whitespace
-- @param value String to trim
-- @return Trimmed string or nil if empty
local function trim(value)
    if value == nil then return nil end
    local s = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

--- Detects if running on Windows
-- @return Boolean: true if running on Windows
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

-- Detect OS once at module load
local IS_WINDOWS = detectWindows()

-- ============================================================================
-- SHELL QUOTING UTILITIES
-- Platform-specific command quoting
-- ============================================================================

--- Escapes a string for POSIX shell (macOS/Linux)
-- @param value String to quote
-- @return POSIX-safe quoted string
local function shellQuotePosix(value)
    local s = tostring(value or '')
    s = s:gsub("'", "'\\''")
    return "'" .. s .. "'"
end

--- Escapes a string for Windows shell
-- @param value String to quote
-- @return Windows-safe quoted string
local function shellQuoteWindows(value)
    local s = tostring(value or '')
    s = s:gsub('"', '""')
    return '"' .. s .. '"'
end

--- Quotes string appropriately for current platform
-- @param value String to quote
-- @return Platform-appropriate quoted string
local function commandQuote(value)
    if IS_WINDOWS then
        return shellQuoteWindows(value)
    end
    return shellQuotePosix(value)
end

--- Generates unique temporary file path
-- @param prefix File name prefix
-- @param ext File extension
-- @return Unique temp file path
local function uniqueTempPath(prefix, ext)
    local tempDir = LrPathUtils.getStandardFilePath('temp') or '/tmp'
    local stamp = tostring(os.time()) .. '_' .. tostring(math.random(100000, 999999))
    return LrPathUtils.child(tempDir, prefix .. '_' .. stamp .. ext)
end

--- Reads entire file as text
-- @param path File path
-- @return File content or empty string on error
local function readTextFile(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local content = f:read("*a") or ""
    f:close()
    return content
end

--- Safely deletes a file
-- @param path File to delete
local function deleteFile(path)
    if path then
        pcall(function() os.remove(path) end)
    end
end

-- ============================================================================
-- LOCAL PLUGIN VERSION MANAGEMENT
-- ============================================================================

--- Reads the plugin's Info.lua file to get current version
-- @return Version table {major, minor, revision, build} or nil on error
local function readLocalPluginInfo()
    local infoPath = LrPathUtils.child(_PLUGIN.path, "Info.lua")
    local ok, result = pcall(dofile, infoPath)
    if ok and type(result) == "table" then
        return result
    end
    return nil
end

--- Converts a version table to a semver-style string
-- @param version Table with major, minor, revision, build fields
-- @return Version string like "1.2.3.4"
local function versionTableToString(version)
    if type(version) ~= "table" then
        return "unknown"
    end
    return table.concat({
        tostring(version.major or 0),
        tostring(version.minor or 0),
        tostring(version.revision or 0),
        tostring(version.build or 0)
    }, ".")
end

-- ============================================================================
-- VERSION PARSING & COMPARISON
-- ============================================================================

--- Extracts version from Info.lua text content
-- Uses pattern matching to find VERSION table in Lua syntax
-- @param text Content of Info.lua file
-- @return Version table {major, minor, revision, build} or nil if not found
local function parseVersionFromInfoText(text)
    local major, minor, revision, build = tostring(text or ""):match("VERSION%s*=%s*{%s*major%s*=%s*(%d+)%s*,%s*minor%s*=%s*(%d+)%s*,%s*revision%s*=%s*(%d+)%s*,%s*build%s*=%s*(%d+)")
    if not major then
        return nil
    end

    return {
        major = tonumber(major) or 0,
        minor = tonumber(minor) or 0,
        revision = tonumber(revision) or 0,
        build = tonumber(build) or 0
    }
end

--- Compares two version tables
-- Uses major.minor.revision.build priority
-- @param a First version table
-- @param b Second version table
-- @return -1 if a < b, 1 if a > b, 0 if equal
local function compareVersions(a, b)
    local keys = { "major", "minor", "revision", "build" }
    for _, key in ipairs(keys) do
        local left = tonumber(a and a[key] or 0) or 0
        local right = tonumber(b and b[key] or 0) or 0
        if left < right then
            return -1
        end
        if left > right then
            return 1
        end
    end
    return 0
end

-- ============================================================================
-- HTTP FETCH UTILITIES
-- Fallback mechanisms for network requests
-- ============================================================================

--- Fetches content from URL using Lightroom HTTP library
-- @param url URL to fetch
-- @return Content string or nil on error
local function httpGet(url)
    local ok, body = pcall(function()
        return LrHttp.get(url)
    end)
    if ok then
        return trim(body)
    end
    return nil
end

--- Fetches content from URL using system shell commands
-- Falls back to curl or wget since Lightroom HTTP can be limited
-- @param url URL to fetch
-- @return Content string or nil on error
local function shellFetch(url)
    local outputFile = uniqueTempPath("lrkw_update_fetch", ".txt")
    local command = nil

    if IS_WINDOWS then
        -- Use PowerShell for Windows
        local psCommand = table.concat({
            "$ProgressPreference='SilentlyContinue'; ",
            "try { ",
            "(Invoke-WebRequest -UseBasicParsing ",
            commandQuote(url),
            " -TimeoutSec 20).Content | Set-Content -Encoding UTF8 ",
            commandQuote(outputFile),
            " } catch { exit 1 }"
        })
        command = 'powershell -NoProfile -ExecutionPolicy Bypass -Command "' .. psCommand .. '"'
    else
        -- Use curl for macOS/Linux
        command = '/bin/sh -lc "curl -fsSL ' .. shellQuotePosix(url) .. ' > ' .. shellQuotePosix(outputFile) .. '"'
    end

    local exitCode = LrTasks.execute(command)
    if exitCode ~= 0 then
        deleteFile(outputFile)
        return nil
    end

    local body = trim(readTextFile(outputFile))
    deleteFile(outputFile)
    return body
end

--- Fetches URL content with fallback mechanism
-- Tries Lightroom HTTP first, then shell curl/PowerShell
-- @param url URL to fetch
-- @return Content string or nil if both methods fail
local function fetchText(url)
    return httpGet(url) or shellFetch(url)
end

-- ============================================================================
-- VERSION CHECKING
-- Fetches and parses remote version info
-- ============================================================================

--- Extracts download URL from GitHub API JSON response
-- Looks for ZIP and zipball URLs in release data
-- @param jsonText GitHub API JSON response
-- @return Download URL or nil if not found
local function extractLatestReleaseZipUrl(jsonText)
    local body = tostring(jsonText or "")
    local browserDownload = body:match('"browser_download_url"%s*:%s*"([^"]+%.zip)"')
    if browserDownload then
        return browserDownload:gsub("\\/", "/")
    end

    local zipballUrl = body:match('"zipball_url"%s*:%s*"([^"]+)"')
    if zipballUrl then
        return zipballUrl:gsub("\\/", "/")
    end

    return nil
end

--- Opens a URL in the default web browser
-- @param url URL to open
local function openUrl(url)
    local ok = pcall(function()
        LrShell.openURLInBrowser(url)
    end)
    if not ok then
        LrDialogs.message("Open this URL manually", tostring(url), "OK")
    end
end

local function fetchUpdateInfo()
    local localInfo = readLocalPluginInfo()
    local localVersion = localInfo and localInfo.VERSION or nil
    local remoteInfoText = fetchText(RAW_INFO_URL)
    if not remoteInfoText then
        return nil, "network"
    end

    local remoteVersion = parseVersionFromInfoText(remoteInfoText)
    if not remoteVersion then
        return nil, "parse"
    end

    local latestReleaseJson = fetchText(GITHUB_API_LATEST_RELEASE)
    local downloadUrl = extractLatestReleaseZipUrl(latestReleaseJson) or BRANCH_ZIP_URL

    return {
        localVersion = localVersion,
        localVersionText = versionTableToString(localVersion),
        remoteVersion = remoteVersion,
        remoteVersionText = versionTableToString(remoteVersion),
        comparison = compareVersions(localVersion, remoteVersion),
        downloadUrl = downloadUrl,
        releasesUrl = RELEASES_URL,
    }, nil
end

function UpdateCore.runManualCheck()
    local info, err = fetchUpdateInfo()
    if not info then
        if err == "parse" then
            LrDialogs.message(
                "Update check failed",
                "The plugin reached GitHub, but could not read the remote plugin version from Info.lua.",
                "OK"
            )
        else
            LrDialogs.message(
                "Update check failed",
                "The plugin could not reach GitHub to check for updates right now. Please try again later or visit the releases page manually.",
                "OK"
            )
        end
        return
    end

    if info.comparison >= 0 then
        LrDialogs.message(
            "Plugin is up to date",
            "Installed version: " .. info.localVersionText .. "\nLatest version found on GitHub: " .. info.remoteVersionText,
            "OK"
        )
        return
    end

    local result = LrDialogs.confirm(
        "Plugin update available",
        "Installed version: " .. info.localVersionText .. "\nLatest version on GitHub: " .. info.remoteVersionText .. "\n\nThis will open the download URL for a fresh zip install. After downloading, unzip it and replace your current plugin folder in Lightroom.",
        "Open Download",
        "Cancel"
    )

    if result == "ok" then
        openUrl(info.downloadUrl)
    else
        local followup = LrDialogs.confirm(
            "Open releases page instead?",
            "If you prefer, the plugin can open the GitHub releases page so you can review release notes before downloading.",
            "Open Releases",
            "Done"
        )
        if followup == "ok" then
            openUrl(info.releasesUrl)
        end
    end
end

function UpdateCore.runStartupAutoCheck()
    local now = os.time()
    local lastCheck = tonumber(prefs.lastUpdateCheckEpoch or 0) or 0
    if lastCheck > 0 and (now - lastCheck) < 86400 then
        return
    end

    prefs.lastUpdateCheckEpoch = now

    local info = fetchUpdateInfo()
    if not info or info.comparison >= 0 then
        return
    end

    local remoteVersionText = info.remoteVersionText
    if trim(prefs.lastUpdateNotifiedVersion) == remoteVersionText then
        return
    end

    prefs.lastUpdateNotifiedVersion = remoteVersionText

    local result = LrDialogs.confirm(
        "Plugin update available",
        "A newer plugin version is available.\nInstalled version: " .. info.localVersionText .. "\nLatest version on GitHub: " .. remoteVersionText .. "\n\nOpen the download page now?",
        "Open Download",
        "Later"
    )

    if result == "ok" then
        openUrl(info.downloadUrl)
    end
end

return UpdateCore
