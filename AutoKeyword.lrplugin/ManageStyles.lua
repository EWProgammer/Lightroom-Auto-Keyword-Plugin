-- ============================================================================
-- MANAGESTYLES.LUA
-- Style Presets Manager Implementation
-- ============================================================================
-- This module implements the Manage Style Presets dialog. It allows users to
-- define custom keyword style profiles. Each style maps a friendly name to
-- Lightroom keyword hierarchy paths. Users can save up to 14 different styles
-- for use when generating keywords for photos.
-- ============================================================================

-- Import Lightroom's asynchronous task management library
local LrTasks = import 'LrTasks'

-- Import Lightroom's dialog box library for modals and messages
local LrDialogs = import 'LrDialogs'

-- Import Lightroom's UI/view factory for creating dialogs
local LrView = import 'LrView'

-- Import Lightroom's data binding system for UI-to-data synchronization
local LrBinding = import 'LrBinding'

-- Import Lightroom's context manager for dialog contexts
local LrFunctionContext = import 'LrFunctionContext'

-- Import Lightroom's preferences module for persistence
local LrPrefs = import 'LrPrefs'

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

-- Default style presets when user hasn't created custom ones
local STYLE_PRESETS_DEFAULT = "Wedding=Event Type|Wedding;Portrait=Event Type|Portrait;Fine Art=Style|Fine Art"

-- Maximum number of editable style rows in the dialog
local MAX_STYLE_ROWS = 14

-- Reference to the plugin's persistent preferences
local prefs = LrPrefs.prefsForPlugin()

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

--- Removes leading and trailing whitespace
-- Returns nil if the result is empty
-- @param value String to trim
-- @return Trimmed string or nil
local function trim(value)
    if value == nil then return nil end
    local s = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

--- Normalizes a keyword hierarchy path to standard Lightroom format (pipe-separated)
-- Accepts formats like: "Parent|Child", "Parent > Child", "Parent › Child"
-- @param value The hierarchy path to normalize
-- @return Normalized path using | separators, or nil if invalid
local function sanitizeHierarchyPath(value)
    local s = trim(value)
    if not s then return nil end
    
    -- Replace arrow-style separators with pipe separator
    s = s:gsub("%s*[>›]%s*", "|")

    -- Split and clean each part
    local parts = {}
    for part in s:gmatch("[^|]+") do
        local p = trim(part)
        if p then
            -- Convert pipes within parts to forward slashes (literal)
            p = p:gsub("|", "/")
            parts[#parts + 1] = p
        end
    end

    if #parts == 0 then return nil end
    return table.concat(parts, "|")
end

--- Parses serialized style presets into individual entries
-- Format: "StyleName=Path1,Path2;StyleName2=Path3,Path4"
-- @param text Serialized preset string (or nil to use defaults)
-- @return Array of {name="...", paths="..."} entries
local function parsePresetEntries(text)
    local entries = {}
    local raw = trim(text) or STYLE_PRESETS_DEFAULT
    
    -- Split by semicolon to get individual styles
    for token in raw:gmatch("[^;\r\n]+") do
        -- Parse "StyleName = Path1,Path2"
        local styleName, paths = token:match("^%s*(.-)%s*=%s*(.-)%s*$")
        styleName = trim(styleName)
        paths = trim(paths)
        
        if styleName and paths then
            -- Normalize each comma-separated path
            local normalizedPaths = {}
            for path in paths:gmatch("[^,]+") do
                local p = sanitizeHierarchyPath(path)
                if p then
                    normalizedPaths[#normalizedPaths + 1] = p
                end
            end
            
            -- Only add if we have valid paths
            if #normalizedPaths > 0 then
                entries[#entries + 1] = {
                    name = styleName,
                    paths = table.concat(normalizedPaths, ",")
                }
            end
        end
    end
    return entries
end

--- Converts style entries back to the serialization format
-- @param entries Array of {name="...", paths="..."} entries
-- @return Serialized string and count of valid entries
local function serializeEntries(entries)
    local out = {}
    
    -- Convert each entry to "StyleName=Path1,Path2" format
    for _, e in ipairs(entries or {}) do
        local name = trim(e.name)
        local paths = trim(e.paths)
        if name and paths then
            -- Normalize all paths again for consistency
            local normalizedPaths = {}
            for path in paths:gmatch("[^,]+") do
                local p = sanitizeHierarchyPath(path)
                if p then
                    normalizedPaths[#normalizedPaths + 1] = p
                end
            end
            
            if #normalizedPaths > 0 then
                out[#out + 1] = name .. "=" .. table.concat(normalizedPaths, ",")
            end
        end
    end

    -- Return defaults if no valid entries
    if #out == 0 then
        return STYLE_PRESETS_DEFAULT, 3
    end

    return table.concat(out, ";"), #out
end

-- ============================================================================
-- DIALOG IMPLEMENTATION
-- ============================================================================

-- Start async task to prevent UI freezing
LrTasks.startAsyncTask(function()
    -- Create a context for the modal dialog
    LrFunctionContext.callWithContext("manageStylesDialog", function(context)
        -- Factory for native UI controls
        local f = LrView.osFactory()
        
        -- Property table for data binding
        local props = LrBinding.makePropertyTable(context)

        -- Load existing style presets
        local existing = parsePresetEntries(prefs.stylePresetText)
        
        -- Initialize property table with existing data
        for i = 1, MAX_STYLE_ROWS do
            props["styleName_" .. i] = existing[i] and existing[i].name or ""
            props["stylePaths_" .. i] = existing[i] and existing[i].paths or ""
        end

        -- Build the dialog rows
        local rows = { spacing = 6 }
        
        -- Column header
        rows[#rows + 1] = f:row {
            spacing = 8,
            f:static_text { title = "Style Name", width_in_chars = 22 },
            f:static_text { title = "Keyword Paths (comma-separated, use | for hierarchy)", width_in_chars = 74 }
        }

        -- Input rows for each style
        for i = 1, MAX_STYLE_ROWS do
            rows[#rows + 1] = f:row {
                spacing = 8,
                f:edit_field {
                    value = LrView.bind("styleName_" .. i),
                    width_in_chars = 22
                },
                f:edit_field {
                    value = LrView.bind("stylePaths_" .. i),
                    width_in_chars = 74
                }
            }
        end

        -- Build dialog content
        local contents = f:column {
            bind_to_object = props,
            spacing = 8,
            f:static_text { title = "Manage Saved Style Presets" },
            f:static_text { title = "Example paths: Event Type|Wedding,People|Bride", width_in_chars = 90 },
            f:scrolled_view {
                width = 980,
                height = 360,
                horizontal_scroller = true,
                vertical_scroller = true,
                f:column(rows)
            }
        }

        -- Display the dialog and get user response
        local result = LrDialogs.presentModalDialog {
            title = "Manage Style Presets",
            contents = contents,
            actionVerb = "Save Presets",
            cancelVerb = "Cancel"
        }

        -- Save if user clicked OK
        if result == "ok" then
            -- Collect all non-empty entries from the dialog
            local entries = {}
            for i = 1, MAX_STYLE_ROWS do
                local name = trim(props["styleName_" .. i])
                local paths = trim(props["stylePaths_" .. i])
                if name and paths then
                    entries[#entries + 1] = { name = name, paths = paths }
                end
            end

            -- Serialize and persist
            local serialized, count = serializeEntries(entries)
            prefs.stylePresetText = serialized
            
            -- Confirm to user
            LrDialogs.message("Saved " .. tostring(count) .. " style preset(s).")
        end
    end)
end)
