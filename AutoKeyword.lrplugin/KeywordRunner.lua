-- ============================================================================
-- KEYWORDRUNNER.LUA
-- Main Keyword Generation Engine for Lightroom Photos
-- ============================================================================
--
-- OVERVIEW:
-- This is the core module that handles all keywording functionality. It
-- manages the complete workflow from user interaction through keyword
-- suggestion, filtering, mapping, and final assignment to selected photos.
--
-- MAIN FEATURES:
-- 1. Multi-mode keyword generation:
--    - Full Keywording: AI + metadata + style mapping + quick tags
--    - Metadata Only: Extract date, season, camera, lens info
--    - AI Assist: Use local Ollama vision model for content-based suggestions
--
-- 2. Style Preset System:
--    - Define custom keyword hierarchies (e.g., "Wedding" style)
--    - Apply styles to automatically add specific keywords
--
-- 3. AI Processing:
--    - Integrates with Ollama running locally
--    - Auto-installs Ollama and models if needed
--    - Renders temporary JPEG previews for AI analysis
--    - Cleans up temp files after processing
--
-- 4. Keyword Management:
--    - Creates/updates Lightroom keyword hierarchies
--    - Deduplicates keywords intelligently
--    - Prevents re-adding existing keywords
--
-- 5. Progress Tracking:
--    - Real-time feedback for batch processing
--    - Handles cancellation gracefully
--
-- ARCHITECTURE:
-- - Keyword caching to minimize Lightroom API calls
-- - Safe keyword creation with proper parent-child relationships
-- - Settings file communication with external AI processes
-- - Temp file cleanup and error handling
-- ============================================================================

-- Import Lightroom SDK libraries
local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'
local LrProgressScope = import 'LrProgressScope'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'

-- ============================================================================
-- KEYWORD CACHING SYSTEM
-- Improves performance by reducing Lightroom API calls
-- ============================================================================

-- Cache for keyword objects by lowercase name
local keywordCache = {}

-- Cache for full keyword paths to avoid recreation
local keywordPathCache = {}

-- Wrapper function for safe Lightroom keyword method calls
local safeKeywordCall

-- Trim helper function
local function trim(value)
    if value == nil then return nil end
    local s = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

-- ============================================================================
-- KEYWORD CREATION AND PATH BUILDING
-- Safely creates keyword hierarchies in Lightroom
-- ============================================================================

--- Creates or retrieves a keyword from the catalog
-- Uses caching to prevent duplicate creation and improve performance
-- @param catalog The Lightroom catalog
-- @param name The keyword name to create or retrieve
-- @param parent The parent keyword object (for hierarchies)
-- @param key Optional cache key (defaults to name)
-- @return The keyword object, or nil on failure
local function getOrCreateKeyword(catalog, name, parent, key)
    name = trim(name)
    if not catalog or not name then return nil end
    key = key or name

    -- Check cache first
    if keywordPathCache[key] then
        return keywordPathCache[key]
    end

    -- Create new keyword in Lightroom
    local kw = catalog:createKeyword(name, {}, false, parent, true)
    if kw then
        keywordPathCache[key] = kw
        keywordCache[string.lower(name)] = keywordCache[string.lower(name)] or kw
    end
    return kw
end

--- Builds and returns a complete keyword hierarchy path
-- Splits pipe-separated path and creates nested keywords as needed
-- @param catalog The Lightroom catalog
-- @param path Pipe-separated hierarchy path (e.g., "Parent|Child|Grandchild")
-- @return The deepest keyword object in the hierarchy, or nil on failure
local function getOrCreatePath(catalog, path)
    path = trim(path)
    if not path then return nil end

    local parent = nil
    local currentPath = ""

    -- Create each level of the hierarchy
    for part in string.gmatch(path, "[^|]+") do
        part = trim(part)
        if part then
            currentPath = (currentPath == "" and part) or (currentPath .. "|" .. part)
            parent = getOrCreateKeyword(catalog, part, parent, currentPath)
            if not parent then
                return nil
            end
        end
    end

    return parent
end

-- ============================================================================
-- HELPER UTILITIES
-- Text processing and sanitization functions
-- ============================================================================

--- Alias for trim function
local function clean(val)
    return trim(val)
end

--- Sanitizes a single keyword segment (part of a path)
-- Removes leading/trailing whitespace and converts pipe chars
-- @param value The keyword segment
-- @return Sanitized segment or nil if empty
local function sanitizeSegment(value)
    local s = clean(value)
    if not s then return nil end
    s = s:gsub("|", "/")
    return clean(s)
end

--- Normalizes keyword hierarchy paths to standard format
-- Handles multiple input formats and converts to pipe-separated
-- @param value The path in any supported format
-- @return Normalized path using pipe (|) separators, or nil if invalid
local function sanitizeHierarchyPath(value)
    local s = clean(value)
    if not s then return nil end

    -- Handle Windows-style backslash paths (e.g., from file system navigation)
    if s:find("\\", 1, true) and not s:find("^%a:[/\\]") and not s:find("|", 1, true) and not s:find(">", 1, true) and not s:find("<", 1, true) and not s:find("›", 1, true) then
        local parts = {}
        for part in s:gmatch("[^\\]+") do
            local p = clean(part)
            if p then
                parts[#parts + 1] = p
            end
        end
        if #parts > 1 then
            return table.concat(parts, "|")
        end
    end

    -- Handle reversed hierarchy format: "child < parent < grandparent"
    -- Lightroom supports hierarchy entry with |, >, and <.
    -- For "dog < animal", reverse into "animal|dog".
    if s:find("<", 1, true) and not s:find("|", 1, true) and not s:find(">", 1, true) and not s:find("›", 1, true) then
        local reverseParts = {}
        for part in s:gmatch("[^<]+") do
            local p = clean(part)
            if p then
                p = p:gsub("|", "/")
                reverseParts[#reverseParts + 1] = p
            end
        end
        if #reverseParts == 0 then return nil end
        local ordered = {}
        for i = #reverseParts, 1, -1 do
            ordered[#ordered + 1] = reverseParts[i]
        end
        return table.concat(ordered, "|")
    end

    -- Convert all arrow-style separators to pipe
    s = s:gsub("%s*[>›<]%s*", "|")
    local parts = {}
    for part in s:gmatch("[^|]+") do
        local p = clean(part)
        if p then
            p = p:gsub("|", "/")
            parts[#parts + 1] = p
        end
    end

    if #parts == 0 then return nil end
    return table.concat(parts, "|")
end

-- ============================================================================
-- LOCAL AI CONFIGURATION & DEFAULTS
-- Ollama-based vision model integration for keyword suggestion
-- ============================================================================

--- Detects if running on Windows OS
-- Checks environment variables and package configuration
-- @return Boolean: true if running on Windows, false otherwise
local function detectWindows()
    local windir = os.getenv and os.getenv("WINDIR")
    if clean(windir) then
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

-- Detect the operating system once at module load time
local IS_WINDOWS = detectWindows()

-- Time to wait between AI API calls to prevent overload
local AI_COOLDOWN_SECONDS = 0.2

-- Default maximum AI suggestions per image
local AI_DEFAULT_MAX_PHOTOS_PER_RUN = 10
local AI_DEFAULT_SUGGESTIONS_PER_IMAGE = 10

-- More conservative defaults for Mac systems (less RAM, lower performance)
local AI_MAC_SAFE_MAX_PHOTOS_PER_RUN = 3
local AI_MAC_SAFE_SUGGESTIONS_PER_IMAGE = 6

-- Access plugin preferences
local prefs = LrPrefs.prefsForPlugin()

-- Default style presets
local STYLE_PRESETS_DEFAULT = "Wedding=Event Type|Wedding;Portrait=Event Type|Portrait;Fine Art=Style|Fine Art"

-- ===== LOCAL AI BRIDGE =====
-- Set to true after configuring LOCAL_AI_COMMAND.
local LOCAL_AI_ENABLED = true

-- Local-only command template. It must write plain text keywords to %OUTPUT_FILE%.
-- Tokens:
--   %IMAGE_PATH%   absolute path to photo file
--   %HISTORY_FILE% text file containing prior keyword profile
--   %OUTPUT_FILE%  output file your local AI should write (comma/newline separated)
-- Important: Do not wrap placeholders in quotes; quoting is handled internally.
-- Example:
--   /usr/local/bin/keyword-ai --image %IMAGE_PATH% --history %HISTORY_FILE% --out %OUTPUT_FILE%
local LOCAL_AI_COMMAND = ''

--- Gets the configured number of AI suggestions per image
-- Reads from preferences and clamps to valid range (1-30)
-- @return Number of suggestions configured
local function getConfiguredSuggestionsPerImage()
    local n = tonumber(prefs.aiDefaultSuggestionsPerImage)
    if not n then
        n = AI_DEFAULT_SUGGESTIONS_PER_IMAGE
    end
    return math.max(1, math.min(30, math.floor(n)))
end

--- Gets the configured maximum number of photos per AI run
-- Reads from preferences and clamps to valid range (1-200)
-- @return Maximum photos per run
local function getConfiguredMaxPhotosPerRun()
    local n = tonumber(prefs.aiMaxPhotosPerRun)
    if not n then
        n = AI_DEFAULT_MAX_PHOTOS_PER_RUN
    end
    return math.max(1, math.min(200, math.floor(n)))
end

--- Initializes platform-specific AI defaults on first run
-- Sets lower memory settings for Mac systems
-- Only runs once per plugin instance
local function seedPlatformAiDefaults()
    if prefs.aiPlatformDefaultsInitialized then
        return
    end

    if not IS_WINDOWS then
        -- Mac-specific safe defaults (lower RAM requirements)
        prefs.aiLowMemoryMode = true
        prefs.aiPreferCpu = true
        prefs.aiDefaultSuggestionsPerImage = AI_MAC_SAFE_SUGGESTIONS_PER_IMAGE
        prefs.aiMaxPhotosPerRun = AI_MAC_SAFE_MAX_PHOTOS_PER_RUN
    else
        -- Windows defaults (more capable systems)
        prefs.aiDefaultSuggestionsPerImage = AI_DEFAULT_SUGGESTIONS_PER_IMAGE
        prefs.aiMaxPhotosPerRun = AI_DEFAULT_MAX_PHOTOS_PER_RUN
    end

    prefs.aiPlatformDefaultsInitialized = true
end

-- Initialize defaults on module load
seedPlatformAiDefaults()

-- ============================================================================
-- SHELL COMMAND & FILE I/O UTILITIES
-- Handles cross-platform command execution and temporary file management
-- ============================================================================

--- Escapes a string for POSIX shell execution (macOS/Linux)
-- Wraps string in single quotes and escapes internal single quotes
-- @param value String to escape
-- @return POSIX-safe quoted string
local function shellQuotePosix(value)
    local s = tostring(value or '')
    s = s:gsub("'", "'\\''")
    return "'" .. s .. "'"
end

--- Escapes a string for Windows cmd.exe / PowerShell execution
-- Wraps string in double quotes and escapes internal double quotes
-- @param value String to escape
-- @return Windows-safe quoted string
local function shellQuoteWindows(value)
    local s = tostring(value or '')
    s = s:gsub('"', '""')
    return '"' .. s .. '"'
end

--- Quotes a string appropriately for the current platform
-- @param value String to quote
-- @return Platform-appropriate quoted string
local function commandQuote(value)
    if IS_WINDOWS then
        return shellQuoteWindows(value)
    end
    return shellQuotePosix(value)
end

--- Generates a unique temporary file path to avoid collisions
-- Uses timestamp and random number for uniqueness
-- @param prefix Name prefix for the temp file
-- @param ext File extension
-- @return Unique full path to temporary file
local function uniqueTempPath(prefix, ext)
    local tempDir = LrPathUtils.getStandardFilePath('temp') or '/tmp'
    local stamp = tostring(os.time()) .. '_' .. tostring(math.random(100000, 999999))
    return LrPathUtils.child(tempDir, prefix .. '_' .. stamp .. ext)
end

--- Writes text content to a file
-- @param path File path to write to
-- @param text Content to write
-- @return Boolean: true on success, false on failure
local function writeTextFile(path, text)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(tostring(text or ""))
    f:close()
    return true
end

--- Writes binary data to a file
-- @param path File path to write to
-- @param data Binary data to write
-- @return Boolean: true on success, false on failure
local function writeBinaryFile(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

--- Reads entire file content as text
-- @param path File path to read
-- @return File content as string, or empty string if file doesn't exist
local function readTextFile(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local content = f:read("*a") or ""
    f:close()
    return content
end

--- Safely deletes a file, ignoring errors
-- Uses pcall to prevent errors from propagating
-- @param path File path to delete
local function deleteFile(path)
    pcall(function() os.remove(path) end)
end

--- Appends text to end of a file
-- @param path File path to append to
-- @param text Content to append
-- @return Boolean: true on success, false on failure
local function appendTextFile(path, text)
    local f = io.open(path, "a")
    if not f then return false end
    f:write(tostring(text or ""))
    f:close()
    return true
end

--- Writes settings as key=value pairs to a file
-- Each key-value pair on its own line, sorted alphabetically
-- @param path File path to write to
-- @param values Table of key-value pairs
-- @return Boolean: true on success, false on failure
local function writeSettingsFile(path, values)
    local lines = {}
    for key, value in pairs(values or {}) do
        local k = clean(key)
        local v = clean(value)
        if k and v then
            lines[#lines + 1] = k .. "=" .. v
        end
    end
    table.sort(lines)
    return writeTextFile(path, table.concat(lines, "\n"))
end

--- Parses AI command output into individual keywords
-- Handles comma, newline, and semicolon delimiters
-- Automatically deduplicates (case-insensitive)
-- @param text Raw output from AI command
-- @return Array of unique keyword strings
local function parseAiKeywordOutput(text)
    local words = {}
    local seen = {}
    for token in tostring(text or ''):gmatch('[^,\n\r;]+') do
        local w = clean(token)
        if w then
            local key = string.lower(w)
            if not seen[key] then
                seen[key] = true
                words[#words + 1] = w
            end
        end
    end
    return words
end

--- Generates helpful error message if AI returns no keywords
-- Provides platform-specific guidance
-- @return Error message string
local function buildLocalAiNoOutputMessage()
    if IS_WINDOWS then
        return "Local AI returned no keywords. Verify Ollama is installed, the Ollama app is running, and a vision model is available (for example llava:latest)."
    end
    return "Local AI returned no keywords. Verify Ollama is installed, running, and a vision model is available (for example llava:latest)."
end

-- ============================================================================
-- LOCAL AI COMMAND RESOLUTION & PHOTO ANALYSIS
-- ============================================================================

--- Determines which AI command template(s) to use
-- Returns configured custom command if available, otherwise uses built-in
-- bridge scripts (OllamaKeywordBridge) for Windows or macOS/Linux
-- @return Array of command template strings, or nil if no commands available
local function resolveLocalAiCommands()
    local configured = clean(LOCAL_AI_COMMAND)
    if configured then
        return { configured }
    end

    if _PLUGIN and _PLUGIN.path then
        if IS_WINDOWS then
            local bridgePath = LrPathUtils.child(_PLUGIN.path, "OllamaKeywordBridge.cmd")
            return {
                '"' .. bridgePath .. '" %IMAGE_PATH% %HISTORY_FILE% %OUTPUT_FILE% %MAX_SUGGESTIONS% %SETTINGS_FILE%',
            }
        else
            local bridgePath = LrPathUtils.child(_PLUGIN.path, "OllamaKeywordBridge.sh")
            return { "/bin/zsh " .. shellQuotePosix(bridgePath) .. " %IMAGE_PATH% %HISTORY_FILE% %OUTPUT_FILE% %MAX_SUGGESTIONS% %SETTINGS_FILE%" }
        end
    end

    return nil
end

--- Extracts and organizes keywords already attached to a photo
-- Builds lookup maps for quick deduplication checks
-- @param photo Lightroom photo object
-- @return State table with paths, leaves, and labels arrays
local function getPhotoAttachedKeywordState(photo)
    local state = {
        paths = {},     -- Full hierarchy paths (lowercase keys)
        leaves = {},    -- Leaf keyword names (lowercase keys)
        labels = {}     -- Array of actual keyword names
    }

    if not photo then
        return state
    end

    local rawKeywords = nil
    pcall(function()
        rawKeywords = photo:getRawMetadata("keywords")
    end)

    -- Process existing keywords
    for _, keyword in ipairs(rawKeywords or {}) do
        local name = clean(safeKeywordCall(keyword, "getName"))
        local fullPath = sanitizeHierarchyPath(safeKeywordCall(keyword, "getNameViaHierarchy")) or name
        if fullPath then
            state.paths[string.lower(fullPath)] = true
        end
        if name then
            local key = string.lower(name)
            if not state.leaves[key] then
                state.leaves[key] = true
                state.labels[#state.labels + 1] = name
            end
        end
    end

    -- Fallback to formatted metadata if keyword objects aren't accessible
    if #state.labels == 0 then
        local tagText = clean(photo:getFormattedMetadata("keywordTags"))
        if tagText then
            for token in tagText:gmatch("[^,\n\r;]+") do
                local label = sanitizeSegment(token)
                if label then
                    local key = string.lower(label)
                    if not state.leaves[key] then
                        state.leaves[key] = true
                        state.labels[#state.labels + 1] = label
                    end
                end
            end
        end
    end

    return state
end

--- Checks if a keyword is already attached to a photo
-- Uses the attached keyword state to avoid duplicate keywords
-- @param path Keyword hierarchy path to check
-- @param attachedKeywordState The state table from getPhotoAttachedKeywordState
-- @return Boolean: true if keyword already exists on photo
local function isKeywordAlreadyAttached(path, attachedKeywordState)
    if not attachedKeywordState or not path then
        return false
    end

    local normalized = sanitizeHierarchyPath(path) or clean(path)
    if not normalized then
        return false
    end

    -- Check full path match
    if attachedKeywordState.paths[string.lower(normalized)] then
        return true
    end

    -- Check leaf keyword match
    local leaf = normalized:match("([^|]+)$")
    if leaf and attachedKeywordState.leaves[string.lower(leaf)] then
        return true
    end

    return false
end

--- Builds runtime settings for AI processing
-- Encodes preferences like model choice, CPU preference, and existing keywords
-- @param aiSettings Table with lowMemoryMode and preferCpu flags
-- @param attachedKeywordState State of keywords already on the photo
-- @return Table of settings to write to settings file
local function buildAiRuntimeSettings(aiSettings, attachedKeywordState)
    local values = {}

    -- Use smaller model in low memory mode
    if aiSettings and aiSettings.lowMemoryMode then
        values.MODEL = "gemma3:4b"
    end

    -- Force CPU execution instead of GPU if preferred
    if aiSettings and aiSettings.preferCpu then
        values.CPU_ONLY = "true"
    end

    -- Pass existing keywords to AI for context (limit to 40 for performance)
    if attachedKeywordState and attachedKeywordState.labels and #attachedKeywordState.labels > 0 then
        local labels = {}
        for i = 1, math.min(#attachedKeywordState.labels, 40) do
            labels[#labels + 1] = attachedKeywordState.labels[i]
        end
        values.EXISTING_KEYWORDS = table.concat(labels, ", ")
    end

    return values
end

--- Renders a Lightroom photo thumbnail as JPEG for AI analysis
-- Lightroom creates temporary JPEG previews on demand
-- This waits for completion with timeout protection
-- @param photo Lightroom photo object
-- @return Path to temp JPEG file, or nil with error message on failure
local function renderAiThumbnail(photo)
    if not photo then
        return nil, "Missing photo"
    end

    local request = nil
    local jpegData = nil
    local thumbError = nil
    local completed = false

    -- Request JPEG thumbnail from Lightroom (1024x1024 max)
    request = photo:requestJpegThumbnail(1024, 1024, function(data, err)
        jpegData = data
        thumbError = err
        completed = true
    end)

    -- Wait for completion (up to 20 seconds = 400 * 0.05)
    local attempts = 0
    while not completed and attempts < 400 do
        LrTasks.sleep(0.05)
        attempts = attempts + 1
    end

    request = nil

    if not completed then
        return nil, "Timed out waiting for Lightroom preview"
    end

    if not jpegData then
        return nil, thumbError or "Failed to render Lightroom preview"
    end

    -- Write JPEG to temp file
    local thumbnailPath = uniqueTempPath('lrkw_ai_thumb', '.jpg')
    if not writeBinaryFile(thumbnailPath, jpegData) then
        return nil, "Failed to create temp JPEG preview for AI"
    end

    return thumbnailPath, nil
end

local LocalAiSuggester = {}

function LocalAiSuggester.isConfigured()
    return LOCAL_AI_ENABLED and resolveLocalAiCommands() ~= nil
end

function LocalAiSuggester.suggest(photoOrPath, historyText, aiSettings)
    if not LocalAiSuggester.isConfigured() then
        return {}, 'Local AI disabled (set LOCAL_AI_ENABLED and LOCAL_AI_COMMAND in KeywordRunner.lua)'
    end

    local imagePath = nil
    local imageCleanupPath = nil
    local imageError = nil
    local attachedKeywordState = nil

    if type(photoOrPath) == "string" then
        imagePath = clean(photoOrPath)
    else
        attachedKeywordState = getPhotoAttachedKeywordState(photoOrPath)
        imagePath, imageError = renderAiThumbnail(photoOrPath)
        imageCleanupPath = imagePath
    end

    if not imagePath then
        return {}, imageError or 'Missing image path'
    end

    local historyFile = uniqueTempPath('lrkw_history', '.txt')
    local outputFile = uniqueTempPath('lrkw_ai_output', '.txt')
    local settingsFile = uniqueTempPath('lrkw_ai_settings', '.txt')
    local debugFile = uniqueTempPath('lrkw_ai_debug', '.log')
    appendTextFile(debugFile, "IS_WINDOWS: " .. tostring(IS_WINDOWS) .. "\n")
    appendTextFile(debugFile, "PLUGIN_PATH: " .. tostring(_PLUGIN and _PLUGIN.path or "") .. "\n\n")
    if not writeTextFile(historyFile, tostring(historyText or '')) then
        return {}, "Failed to create temp history file for AI"
    end
    if not writeSettingsFile(settingsFile, buildAiRuntimeSettings(aiSettings, attachedKeywordState)) then
        deleteFile(imageCleanupPath)
        deleteFile(historyFile)
        deleteFile(outputFile)
        return {}, "Failed to create AI settings file"
    end

    local commandTemplates = resolveLocalAiCommands() or {}
    local desiredCount = tonumber(aiSettings and aiSettings.suggestionsPerImage or getConfiguredSuggestionsPerImage()) or getConfiguredSuggestionsPerImage()
    desiredCount = math.max(1, math.min(30, math.floor(desiredCount)))
    local exitCode = nil
    for _, template in ipairs(commandTemplates) do
        local cmd = template
        cmd = cmd:gsub('%%IMAGE_PATH%%', commandQuote(imagePath))
        cmd = cmd:gsub('%%HISTORY_FILE%%', commandQuote(historyFile))
        cmd = cmd:gsub('%%OUTPUT_FILE%%', commandQuote(outputFile))
        cmd = cmd:gsub('%%MAX_SUGGESTIONS%%', tostring(desiredCount))
        cmd = cmd:gsub('%%SETTINGS_FILE%%', commandQuote(settingsFile))
        local candidates = { cmd }
        if IS_WINDOWS then
            candidates = { '"' .. cmd .. '"', cmd }
        end

        for _, candidate in ipairs(candidates) do
            appendTextFile(debugFile, "COMMAND: " .. tostring(candidate) .. "\n")
            exitCode = LrTasks.execute(candidate)
            appendTextFile(debugFile, "EXIT: " .. tostring(exitCode) .. "\n\n")
            if exitCode == 0 then
                break
            end
        end

        if exitCode == 0 then
            break
        end
    end

    if exitCode ~= 0 then
        deleteFile(imageCleanupPath)
        deleteFile(historyFile)
        deleteFile(outputFile)
        deleteFile(settingsFile)
        return {}, 'Local AI command failed with exit code ' .. tostring(exitCode) .. '. Debug log: ' .. tostring(debugFile)
    end

    local outputText = readTextFile(outputFile)

    deleteFile(imageCleanupPath)
    deleteFile(historyFile)
    deleteFile(outputFile)
    deleteFile(settingsFile)

    if clean(outputText) == nil then
        deleteFile(debugFile)
        return {}, buildLocalAiNoOutputMessage()
    end

    local parsed = parseAiKeywordOutput(outputText)

    if #parsed > desiredCount then
        local limited = {}
        for i = 1, desiredCount do
            limited[#limited + 1] = parsed[i]
        end
        parsed = limited
    end

    deleteFile(debugFile)
    return parsed, nil
end

local function getSeason(month)
    if not month then return nil end
    if month == 12 or month <= 2 then return "Winter"
    elseif month <= 5 then return "Spring"
    elseif month <= 8 then return "Summer"
    else return "Fall" end
end

local function getDateInfo(photo)
    if not photo then return nil end
    local raw = photo:getRawMetadata("dateTimeOriginal")
    if not raw then return nil end

    local rawNumber = tonumber(raw)
    if not rawNumber then return nil end

    local timestamp = math.floor(rawNumber + 978307200)
    if not timestamp then return nil end

    return {
        year = os.date("%Y", timestamp),
        monthName = os.date("%B", timestamp),
        monthNumber = tonumber(os.date("%m", timestamp))
    }
end

-- ===== QUICK TAG INPUT =====
local function promptQuickTags()
    local resultValue = nil

    LrFunctionContext.callWithContext("quickTagsDialog", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)

        local contents = f:column {
            bind_to_object = props,

            f:static_text { title = "Enter keywords:" },

            f:edit_field {
                value = LrView.bind("input"),
                width_in_chars = 40
            }
        }

        local result = LrDialogs.presentModalDialog {
            title = "Quick Tags",
            contents = contents
        }

        if result == "ok" then
            resultValue = props.input
        end
    end)

    return resultValue
end

-- ===== CONTEXT =====
local function chooseMode()
    local selectedMode = nil

    LrFunctionContext.callWithContext("chooseModeDialog", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)
        props.mode = "full"

        local contents = f:column {
            bind_to_object = props,
            spacing = 8,

            f:static_text { title = "Choose processing mode:" },

            f:radio_button {
                title = "Full Keywording (metadata + mapping + context + quick tags)",
                value = LrView.bind("mode"),
                checked_value = "full"
            },
            f:radio_button {
                title = "Metadata Only (Date/Season/Camera/Lens)",
                value = LrView.bind("mode"),
                checked_value = "camera_only"
            },
            f:radio_button {
                title = "AI Assist (Local-only, with keyword learning)",
                value = LrView.bind("mode"),
                checked_value = "ai_local"
            }
        }

        local result = LrDialogs.presentModalDialog {
            title = "Keyword Mode",
            contents = contents,
            actionVerb = "Continue",
            cancelVerb = "Cancel"
        }

        if result == "ok" then
            selectedMode = props.mode
        end
    end)

    return selectedMode
end

local function promptAiSettings()
    local settings = nil

    LrFunctionContext.callWithContext("aiSettingsDialog", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)

        props.suggestionsPerImage = tostring(getConfiguredSuggestionsPerImage())
        props.lowMemoryMode = prefs.aiLowMemoryMode and true or false
        props.preferCpu = prefs.aiPreferCpu and true or false

        local contents = f:column {
            bind_to_object = props,
            spacing = 8,
            f:static_text { title = "AI Settings" },
            f:static_text { title = "Desired AI suggestions per image:" },
            f:edit_field {
                value = LrView.bind("suggestionsPerImage"),
                width_in_chars = 6
            },
            f:checkbox {
                title = "Low memory mode: prefer a smaller vision model for lower RAM use",
                value = LrView.bind("lowMemoryMode")
            },
            f:checkbox {
                title = "Prefer CPU when the plugin starts Ollama itself (slower, but lighter on GPU/unified memory)",
                value = LrView.bind("preferCpu")
            },
            f:static_text { title = "Tip: start with 6-8 suggestions on low-memory systems, especially older Macs." }
        }

        local result = LrDialogs.presentModalDialog {
            title = "AI Assist Settings",
            contents = contents,
            actionVerb = "Continue",
            cancelVerb = "Cancel"
        }

        if result == "ok" then
            local n = tonumber(props.suggestionsPerImage)
            if not n then
                n = getConfiguredSuggestionsPerImage()
            end
            n = math.max(1, math.min(30, math.floor(n)))
            prefs.aiLowMemoryMode = props.lowMemoryMode and true or false
            prefs.aiPreferCpu = props.preferCpu and true or false
            prefs.aiDefaultSuggestionsPerImage = n
            settings = {
                suggestionsPerImage = n,
                lowMemoryMode = prefs.aiLowMemoryMode,
                preferCpu = prefs.aiPreferCpu
            }
        end
    end)

    return settings
end

local function promptAiBootstrapNotice()
    if prefs.aiBootstrapNoticeDismissed then
        return true
    end

    local shouldContinue = false

    LrFunctionContext.callWithContext("aiBootstrapNoticeDialog", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)
        props.dontShowAgain = false

        local contents = f:column {
            bind_to_object = props,
            spacing = 8,
            f:static_text { title = "Local AI Setup", width_in_chars = 70 },
            f:static_text { title = "If Ollama is not installed, this plugin will try to install it automatically from the official Ollama installer on first use.", width_in_chars = 90 },
            f:static_text { title = "If no vision model is installed yet, it will also download a vision model such as llava:latest automatically.", width_in_chars = 90 },
            f:static_text { title = "The first AI run can take several minutes and download multiple gigabytes depending on your connection and hardware.", width_in_chars = 90 },
            f:static_text { title = "Internet access is required for the install/model download step.", width_in_chars = 90 },
            f:static_text { title = "For privacy, the plugin sends Ollama only a temporary Lightroom JPEG preview stored in your system temp folder, then deletes it after the run.", width_in_chars = 90 },
            f:static_text { title = "If you ever want to remove Ollama, use Library > Plug-in Extras > Manage Local AI Runtime.", width_in_chars = 90 },
            f:checkbox {
                title = "Don't show this setup notice again",
                value = LrView.bind("dontShowAgain")
            }
        }

        local result = LrDialogs.presentModalDialog {
            title = "Local AI Setup",
            contents = contents,
            actionVerb = "Continue",
            cancelVerb = "Cancel"
        }

        if result == "ok" then
            if props.dontShowAgain then
                prefs.aiBootstrapNoticeDismissed = true
            end
            shouldContinue = true
        end
    end)

    return shouldContinue
end

local function parseStylePresetText(presetText)
    local styles = {}
    local styleOrder = {}
    local text = clean(presetText) or STYLE_PRESETS_DEFAULT

    for entry in text:gmatch("[^;]+") do
        local styleName, pathList = entry:match("^%s*(.-)%s*=%s*(.-)%s*$")
        styleName = sanitizeSegment(styleName)
        pathList = clean(pathList)
        if styleName and pathList then
            local paths = {}
            for p in pathList:gmatch("[^,]+") do
                local path = sanitizeHierarchyPath(p)
                if path then
                    paths[#paths + 1] = path
                end
            end
            if #paths > 0 then
                styles[styleName] = paths
                styleOrder[#styleOrder + 1] = styleName
            end
        end
    end

    return styles, styleOrder, text
end

local function promptStyleSelection()
    local selectedPaths = {}
    local selectedStyleName = "No Style"
    local canceled = true

    LrFunctionContext.callWithContext("styleSelectionDialog", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)

        local parsedStyles, styleOrder, existingText = parseStylePresetText(prefs.stylePresetText)
        props.stylePresetText = existingText
        props.selectedStyle = "No Style"

        local items = {
            { title = "No Style", value = "No Style" }
        }
        table.sort(styleOrder)
        for _, styleName in ipairs(styleOrder) do
            items[#items + 1] = { title = styleName, value = styleName }
        end

        local contents = f:column {
            bind_to_object = props,
            spacing = 8,
            f:static_text { title = "Style (optional):" },
            f:popup_menu {
                value = LrView.bind("selectedStyle"),
                items = items,
                width_in_chars = 30
            },
            f:static_text { title = "Saved style keyword lists (editable):" },
            f:static_text { title = "Format: Style=Path1,Path2;NextStyle=Path1", width_in_chars = 80 },
            f:edit_field {
                value = LrView.bind("stylePresetText"),
                width_in_chars = 90
            }
        }

        local result = LrDialogs.presentModalDialog {
            title = "Style Presets",
            contents = contents,
            actionVerb = "Use Style",
            cancelVerb = "Cancel"
        }

        if result == "ok" then
            local updatedStyles, _, updatedText = parseStylePresetText(props.stylePresetText)
            prefs.stylePresetText = updatedText
            local selected = clean(props.selectedStyle) or "No Style"
            selectedStyleName = selected
            selectedPaths = updatedStyles[selected] or {}
            canceled = false
        end
    end)

    if canceled then
        return nil, nil
    end
    return selectedPaths, selectedStyleName
end

-- ===== MAPPING =====
local MAPPING_RULES = {
    bride = { name="Bride", parent="People" },
    groom = { name="Groom", parent="People" },
    ceremony = { name="Ceremony", parent="Events" },
    reception = { name="Reception", parent="Events" },
    rings = { name="Rings", parent="Details" },
}

safeKeywordCall = function(keyword, methodName)
    if not keyword then return nil end
    local fn = keyword[methodName]
    if type(fn) ~= "function" then
        return nil
    end
    local ok, result = pcall(fn, keyword)
    if ok then
        return result
    end
    return nil
end

local function buildExistingKeywordIndex(catalog)
    local index = {}
    if not catalog then return index end

    local allKeywords = catalog:getKeywords() or {}
    for _, keyword in ipairs(allKeywords) do
        local name = clean(safeKeywordCall(keyword, "getName"))
        if name then
            local fullPath = sanitizeHierarchyPath(safeKeywordCall(keyword, "getNameViaHierarchy"))

            if not fullPath then
                fullPath = name
                local parent = safeKeywordCall(keyword, "getParent")
                local guard = 0
                while parent and guard < 32 do
                    local parentName = clean(safeKeywordCall(parent, "getName"))
                    if not parentName then break end
                    fullPath = parentName .. "|" .. fullPath
                    parent = safeKeywordCall(parent, "getParent")
                    guard = guard + 1
                end
                fullPath = sanitizeHierarchyPath(fullPath) or fullPath
            end

            local key = string.lower(name)
            if not index[key] then
                index[key] = fullPath
            end
            if fullPath then
                keywordPathCache[fullPath] = keyword
            end
            if not keywordCache[key] then
                keywordCache[key] = keyword
            end
        end
    end

    return index
end

local function mapWord(word)
    word = clean(word)
    if not word then return nil end
    return MAPPING_RULES[string.lower(word)]
end

local function promptUnknownKeywordCategories(unknownWords)
    if not unknownWords or #unknownWords == 0 then
        return { __default = "Misc" }
    end

    local resultMap = nil
    local sorted = {}
    for i, word in ipairs(unknownWords) do
        sorted[i] = word
    end
    table.sort(sorted)

    LrFunctionContext.callWithContext("unknownCategoryDialog", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)
        props.defaultCategory = "Misc"
        local categoryRows = { spacing = 4 }
        for i, word in ipairs(sorted) do
            local key = "cat_" .. i
            props[key] = props.defaultCategory
            categoryRows[#categoryRows + 1] = f:row {
                spacing = 8,
                f:static_text { title = word, width_in_chars = 35 },
                f:edit_field {
                    value = LrView.bind(key),
                    width_in_chars = 28
                }
            }
        end

        local contents = f:column {
            bind_to_object = props,
            spacing = 8,
            f:static_text { title = "New AI keywords need a category." },
            f:static_text { title = "Set category path for each keyword (supports |, >, < hierarchy)." },
            f:row {
                spacing = 8,
                f:static_text { title = "Default Category", width_in_chars = 35 },
                f:edit_field {
                    value = LrView.bind("defaultCategory"),
                    width_in_chars = 28
                }
            },
            f:scrolled_view {
                width = 620,
                height = 260,
                horizontal_scroller = false,
                vertical_scroller = true,
                f:column(categoryRows)
            }
        }

        local result = LrDialogs.presentModalDialog {
            title = "Assign Categories for New AI Keywords",
            contents = contents,
            actionVerb = "Use Categories",
            cancelVerb = "Cancel"
        }

        if result == "ok" then
            local defaultCategory = sanitizeHierarchyPath(props.defaultCategory) or "Misc"
            local map = { __default = defaultCategory }
            for i, word in ipairs(sorted) do
                local key = "cat_" .. i
                local category = sanitizeHierarchyPath(props[key]) or defaultCategory
                map[string.lower(word)] = category
            end

            resultMap = map
        end
    end)

    return resultMap
end

local function collectKeywordLearningProfile(photos)
    local counts = {}

    for _, photo in ipairs(photos or {}) do
        if photo then
            local tagText = clean(photo:getFormattedMetadata("keywordTags"))
            if tagText then
                for token in tagText:gmatch("[^,\n\r;]+") do
                    local k = sanitizeSegment(token)
                    if k then
                        local key = string.lower(k)
                        counts[key] = { label = k, count = (counts[key] and counts[key].count or 0) + 1 }
                    end
                end
            end
        end
    end

    local ordered = {}
    for _, v in pairs(counts) do
        ordered[#ordered + 1] = v
    end

    table.sort(ordered, function(a, b)
        if a.count == b.count then
            return a.label < b.label
        end
        return a.count > b.count
    end)

    local top = {}
    for i = 1, math.min(#ordered, 80) do
        top[#top + 1] = ordered[i].label
    end

    return table.concat(top, ", ")
end

local function addKeywordPath(list, set, path, attachedKeywordState)
    path = clean(path)
    if not path then return end
    if set[path] then return end
    if isKeywordAlreadyAttached(path, attachedKeywordState) then return end

    set[path] = true
    list[#list + 1] = path
end

local function resolveWordToPath(word, existingKeywordIndex, categoryMap, unknownSet)
    local cleanWord = sanitizeSegment(word)
    if not cleanWord then return nil end

    local rule = mapWord(cleanWord)
    if rule and rule.parent and rule.name then
        return rule.parent .. "|" .. rule.name
    end

    local key = string.lower(cleanWord)
    if existingKeywordIndex and existingKeywordIndex[key] then
        return existingKeywordIndex[key]
    end

    if unknownSet then
        unknownSet[key] = cleanWord
    end

    local defaultCategory = "Misc"
    if categoryMap and categoryMap.__default then
        defaultCategory = sanitizeHierarchyPath(categoryMap.__default) or "Misc"
    end

    local category = defaultCategory
    if categoryMap and categoryMap[key] then
        category = sanitizeHierarchyPath(categoryMap[key]) or defaultCategory
    end

    local categoryLeaf = category:match("([^|]+)$")
    if categoryLeaf and string.lower(categoryLeaf) == key then
        return category
    end

    return category .. "|" .. cleanWord
end

local function addMappedOrCategorizedPath(paths, pathSet, word, existingKeywordIndex, categoryMap, unknownSet, attachedKeywordState)
    local path = resolveWordToPath(word, existingKeywordIndex, categoryMap, unknownSet)
    if path then
        addKeywordPath(paths, pathSet, path, attachedKeywordState)
    end
end

local function collectKeywordPathsForPhoto(photo, mode, stylePaths, quickTags, aiKeywords, existingKeywordIndex, categoryMap, unknownSet)
    local paths = {}
    local pathSet = {}
    local attachedKeywordState = getPhotoAttachedKeywordState(photo)

    local data = {
        dateInfo = getDateInfo(photo),
        camera = clean(photo and photo:getFormattedMetadata("cameraModel")),
        lens = clean(photo and photo:getFormattedMetadata("lens"))
    }

    if data.camera then
        addKeywordPath(paths, pathSet, "Camera|" .. data.camera, attachedKeywordState)
    end

    if data.dateInfo then
        addKeywordPath(paths, pathSet, "Date|" .. tostring(data.dateInfo.year) .. "|" .. tostring(data.dateInfo.monthName), attachedKeywordState)

        local season = getSeason(data.dateInfo.monthNumber)
        if season then
            addKeywordPath(paths, pathSet, "Season|" .. season, attachedKeywordState)
        end
    end

    if data.lens then
        addKeywordPath(paths, pathSet, "Lens|" .. data.lens, attachedKeywordState)
    end

    if mode == "camera_only" then
        return paths
    end

    if quickTags then
        for word in tostring(quickTags):gmatch("[^,%s;]+") do
            addMappedOrCategorizedPath(paths, pathSet, word, existingKeywordIndex, categoryMap, unknownSet, attachedKeywordState)
        end
    end

    if mode == "ai_local" and aiKeywords and #aiKeywords > 0 then
        for _, aiWord in ipairs(aiKeywords) do
            addMappedOrCategorizedPath(paths, pathSet, aiWord, existingKeywordIndex, categoryMap, unknownSet, attachedKeywordState)
        end
    end

    for _, stylePath in ipairs(stylePaths or {}) do
        addKeywordPath(paths, pathSet, stylePath, attachedKeywordState)
    end

    return paths
end

local function promptKeywordPreview(uniquePaths)
    if not uniquePaths or #uniquePaths == 0 then
        return nil
    end

    local sorted = {}
    for i, value in ipairs(uniquePaths) do
        sorted[i] = value
    end
    table.sort(sorted)

    local approvedSet = nil

    LrFunctionContext.callWithContext("keywordPreviewDialog", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)

        local rowChildren = { spacing = 4 }
        for i, path in ipairs(sorted) do
            local key = "approve_" .. i
            props[key] = true

            rowChildren[#rowChildren + 1] = f:row {
                spacing = 8,
                f:checkbox { value = LrView.bind(key), title = "" },
                f:static_text { title = path, width_in_chars = 72 }
            }
        end

        local contents = f:column {
            bind_to_object = props,
            spacing = 8,
            f:static_text { title = "Approve or deny keywords before applying:" },
            f:static_text { title = "Uncheck a keyword to deny it.", width_in_chars = 60 },
            f:scrolled_view {
                width = 620,
                height = 340,
                horizontal_scroller = false,
                vertical_scroller = true,
                f:column(rowChildren)
            }
        }

        local result = LrDialogs.presentModalDialog {
            title = "Keyword Preview",
            contents = contents,
            actionVerb = "Apply Approved Keywords",
            cancelVerb = "Cancel"
        }

        if result == "ok" then
            approvedSet = {}
            for i, path in ipairs(sorted) do
                if props["approve_" .. i] then
                    approvedSet[path] = true
                end
            end
        end
    end)

    return approvedSet, #sorted
end

-- ===== MAIN =====
LrTasks.startAsyncTask(function()

    local mode = chooseMode()
    if not mode then
        LrDialogs.message("Keywording canceled")
        return
    end

    local aiSettings = nil
    if mode == "ai_local" then
        if not promptAiBootstrapNotice() then
            LrDialogs.message("Keywording canceled")
            return
        end
        aiSettings = promptAiSettings()
        if not aiSettings then
            LrDialogs.message("Keywording canceled")
            return
        end
    end

    local selectedStylePaths = {}
    local selectedStyleName = "No Style"
    local quickTags = nil
    if mode == "full" or mode == "ai_local" then
        local stylePaths, styleName = promptStyleSelection()
        if stylePaths == nil and styleName == nil then
            LrDialogs.message("Keywording canceled")
            return
        end
        selectedStylePaths = stylePaths or {}
        selectedStyleName = styleName or "No Style"
        quickTags = promptQuickTags()
    end

    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()

    if not photos or #photos == 0 then
        LrDialogs.message("No photos selected")
        return
    end

    if mode == "ai_local" and not LocalAiSuggester.isConfigured() then
        LrDialogs.message(
            "Local AI is not configured",
            "Set LOCAL_AI_ENABLED=true in KeywordRunner.lua. LOCAL_AI_COMMAND is optional if using the bundled Ollama bridge script.",
            "OK"
        )
        return
    end

    local maxPhotosPerRun = getConfiguredMaxPhotosPerRun()
    if mode == "ai_local" and #photos > maxPhotosPerRun then
        LrDialogs.message(
            "AI safety limit reached",
            "AI Assist is limited to " .. tostring(maxPhotosPerRun) .. " photos per run to protect system stability. Please select fewer photos or raise the limit in Manage Local AI Runtime.",
            "OK"
        )
        return
    end

    local setupProgress = LrProgressScope({ title = "Preparing Keywords" })
    local function updateSetupProgress(caption, portion)
        if setupProgress.setCaption then
            setupProgress:setCaption(caption)
        end
        if portion then
            setupProgress:setPortionComplete(portion)
        end
    end

    updateSetupProgress("Step 1/5: Parsing existing keyword library", 0.05)
    local existingKeywordIndex = buildExistingKeywordIndex(catalog)

    local plannedByPhoto = {}
    local uniquePaths = {}
    local aiProfile = nil
    local aiKeywordsByPhoto = {}
    local firstAiError = nil

    if mode == "ai_local" then
        updateSetupProgress("Step 2/5: Learning from existing photo keywords", 0.1)
        aiProfile = collectKeywordLearningProfile(photos)
    end

    updateSetupProgress("Step 3/5: Building keyword candidates", 0.15)

    local function buildPlan(categoryMap, collectUnknown)
        local perPhoto = {}
        local uniquePathSet = {}
        local unique = {}
        local unknownSet = collectUnknown and {} or nil

        for i, photo in ipairs(photos) do
            local aiKeywords = aiKeywordsByPhoto[i]
            local paths = collectKeywordPathsForPhoto(photo, mode, selectedStylePaths, quickTags, aiKeywords, existingKeywordIndex, categoryMap, unknownSet)
            perPhoto[i] = paths

            for _, path in ipairs(paths) do
                if not uniquePathSet[path] then
                    uniquePathSet[path] = true
                    unique[#unique + 1] = path
                end
            end
        end

        return perPhoto, unique, unknownSet
    end

    for i, photo in ipairs(photos) do
        if mode == "ai_local" then
            local aiErr = nil
            local aiKeywords = nil
            aiKeywords, aiErr = LocalAiSuggester.suggest(photo, aiProfile, aiSettings)
            aiKeywordsByPhoto[i] = aiKeywords or {}
            if aiErr and not firstAiError then
                firstAiError = aiErr
            end

            if AI_COOLDOWN_SECONDS > 0 then
                LrTasks.sleep(AI_COOLDOWN_SECONDS)
            end
        end
        updateSetupProgress("Step 3/5: Building keyword candidates (" .. tostring(i) .. "/" .. tostring(#photos) .. ")", 0.15 + (0.45 * (i / #photos)))
    end

    local categoryMap = { __default = "Misc" }
    if mode == "ai_local" then
        local _, _, unknownSet = buildPlan(nil, true)
        local unknownWords = {}
        for _, word in pairs(unknownSet or {}) do
            unknownWords[#unknownWords + 1] = word
        end

        if #unknownWords > 0 then
            updateSetupProgress("Step 4/5: Assign categories for new AI keywords", 0.65)
            categoryMap = promptUnknownKeywordCategories(unknownWords)
            if not categoryMap then
                setupProgress:done()
                LrDialogs.message("Keywording canceled")
                return
            end
        end
    end

    plannedByPhoto, uniquePaths = buildPlan(categoryMap, false)

    updateSetupProgress("Step 5/5: Preparing preview", 0.85)
    if #uniquePaths == 0 then
        setupProgress:done()
        LrDialogs.message("No keywords generated for selected photos")
        return
    end

    local approvedSet, previewCount = promptKeywordPreview(uniquePaths)
    setupProgress:done()
    if not approvedSet then
        LrDialogs.message("Keywording canceled")
        return
    end

    local approvedCount = 0
    for _ in pairs(approvedSet) do
        approvedCount = approvedCount + 1
    end

    if approvedCount == 0 then
        LrDialogs.message("No approved keywords to apply")
        return
    end

    local progress = LrProgressScope({ title = "Applying Approved Keywords" })

    catalog:withWriteAccessDo("Apply Keywords", function()
        for i, photo in ipairs(photos) do
            if progress.setCaption then
                progress:setCaption("Applying keywords to photo " .. tostring(i) .. " of " .. tostring(#photos))
            end
            local paths = plannedByPhoto[i] or {}
            for _, path in ipairs(paths) do
                if approvedSet[path] then
                    local kw = getOrCreatePath(catalog, path)
                    if kw then
                        photo:addKeyword(kw)
                    end
                end
            end

            progress:setPortionComplete(i / #photos)
        end
    end)

    progress:done()
    if firstAiError then
        LrDialogs.message(
            "Applied " .. tostring(approvedCount) .. " approved keywords (" .. tostring(previewCount or 0) .. " proposed)",
            "Style: " .. tostring(selectedStyleName) .. "\nAI note: " .. tostring(firstAiError),
            "OK"
        )
    else
        LrDialogs.message("Applied " .. tostring(approvedCount) .. " approved keywords (" .. tostring(previewCount or 0) .. " proposed)\nStyle: " .. tostring(selectedStyleName))
    end

end)
