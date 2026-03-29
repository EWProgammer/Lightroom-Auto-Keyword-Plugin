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
local LrView = import 'LrView'
local LrFunctionContext = import 'LrFunctionContext'

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
local CONTENTS_INFO_URL = "https://api.github.com/repos/" .. REPO_OWNER .. "/" .. REPO_NAME .. "/contents/AutoKeyword.lrplugin/Info.lua?ref=" .. DEFAULT_BRANCH

-- URL to download entire branch as ZIP
local BRANCH_ZIP_URL = "https://github.com/" .. REPO_OWNER .. "/" .. REPO_NAME .. "/archive/refs/heads/" .. DEFAULT_BRANCH .. ".zip"

-- GitHub Releases page for manual downloads
local RELEASES_URL = "https://github.com/" .. REPO_OWNER .. "/" .. REPO_NAME .. "/releases"

-- GitHub API endpoint for latest release
local GITHUB_API_LATEST_RELEASE = "https://api.github.com/repos/" .. REPO_OWNER .. "/" .. REPO_NAME .. "/releases/latest"
local GITHUB_API_RECENT_COMMITS = "https://api.github.com/repos/" .. REPO_OWNER .. "/" .. REPO_NAME .. "/commits?sha=" .. DEFAULT_BRANCH .. "&per_page=6"

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

local function decodeBase64(data)
    local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    data = tostring(data or ''):gsub('%s+', ''):gsub('[^' .. alphabet .. '=]', '')

    return (data:gsub('.', function(char)
        if char == '=' then
            return ''
        end

        local index = alphabet:find(char, 1, true)
        if not index then
            return ''
        end

        local value = index - 1
        local bits = ''
        for i = 6, 1, -1 do
            bits = bits .. ((value % 2 ^ i - value % 2 ^ (i - 1) > 0) and '1' or '0')
        end
        return bits
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(byte)
        if #byte ~= 8 then
            return ''
        end

        local value = 0
        for i = 1, 8 do
            if byte:sub(i, i) == '1' then
                value = value + 2 ^ (8 - i)
            end
        end
        return string.char(value)
    end))
end

local function extractContentFromGitHubContentsJson(jsonText)
    local body = tostring(jsonText or "")
    local encoded = body:match('"content"%s*:%s*"([^"]+)"')
    if not encoded then
        return nil
    end

    encoded = encoded:gsub("\\n", "")
    local decoded = decodeBase64(encoded)
    return trim(decoded)
end

local function fetchRemoteInfoText()
    local cacheBust = tostring(os.time())
    local rawUrl = RAW_INFO_URL .. "?t=" .. cacheBust
    local rawText = fetchText(rawUrl)
    local rawVersion = parseVersionFromInfoText(rawText)

    local contentsText = extractContentFromGitHubContentsJson(fetchText(CONTENTS_INFO_URL))
    local contentsVersion = parseVersionFromInfoText(contentsText)

    if rawVersion and contentsVersion then
        if compareVersions(rawVersion, contentsVersion) >= 0 then
            return rawText
        end
        return contentsText
    end

    return rawText or contentsText
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

local function decodeJsonString(value)
    local text = tostring(value or "")
    text = text:gsub('\\"', '"')
    text = text:gsub("\\/", "/")
    text = text:gsub("\\r\\n", "\n")
    text = text:gsub("\\n", "\n")
    text = text:gsub("\\r", "\n")
    text = text:gsub("\\t", "\t")
    text = text:gsub("\\u(%x%x%x%x)", function(hex)
        local code = tonumber(hex, 16)
        if not code then
            return ""
        end
        if code < 128 then
            return string.char(code)
        end
        return "?"
    end)
    return text
end

local function extractLatestReleaseNotes(jsonText)
    local body = tostring(jsonText or "")
    local releaseName = body:match('"name"%s*:%s*"([^"]*)"')
    local releaseBody = body:match('"body"%s*:%s*"((?:\\"|[^"])*)"')

    releaseName = trim(decodeJsonString(releaseName))
    releaseBody = trim(decodeJsonString(releaseBody))

    if not releaseBody then
        return nil
    end

    if releaseName then
        return releaseName .. "\n\n" .. releaseBody
    end

    return releaseBody
end

local function extractCommitNotes(jsonText)
    local body = tostring(jsonText or "")
    local notes = {}

    for message in body:gmatch('"message"%s*:%s*"((?:\\"|[^"])*)"') do
        local decoded = trim(decodeJsonString(message))
        if decoded then
            local firstLine = trim(decoded:match("([^\n\r]+)"))
            if firstLine and not firstLine:match("^Merge ") then
                notes[#notes + 1] = "- " .. firstLine
            end
        end
        if #notes >= 5 then
            break
        end
    end

    if #notes == 0 then
        return nil
    end

    return "Recent changes on " .. DEFAULT_BRANCH .. ":\n\n" .. table.concat(notes, "\n")
end

local function showUpdateDetailsDialog(info)
    LrFunctionContext.callWithContext("pluginUpdateDetailsDialog", function(context)
        local f = LrView.osFactory()
        local contents = f:column {
            spacing = 10,
            f:static_text {
                title = "Installed version: " .. tostring(info.localVersionText) .. "\nLatest version: " .. tostring(info.remoteVersionText),
                width_in_chars = 84
            },
            f:static_text {
                title = "What's new:",
                width_in_chars = 20
            },
            f:scrolled_view {
                width = 640,
                height = 280,
                horizontal_scroller = false,
                vertical_scroller = true,
                f:static_text {
                    title = tostring(info.releaseNotes or "No release notes were available for this update."),
                    width_in_chars = 86
                }
            },
            f:static_text {
                title = "Installing will open the download page for a fresh zip install. After downloading, unzip it and replace your current plugin folder in Lightroom.",
                width_in_chars = 86
            }
        }

        local result = LrDialogs.presentModalDialog {
            title = "Plugin Update Available",
            contents = contents,
            actionVerb = "Open Download",
            cancelVerb = "Later"
        }

        if result == "ok" then
            openUrl(info.downloadUrl)
        end
    end)
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
    local remoteInfoText = fetchRemoteInfoText()
    if not remoteInfoText then
        return nil, "network"
    end

    local remoteVersion = parseVersionFromInfoText(remoteInfoText)
    if not remoteVersion then
        return nil, "parse"
    end

    local latestReleaseJson = fetchText(GITHUB_API_LATEST_RELEASE)
    local downloadUrl = extractLatestReleaseZipUrl(latestReleaseJson) or BRANCH_ZIP_URL
    local releaseNotes = extractLatestReleaseNotes(latestReleaseJson)

    if not releaseNotes then
        releaseNotes = extractCommitNotes(fetchText(GITHUB_API_RECENT_COMMITS))
    end

    return {
        localVersion = localVersion,
        localVersionText = versionTableToString(localVersion),
        remoteVersion = remoteVersion,
        remoteVersionText = versionTableToString(remoteVersion),
        comparison = compareVersions(localVersion, remoteVersion),
        downloadUrl = downloadUrl,
        releasesUrl = RELEASES_URL,
        releaseNotes = releaseNotes,
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

    showUpdateDetailsDialog(info)
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

