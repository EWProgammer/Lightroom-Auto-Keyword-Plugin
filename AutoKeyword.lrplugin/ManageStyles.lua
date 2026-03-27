local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs = import 'LrPrefs'

local STYLE_PRESETS_DEFAULT = "Wedding=Event Type|Wedding;Portrait=Event Type|Portrait;Fine Art=Style|Fine Art"
local MAX_STYLE_ROWS = 14
local prefs = LrPrefs.prefsForPlugin()

local function trim(value)
    if value == nil then return nil end
    local s = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

local function sanitizeHierarchyPath(value)
    local s = trim(value)
    if not s then return nil end
    s = s:gsub("%s*[>›]%s*", "|")

    local parts = {}
    for part in s:gmatch("[^|]+") do
        local p = trim(part)
        if p then
            p = p:gsub("|", "/")
            parts[#parts + 1] = p
        end
    end

    if #parts == 0 then return nil end
    return table.concat(parts, "|")
end

local function parsePresetEntries(text)
    local entries = {}
    local raw = trim(text) or STYLE_PRESETS_DEFAULT
    for token in raw:gmatch("[^;\r\n]+") do
        local styleName, paths = token:match("^%s*(.-)%s*=%s*(.-)%s*$")
        styleName = trim(styleName)
        paths = trim(paths)
        if styleName and paths then
            local normalizedPaths = {}
            for path in paths:gmatch("[^,]+") do
                local p = sanitizeHierarchyPath(path)
                if p then
                    normalizedPaths[#normalizedPaths + 1] = p
                end
            end
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

local function serializeEntries(entries)
    local out = {}
    for _, e in ipairs(entries or {}) do
        local name = trim(e.name)
        local paths = trim(e.paths)
        if name and paths then
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

    if #out == 0 then
        return STYLE_PRESETS_DEFAULT, 3
    end

    return table.concat(out, ";"), #out
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext("manageStylesDialog", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)

        local existing = parsePresetEntries(prefs.stylePresetText)
        for i = 1, MAX_STYLE_ROWS do
            props["styleName_" .. i] = existing[i] and existing[i].name or ""
            props["stylePaths_" .. i] = existing[i] and existing[i].paths or ""
        end

        local rows = { spacing = 6 }
        rows[#rows + 1] = f:row {
            spacing = 8,
            f:static_text { title = "Style Name", width_in_chars = 22 },
            f:static_text { title = "Keyword Paths (comma-separated, use | for hierarchy)", width_in_chars = 74 }
        }

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

        local result = LrDialogs.presentModalDialog {
            title = "Manage Style Presets",
            contents = contents,
            actionVerb = "Save Presets",
            cancelVerb = "Cancel"
        }

        if result == "ok" then
            local entries = {}
            for i = 1, MAX_STYLE_ROWS do
                local name = trim(props["styleName_" .. i])
                local paths = trim(props["stylePaths_" .. i])
                if name and paths then
                    entries[#entries + 1] = { name = name, paths = paths }
                end
            end

            local serialized, count = serializeEntries(entries)
            prefs.stylePresetText = serialized
            LrDialogs.message("Saved " .. tostring(count) .. " style preset(s).")
        end
    end)
end)
