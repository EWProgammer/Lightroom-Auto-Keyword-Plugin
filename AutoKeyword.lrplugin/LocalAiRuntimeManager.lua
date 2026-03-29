local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs = import 'LrPrefs'

local prefs = LrPrefs.prefsForPlugin()

local function trim(value)
    if value == nil then return nil end
    local s = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

local function pathExists(path)
    if not trim(path) then return false end
    local ok, result = pcall(function()
        local f = io.open(path, "rb")
        if f then
            f:close()
            return true
        end
        return false
    end)
    return ok and result or false
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
local DEFAULT_SUGGESTIONS = 10
local DEFAULT_MAX_PHOTOS = 10
local MAC_SAFE_SUGGESTIONS = 6
local MAC_SAFE_MAX_PHOTOS = 3

local function getConfiguredSuggestionsPerImage()
    local n = tonumber(prefs.aiDefaultSuggestionsPerImage)
    if not n then
        n = DEFAULT_SUGGESTIONS
    end
    return math.max(1, math.min(30, math.floor(n)))
end

local function getConfiguredMaxPhotosPerRun()
    local n = tonumber(prefs.aiMaxPhotosPerRun)
    if not n then
        n = DEFAULT_MAX_PHOTOS
    end
    return math.max(1, math.min(200, math.floor(n)))
end

local function getWindowsPaths()
    local localAppData = os.getenv and os.getenv("LOCALAPPDATA") or ""
    local homePath = os.getenv and os.getenv("USERPROFILE") or ""
    local installDir = trim(localAppData) and (localAppData .. "\\Programs\\Ollama") or nil
    local uninstaller = installDir and (installDir .. "\\unins000.exe") or nil
    local modelsDir = trim(homePath) and (homePath .. "\\.ollama") or nil
    return {
        installDir = installDir,
        uninstaller = uninstaller,
        modelsDir = modelsDir,
    }
end

local function getMacPaths()
    local homePath = os.getenv and os.getenv("HOME") or ""
    return {
        appPath = "/Applications/Ollama.app",
        cliPath = "/usr/local/bin/ollama",
        altCliPath = "/opt/homebrew/bin/ollama",
        modelsDir = trim(homePath) and (homePath .. "/.ollama") or nil,
    }
end

local function launchWindowsUninstaller(uninstaller)
    if not pathExists(uninstaller) then
        LrDialogs.message("Ollama uninstaller not found", "Try Windows Settings > Apps > Installed apps > Ollama.", "OK")
        return
    end

    local result = LrDialogs.confirm(
        "Run Ollama uninstaller?",
        "This will launch the installed Ollama uninstaller. Ollama models may remain on disk if the uninstaller does not remove them.",
        "Run Uninstaller",
        "Cancel"
    )

    if result == "ok" then
        LrTasks.execute('start "" "' .. uninstaller .. '"')
    end
end

local function showMacUninstallInstructions(paths)
    local lines = table.concat({
        "To fully remove Ollama on macOS, Ollama's official docs currently recommend removing these items:",
        "",
        "sudo rm -rf /Applications/Ollama.app",
        "sudo rm /usr/local/bin/ollama",
        "rm -rf ~/Library/Application Support/Ollama",
        "rm -rf ~/Library/Saved Application State/com.electron.ollama.savedState",
        "rm -rf ~/Library/Caches/com.electron.ollama",
        "rm -rf ~/Library/Caches/ollama",
        "rm -rf ~/Library/WebKit/com.electron.ollama",
        "rm -rf ~/.ollama",
        "",
        "If you installed the CLI via Homebrew instead, also check:",
        paths.altCliPath or "/opt/homebrew/bin/ollama"
    }, "\n")

    LrDialogs.message("macOS Ollama Uninstall", lines, "OK")
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext("localAiRuntimeManagerDialog", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)
        props.showStartupNotice = not not prefs.aiBootstrapNoticeDismissed
        props.defaultSuggestions = tostring(getConfiguredSuggestionsPerImage())
        props.maxPhotosPerRun = tostring(getConfiguredMaxPhotosPerRun())
        props.lowMemoryMode = prefs.aiLowMemoryMode and true or false
        props.preferCpu = prefs.aiPreferCpu and true or false

        local contents = nil
        local actionVerb = nil
        local actionMode = nil

        if IS_WINDOWS then
            local paths = getWindowsPaths()
            local hasInstall = pathExists(paths.uninstaller)
            actionVerb = hasInstall and "Run Ollama Uninstaller" or nil
            actionMode = hasInstall and "windows_uninstall" or nil

            contents = f:column {
                bind_to_object = props,
                spacing = 8,
                f:static_text { title = "Local AI Runtime Details", width_in_chars = 90 },
                f:static_text { title = "This plugin can automatically install Ollama and download a vision model on the first AI run if Ollama is missing.", width_in_chars = 90 },
                f:static_text { title = "The first AI run may take several minutes and multiple gigabytes of downloads.", width_in_chars = 90 },
                f:static_text { title = "Ollama install location: " .. tostring(paths.installDir or "Unknown"), width_in_chars = 90 },
                f:static_text { title = "Ollama model storage: " .. tostring(paths.modelsDir or "Unknown"), width_in_chars = 90 },
                f:static_text { title = "Temporary Lightroom JPEG previews are written to your temp folder only for the duration of an AI run and then deleted.", width_in_chars = 90 },
                f:static_text { title = "Default suggestions per image:", width_in_chars = 35 },
                f:edit_field { value = LrView.bind("defaultSuggestions"), width_in_chars = 6 },
                f:static_text { title = "Max selected photos allowed per AI run:", width_in_chars = 35 },
                f:edit_field { value = LrView.bind("maxPhotosPerRun"), width_in_chars = 6 },
                f:checkbox {
                    title = "Low memory mode: prefer a smaller vision model",
                    value = LrView.bind("lowMemoryMode")
                },
                f:checkbox {
                    title = "Prefer CPU when the plugin starts Ollama",
                    value = LrView.bind("preferCpu")
                },
                f:static_text { title = "To fully remove Ollama, use the uninstaller below. Some downloaded models may remain in ~/.ollama unless removed separately.", width_in_chars = 90 },
                f:checkbox {
                    title = "Hide the detailed Local AI setup notice before future AI runs",
                    value = LrView.bind("showStartupNotice")
                }
            }
        else
            local paths = getMacPaths()
            actionVerb = "Show macOS Uninstall Steps"
            actionMode = "mac_uninstall_help"

            contents = f:column {
                bind_to_object = props,
                spacing = 8,
                f:static_text { title = "Local AI Runtime Details", width_in_chars = 90 },
                f:static_text { title = "This plugin can automatically install Ollama and download a vision model on the first AI run if Ollama is missing.", width_in_chars = 90 },
                f:static_text { title = "The first AI run may take several minutes and multiple gigabytes of downloads.", width_in_chars = 90 },
                f:static_text { title = "Ollama app location: " .. tostring(paths.appPath), width_in_chars = 90 },
                f:static_text { title = "Ollama CLI locations: " .. tostring(paths.cliPath) .. " or " .. tostring(paths.altCliPath), width_in_chars = 90 },
                f:static_text { title = "Ollama model storage: " .. tostring(paths.modelsDir or "Unknown"), width_in_chars = 90 },
                f:static_text { title = "Temporary Lightroom JPEG previews are written to your temp folder only for the duration of an AI run and then deleted.", width_in_chars = 90 },
                f:static_text { title = "Default suggestions per image:", width_in_chars = 35 },
                f:edit_field { value = LrView.bind("defaultSuggestions"), width_in_chars = 6 },
                f:static_text { title = "Max selected photos allowed per AI run:", width_in_chars = 35 },
                f:edit_field { value = LrView.bind("maxPhotosPerRun"), width_in_chars = 6 },
                f:checkbox {
                    title = "Low memory mode: prefer a smaller vision model",
                    value = LrView.bind("lowMemoryMode")
                },
                f:checkbox {
                    title = "Prefer CPU when the plugin starts Ollama",
                    value = LrView.bind("preferCpu")
                },
                f:static_text { title = "Recommended low-end Mac defaults: 6 suggestions, max 3 photos, low memory mode on, prefer CPU on.", width_in_chars = 90 },
                f:static_text { title = "Use the button below to review the official macOS uninstall paths.", width_in_chars = 90 },
                f:checkbox {
                    title = "Hide the detailed Local AI setup notice before future AI runs",
                    value = LrView.bind("showStartupNotice")
                }
            }
        end

        local result = LrDialogs.presentModalDialog {
            title = "Manage Local AI Runtime",
            contents = contents,
            actionVerb = actionVerb or "Close",
            cancelVerb = "Done"
        }

        local suggestions = tonumber(props.defaultSuggestions)
        if not suggestions then
            suggestions = getConfiguredSuggestionsPerImage()
        end
        suggestions = math.max(1, math.min(30, math.floor(suggestions)))

        local maxPhotos = tonumber(props.maxPhotosPerRun)
        if not maxPhotos then
            maxPhotos = getConfiguredMaxPhotosPerRun()
        end
        maxPhotos = math.max(1, math.min(200, math.floor(maxPhotos)))

        prefs.aiDefaultSuggestionsPerImage = suggestions
        prefs.aiMaxPhotosPerRun = maxPhotos
        prefs.aiLowMemoryMode = props.lowMemoryMode and true or false
        prefs.aiPreferCpu = props.preferCpu and true or false
        prefs.aiBootstrapNoticeDismissed = props.showStartupNotice and true or false

        if result == "ok" then
            if actionMode == "windows_uninstall" then
                launchWindowsUninstaller(getWindowsPaths().uninstaller)
            elseif actionMode == "mac_uninstall_help" then
                showMacUninstallInstructions(getMacPaths())
            end
        end
    end)
end)
