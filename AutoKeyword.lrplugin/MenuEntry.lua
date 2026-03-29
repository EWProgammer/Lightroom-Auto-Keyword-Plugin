-- ============================================================================
-- MENUENTRY.LUA
-- Style Presets Manager UI
-- ============================================================================
-- This module provides the Manage Style Presets dialog that allows users to
-- define custom keyword style profiles. Each style maps a friendly name to one
-- or more Lightroom keyword hierarchy paths. When keywords are processed, users
-- can apply styles to pre-populate certain keywords based on the style selected.
-- ============================================================================

-- Import Lightroom's asynchronous task management library
local LrTasks = import 'LrTasks'

-- Import Lightroom's dialog box library for showing messages and dialogs
local LrDialogs = import 'LrDialogs'

-- Import Lightroom's UI/view factory for building dynamic dialogs
local LrView = import 'LrView'

-- Import Lightroom's data binding system for two-way binding between UI and data
local LrBinding = import 'LrBinding'

-- Import Lightroom's context manager for creating dialog contexts
local LrFunctionContext = import 'LrFunctionContext'

-- Import Lightroom's preferences module for persistent plugin settings
local LrPrefs = import 'LrPrefs'

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

-- Default style presets if user has never created any
-- Format: "StyleName=Path1|Hierarchy|Structure,Path2|Another|Hierarchy;StyleName2=..."
local STYLE_PRESETS_DEFAULT = "Wedding=Event Type|Wedding;Portrait=Event Type|Portrait;Fine Art=Style|Fine Art"

-- Maximum number of style rows shown in the UI dialog
local MAX_STYLE_ROWS = 14

-- Get reference to plugin preferences for saving/loading style data
local prefs = LrPrefs.prefsForPlugin()

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

--- Removes leading and trailing whitespace from a string
-- Returns nil if string is empty or only whitespace
-- @param value The string to trim
-- @return Trimmed string or nil if empty
local function trim(value)
    if value == nil then return nil end
    local s = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

--- Normalizes a keyword hierarchy path to standard Lightroom format
-- Accepts multiple formats:
--   - Pipe-separated: "Parent|Child"
--   - Arrow-separated: "Parent > Child" or "Child < Parent"
--   - Slash-separated: "Parent/Child" (converts to pipe)
-- Handles edge case where < format (reversed hierarchy) needs to be un-reversed
-- @param value The hierarchy path in any supported format
-- @return Normalized path using pipe (|) separators, or nil if invalid
local function sanitizeHierarchyPath(value)
    local s = trim(value)
    if not s then return nil end

    -- Handle reversed hierarchy format: "child < parent < grandparent"
    -- These need to be reversed to "grandparent | parent | child"
    if s:find("<", 1, true) and not s:find("|", 1, true) and not s:find(">", 1, true) and not s:find("›", 1, true) then
        local reverseParts = {}
        for part in s:gmatch("[^<]+") do
            local p = trim(part)
            if p then
                p = p:gsub("|", "/")  -- Convert pipes to slashes (they're literal here)
                reverseParts[#reverseParts + 1] = p
            end
        end
        if #reverseParts == 0 then return nil end
        
        -- Reverse the order
        local ordered = {}
        for i = #reverseParts, 1, -1 do
            ordered[#ordered + 1] = reverseParts[i]
        end
        return table.concat(ordered, "|")
    end

    -- Convert arrow separators (> or <) to pipe separators
    s = s:gsub("%s*[>›<]%s*", "|")

    -- Split by pipe and normalize each part
    local parts = {}
    for part in s:gmatch("[^|]+") do
        local p = trim(part)
        if p then
            -- Convert slashes to the literal "/" character instead of hierarchy separator
            p = p:gsub("|", "/")
            parts[#parts + 1] = p
        end
    end

    if #parts == 0 then return nil end
    return table.concat(parts, "|")
end

--- Parses the serialized style presets string into a table of entries
-- Format expected: "StyleName=Path1,Path2;StyleName2=Path1,Path2"
-- @param text The serialized style preset string (or nil to use defaults)
-- @return Table of entries: {{name="...", paths="..."}, ...}
local function parsePresetEntries(text)
    local entries = {}
    -- Use default presets if user hasn't set anything yet
    local raw = trim(text) or STYLE_PRESETS_DEFAULT
    
    -- Split by semicolon to get individual style definitions
    for token in raw:gmatch("[^;\r\n]+") do
        -- Parse "StyleName = Path1,Path2"
        local styleName, paths = token:match("^%s*(.-)%s*=%s*(.-)%s*$")
        styleName = trim(styleName)
        paths = trim(paths)
        
        if styleName and paths then
            -- Split comma-separated paths and normalize each
            local normalizedPaths = {}
            for path in paths:gmatch("[^,]+") do
                local p = sanitizeHierarchyPath(path)
                if p then
                    normalizedPaths[#normalizedPaths + 1] = p
                end
            end
            
            -- Only add style if it has valid paths
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

--- Converts a table of style entries back to the serialized string format
-- @param entries Table of entries: {{name="...", paths="..."}, ...}
-- @return Serialized string and count of valid entries
local function serializeEntries(entries)
    local out = {}
    
    -- Convert each entry to "StyleName=Path1,Path2" format
    for _, e in ipairs(entries or {}) do
        local name = trim(e.name)
        local paths = trim(e.paths)
        
        if name and paths then
            -- Normalize all paths
            local normalizedPaths = {}
            for path in paths:gmatch("[^,]+") do
                local p = sanitizeHierarchyPath(path)
                if p then
                    normalizedPaths[#normalizedPaths + 1] = p
                end
            end
            
            -- Build entry string
            if #normalizedPaths > 0 then
                out[#out + 1] = name .. "=" .. table.concat(normalizedPaths, ",")
            end
        end
    end

    -- If no valid entries, return defaults
    if #out == 0 then
        return STYLE_PRESETS_DEFAULT, 3
    end

    return table.concat(out, ";"), #out
end

-- ============================================================================
-- UI DIALOG
-- ============================================================================

-- Start async task so the dialog doesn't block Lightroom's UI
LrTasks.startAsyncTask(function()
    -- Create a dialog context for this modal dialog
    LrFunctionContext.callWithContext("manageStylesDialog", function(context)
        -- Factory for creating OS-native UI elements
        local f = LrView.osFactory()
        
        -- Create a property table for two-way data binding with UI elements
        local props = LrBinding.makePropertyTable(context)

        -- Load existing style preset entries from saved preferences
        local existing = parsePresetEntries(prefs.stylePresetText)
        
        -- Populate property table with existing styles (one per UI row)
        for i = 1, MAX_STYLE_ROWS do
            props["styleName_" .. i] = existing[i] and existing[i].name or ""
            props["stylePaths_" .. i] = existing[i] and existing[i].paths or ""
        end

        -- Build the dialog rows
        local rows = { spacing = 6 }
        
        -- Header row with column labels
        rows[#rows + 1] = f:row {
            spacing = 8,
            f:static_text { title = "Style Name", width_in_chars = 22 },
            f:static_text { title = "Keyword Paths (comma-separated, use | for hierarchy)", width_in_chars = 74 }
        }

        -- Add input rows for each style (user can edit these)
        for i = 1, MAX_STYLE_ROWS do
            rows[#rows + 1] = f:row {
                spacing = 8,
                -- Style name input field
                f:edit_field {
                    value = LrView.bind("styleName_" .. i),
                    width_in_chars = 22
                },
                -- Keyword paths input field
                f:edit_field {
                    value = LrView.bind("stylePaths_" .. i),
                    width_in_chars = 74
                }
            }
        end

        -- Build the main dialog content
        local contents = f:column {
            bind_to_object = props,  -- Bind all controls to property table
            spacing = 8,
            
            -- Dialog title
            f:static_text { title = "Manage Saved Style Presets" },
            
            -- Help text showing examples
            f:static_text { title = "Example paths: Event Type|Wedding,People|Bride (also supports > and <)", width_in_chars = 90 },
            
            -- Scrollable area containing all input rows
            f:scrolled_view {
                width = 980,
                height = 360,
                horizontal_scroller = true,
                vertical_scroller = true,
                f:column(rows)
            }
        }

        -- Show the modal dialog and wait for user response
        local result = LrDialogs.presentModalDialog {
            title = "Manage Style Presets",
            contents = contents,
            actionVerb = "Save Presets",
            cancelVerb = "Cancel"
        }

        -- Process the result if user clicked "Save Presets"
        if result == "ok" then
            -- Collect all non-empty entries from the dialog
            local entries = {}
            for i = 1, MAX_STYLE_ROWS do
                local name = trim(props["styleName_" .. i])
                local paths = trim(props["stylePaths_" .. i])
                
                -- Only include rows where both name and paths are provided
                if name and paths then
                    entries[#entries + 1] = { name = name, paths = paths }
                end
            end

            -- Serialize and save to preferences
            local serialized, count = serializeEntries(entries)
            prefs.stylePresetText = serialized
            
            -- Show confirmation message
            LrDialogs.message("Saved " .. tostring(count) .. " style preset(s).")
        end
    end)
end)
