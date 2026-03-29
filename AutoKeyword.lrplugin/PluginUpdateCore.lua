local LrDialogs = import 'LrDialogs'
local LrHttp = import 'LrHttp'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'
local LrShell = import 'LrShell'
local LrTasks = import 'LrTasks'

local UpdateCore = {}

local REPO_OWNER = "EWProgammer"
local REPO_NAME = "Lightroom-Auto-Keyword-Plugin"
local DEFAULT_BRANCH = "main"
local RAW_INFO_URL = "https://raw.githubusercontent.com/" .. REPO_OWNER .. "/" .. REPO_NAME .. "/" .. DEFAULT_BRANCH .. "/AutoKeyword.lrplugin/Info.lua"
local BRANCH_ZIP_URL = "https://github.com/" .. REPO_OWNER .. "/" .. REPO_NAME .. "/archive/refs/heads/" .. DEFAULT_BRANCH .. ".zip"
local RELEASES_URL = "https://github.com/" .. REPO_OWNER .. "/" .. REPO_NAME .. "/releases"
local GITHUB_API_LATEST_RELEASE = "https://api.github.com/repos/" .. REPO_OWNER .. "/" .. REPO_NAME .. "/releases/latest"

local prefs = LrPrefs.prefsForPlugin()

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

local IS_WINDOWS = detectWindows()

local function shellQuotePosix(value)
    local s = tostring(value or '')
    s = s:gsub("'", "'\\''")
    return "'" .. s .. "'"
end

local function shellQuoteWindows(value)
    local s = tostring(value or '')
    s = s:gsub('"', '""')
    return '"' .. s .. '"'
end

local function commandQuote(value)
    if IS_WINDOWS then
        return shellQuoteWindows(value)
    end
    return shellQuotePosix(value)
end

local function uniqueTempPath(prefix, ext)
    local tempDir = LrPathUtils.getStandardFilePath('temp') or '/tmp'
    local stamp = tostring(os.time()) .. '_' .. tostring(math.random(100000, 999999))
    return LrPathUtils.child(tempDir, prefix .. '_' .. stamp .. ext)
end

local function readTextFile(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local content = f:read("*a") or ""
    f:close()
    return content
end

local function deleteFile(path)
    if path then
        pcall(function() os.remove(path) end)
    end
end

local function readLocalPluginInfo()
    local infoPath = LrPathUtils.child(_PLUGIN.path, "Info.lua")
    local ok, result = pcall(dofile, infoPath)
    if ok and type(result) == "table" then
        return result
    end
    return nil
end

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

local function httpGet(url)
    local ok, body = pcall(function()
        return LrHttp.get(url)
    end)
    if ok then
        return trim(body)
    end
    return nil
end

local function shellFetch(url)
    local outputFile = uniqueTempPath("lrkw_update_fetch", ".txt")
    local command = nil

    if IS_WINDOWS then
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

local function fetchText(url)
    return httpGet(url) or shellFetch(url)
end

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
