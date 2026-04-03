-- ============================================================================
-- PURGEJPEGPREVIEWS.LUA
-- Removes leftover temporary JPEG previews created for Local AI runs
-- ============================================================================

local LrDialogs = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local PREVIEW_PREFIX = "lrkw_ai_thumb_"
local PREVIEW_EXTENSION = ".jpg"

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

    return package and package.config and package.config:sub(1, 1) == "\\" or false
end

local IS_WINDOWS = detectWindows()

local function commandQuote(value)
    local text = tostring(value or "")
    if IS_WINDOWS then
        text = text:gsub('"', '""')
        return '"' .. text .. '"'
    end

    text = text:gsub("'", "'\\''")
    return "'" .. text .. "'"
end

local function listPreviewFiles(tempDir)
    local command

    if IS_WINDOWS then
        command = 'cmd /c dir /b /a-d ' .. commandQuote(tempDir .. "\\" .. PREVIEW_PREFIX .. "*" .. PREVIEW_EXTENSION) .. ' 2>nul'
    else
        command = 'find ' .. commandQuote(tempDir) .. ' -maxdepth 1 -type f -name ' .. commandQuote(PREVIEW_PREFIX .. "*" .. PREVIEW_EXTENSION) .. ' 2>/dev/null'
    end

    local pipe = io.popen(command, "r")
    if not pipe then
        return nil, "Failed to inspect the system temp folder."
    end

    local files = {}
    for line in pipe:lines() do
        local entry = trim(line)
        if entry then
            if IS_WINDOWS then
                files[#files + 1] = tempDir .. "\\" .. entry
            else
                files[#files + 1] = entry
            end
        end
    end

    pipe:close()
    return files, nil
end

local function purgePreviewFiles(files)
    local deleted = 0
    local failed = 0

    for _, path in ipairs(files or {}) do
        local ok, removed = pcall(os.remove, path)
        if ok and removed then
            deleted = deleted + 1
        else
            failed = failed + 1
        end
    end

    return deleted, failed
end

LrTasks.startAsyncTask(function()
    local tempDir = trim(LrPathUtils.getStandardFilePath('temp')) or trim(os.getenv("TEMP")) or trim(os.getenv("TMP")) or "/tmp"
    if not tempDir then
        LrDialogs.message("Purge JPEG Previews", "Could not determine the system temp folder.", "OK")
        return
    end

    local previewFiles, listError = listPreviewFiles(tempDir)
    if not previewFiles then
        LrDialogs.message("Purge JPEG Previews", listError or "Unable to inspect the temp folder.", "OK")
        return
    end

    if #previewFiles == 0 then
        LrDialogs.message("Purge JPEG Previews", "No leftover AI preview JPEGs were found in:\n" .. tempDir, "OK")
        return
    end

    local confirm = LrDialogs.confirm(
        "Purge JPEG Previews",
        "Delete " .. tostring(#previewFiles) .. " leftover AI preview JPEG(s) from:\n" .. tempDir,
        "Purge",
        "Cancel"
    )

    if confirm ~= "ok" then
        return
    end

    local deleted, failed = purgePreviewFiles(previewFiles)
    local message = "Deleted " .. tostring(deleted) .. " preview JPEG(s)."

    if failed > 0 then
        message = message .. "\nCould not delete " .. tostring(failed) .. " file(s). They may still be in use."
    end

    LrDialogs.message("Purge JPEG Previews", message, "OK")
end)
