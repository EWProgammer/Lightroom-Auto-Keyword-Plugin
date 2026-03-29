-- ============================================================================
-- LOCALAIRUNTIMEMANAGER.LUA
-- Ollama Runtime Configuration and Management UI
-- ============================================================================
-- This module provides a dialog for managing the local AI (Ollama) runtime.
-- Users can configure AI settings, see installation paths, manage models, and
-- uninstall Ollama if needed. Platform-specific options are provided for
-- Windows and macOS/Linux systems.
-- ============================================================================

-- Import Lightroom SDK libraries
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs = import 'LrPrefs'

-- Get access to plugin preferences for saving settings
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

--- Checks if a file path exists by attempting to open it
-- Uses safe error handling to avoid crashing
-- @param path File path to check
-- @return Boolean: true if file exists, false otherwise
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

--- Detects if running on Windows OS
-- Checks environment variables and package configuration
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

    return package and package.config and package.config:sub(1, 1) == "\\" or false
end

-- Detects OS once at module load
local IS_WINDOWS = detectWindows()

-- ============================================================================
-- CONFIGURATION VALUES
-- ============================================================================

-- Default number of AI suggestions 
local DEFAULT_SUGGESTIONS = 10
local DEFAULT_MAX_PHOTOS = 10

-- Conservative defaults for Mac systems (lower RAM)
local MAC_SAFE_SUGGESTIONS = 6
local MAC_SAFE_MAX_PHOTOS = 3
local PROFILE_FASTEST = "fastest"
local PROFILE_BALANCED = "balanced"
local PROFILE_LOW_MEMORY = "low_memory"

--- Gets configured suggestions per image from preferences
-- @return Number clamped to range 1-30
local function getConfiguredSuggestionsPerImage()
    local n = tonumber(prefs.aiDefaultSuggestionsPerImage)
    if not n then
        n = DEFAULT_SUGGESTIONS
    end
    return math.max(1, math.min(30, math.floor(n)))
end

--- Gets configured max photos per run from preferences
-- @return Number clamped to range 1-200
local function getConfiguredMaxPhotosPerRun()
    local n = tonumber(prefs.aiMaxPhotosPerRun)
    if not n then
        n = DEFAULT_MAX_PHOTOS
    end
    return math.max(1, math.min(200, math.floor(n)))
end

local function getConfiguredPerformanceProfile()
    local profile = trim(prefs.aiPerformanceProfile)
    if profile == PROFILE_FASTEST or profile == PROFILE_BALANCED or profile == PROFILE_LOW_MEMORY then
        return profile
    end

    if prefs.aiLowMemoryMode and prefs.aiPreferCpu then
        return PROFILE_LOW_MEMORY
    end

    if prefs.aiLowMemoryMode or prefs.aiPreferCpu then
        return PROFILE_BALANCED
    end

    return PROFILE_FASTEST
end

-- ============================================================================
-- PLATFORM-SPECIFIC PATH HELPERS
-- ============================================================================

--- Gets typical Ollama installation paths on Windows
-- @return Table with installDir, uninstaller, and modelsDir paths
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

--- Gets typical Ollama installation paths on macOS/Linux
-- @return Table with appPath, cliPath, altCliPath, and modelsDir paths
local function getMacPaths()
    local homePath = os.getenv and os.getenv("HOME") or ""
    return {
        appPath = "/Applications/Ollama.app",
        cliPath = "/usr/local/bin/ollama",
        altCliPath = "/opt/homebrew/bin/ollama",
        modelsDir = trim(homePath) and (homePath .. "/.ollama") or nil,
    }
end

-- ============================================================================
-- UNINSTALL HELPERS
-- ============================================================================

--- Launches the Windows Ollama uninstaller if found
-- Confirms with user before executing
-- @param uninstaller Path to unins000.exe
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

--- Shows recommended manual uninstall steps for macOS
-- Ollama on macOS doesn't have an automated uninstaller, so users must
-- manually remove files following the official uninstall documentation
-- @param paths Table with macOS Ollama paths
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

-- ============================================================================
-- MAIN DIALOG UI
-- ============================================================================

local function applyStandardDefaults(props)
    props.performanceProfile = PROFILE_BALANCED
    props.defaultSuggestions = tostring(DEFAULT_SUGGESTIONS)
    props.maxPhotosPerRun = tostring(DEFAULT_MAX_PHOTOS)
end

local function applyMacSafeDefaults(props)
    props.performanceProfile = PROFILE_LOW_MEMORY
    props.defaultSuggestions = tostring(MAC_SAFE_SUGGESTIONS)
    props.maxPhotosPerRun = tostring(MAC_SAFE_MAX_PHOTOS)
end

local function getProfileSettings(profile)
    if profile == PROFILE_LOW_MEMORY then
        return true, true, "Lowest memory usage. Best for older or RAM-constrained Macs, but usually the slowest."
    end

    if profile == PROFILE_BALANCED then
        return true, false, "A middle ground. Uses a smaller model without forcing CPU-only execution."
    end

    return false, false, "Best speed. Uses the larger model and allows hardware acceleration when available."
end

local function getProfileTitle(profile)
    if profile == PROFILE_LOW_MEMORY then
        return "Low Memory"
    end
    if profile == PROFILE_BALANCED then
        return "Balanced"
    end
    return "Fastest"
end

local function clampWholeNumber(value, fallback, minValue, maxValue)
    local n = tonumber(value)
    if not n then
        n = fallback
    end
    return math.max(minValue, math.min(maxValue, math.floor(n)))
end

local function saveRuntimeSettings(props)
    local suggestions = clampWholeNumber(props.defaultSuggestions, getConfiguredSuggestionsPerImage(), 1, 30)
    local maxPhotos = clampWholeNumber(props.maxPhotosPerRun, getConfiguredMaxPhotosPerRun(), 1, 200)
    local profile = trim(props.performanceProfile) or PROFILE_BALANCED
    local lowMemoryMode, preferCpu = getProfileSettings(profile)

    prefs.aiDefaultSuggestionsPerImage = suggestions
    prefs.aiMaxPhotosPerRun = maxPhotos
    prefs.aiPerformanceProfile = profile
    prefs.aiLowMemoryMode = lowMemoryMode and true or false
    prefs.aiPreferCpu = preferCpu and true or false
    prefs.aiBootstrapNoticeDismissed = props.hideStartupNotice and true or false

    return suggestions, maxPhotos, profile
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext("localAiRuntimeManagerDialog", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)

        props.hideStartupNotice = prefs.aiBootstrapNoticeDismissed and true or false
        props.defaultSuggestions = tostring(getConfiguredSuggestionsPerImage())
        props.maxPhotosPerRun = tostring(getConfiguredMaxPhotosPerRun())
        props.performanceProfile = getConfiguredPerformanceProfile()

        local installSummary = nil
        local uninstallButtonTitle = nil
        local uninstallAction = nil

        if IS_WINDOWS then
            local paths = getWindowsPaths()
            installSummary = f:column {
                spacing = 4,
                f:static_text { title = "Ollama install location: " .. tostring(paths.installDir or "Unknown"), width_in_chars = 90 },
                f:static_text { title = "Model storage: " .. tostring(paths.modelsDir or "Unknown"), width_in_chars = 90 },
            }

            if pathExists(paths.uninstaller) then
                uninstallButtonTitle = "Run Ollama Uninstaller"
                uninstallAction = function()
                    launchWindowsUninstaller(paths.uninstaller)
                end
            end
        else
            local paths = getMacPaths()
            installSummary = f:column {
                spacing = 4,
                f:static_text { title = "Ollama app location: " .. tostring(paths.appPath), width_in_chars = 90 },
                f:static_text { title = "Ollama CLI locations: " .. tostring(paths.cliPath) .. " or " .. tostring(paths.altCliPath), width_in_chars = 90 },
                f:static_text { title = "Model storage: " .. tostring(paths.modelsDir or "Unknown"), width_in_chars = 90 },
            }

            uninstallButtonTitle = "Show Uninstall Steps"
            uninstallAction = function()
                showMacUninstallInstructions(paths)
            end
        end

        local contents = f:column {
            bind_to_object = props,
            spacing = 12,

            f:static_text {
                title = "Configure how Local AI behaves on this machine. These settings control the default suggestion count, how many photos can be processed in one run, and whether the plugin should prefer lighter Ollama settings.",
                width_in_chars = 95
            },

            f:separator { fill_horizontal = 1 },

            f:column {
                spacing = 8,
                f:static_text { title = "Performance Defaults", width_in_chars = 40 },
                f:row {
                    spacing = 10,
                    f:static_text { title = "Performance profile", width_in_chars = 28 },
                    f:popup_menu {
                        value = LrView.bind("performanceProfile"),
                        width_in_chars = 20,
                        items = {
                            { title = "Fastest", value = PROFILE_FASTEST },
                            { title = "Balanced", value = PROFILE_BALANCED },
                            { title = "Low Memory", value = PROFILE_LOW_MEMORY },
                        }
                    },
                },
                f:static_text {
                    title = "Fastest uses more resources, Balanced uses a smaller model, and Low Memory also prefers CPU for maximum stability.",
                    width_in_chars = 95
                },
                f:row {
                    spacing = 10,
                    f:static_text { title = "Suggestions per image", width_in_chars = 28 },
                    f:edit_field { value = LrView.bind("defaultSuggestions"), width_in_chars = 8 },
                    f:static_text { title = "Allowed range: 1 to 30", width_in_chars = 24 },
                },
                f:row {
                    spacing = 10,
                    f:static_text { title = "Max selected photos per AI run", width_in_chars = 28 },
                    f:edit_field { value = LrView.bind("maxPhotosPerRun"), width_in_chars = 8 },
                    f:static_text { title = "Allowed range: 1 to 200", width_in_chars = 24 },
                },
                f:checkbox {
                    title = "Hide the detailed Local AI setup notice before future AI runs",
                    value = LrView.bind("hideStartupNotice")
                },
            },

            f:row {
                spacing = 10,
                f:push_button {
                    title = "Use Standard Defaults",
                    action = function()
                        applyStandardDefaults(props)
                    end
                },
                f:push_button {
                    title = "Use Low-End Mac Defaults",
                    action = function()
                        applyMacSafeDefaults(props)
                    end
                },
            },

            f:separator { fill_horizontal = 1 },

            f:column {
                spacing = 6,
                f:static_text { title = "Runtime Details", width_in_chars = 40 },
                f:static_text {
                    title = "If Ollama is missing, the plugin can install it and download a vision model on the first Local AI run. The first run may take several minutes and several gigabytes of downloads.",
                    width_in_chars = 95
                },
                f:static_text {
                    title = "Temporary Lightroom JPEG previews are created only for the current AI run and are deleted afterward.",
                    width_in_chars = 95
                },
                installSummary,
            },

            f:separator { fill_horizontal = 1 },

            f:row {
                spacing = 10,
                f:push_button {
                    title = uninstallButtonTitle,
                    enabled = uninstallButtonTitle and true or false,
                    action = function()
                        if uninstallAction then
                            uninstallAction()
                        end
                    end
                },
                f:static_text {
                    title = "Use this only if you want to remove the Ollama runtime from your system.",
                    width_in_chars = 65
                },
            },
        }

        local result = LrDialogs.presentModalDialog {
            title = "Manage Local AI Runtime",
            contents = contents,
            actionVerb = "Save Settings",
            cancelVerb = "Close"
        }

        if result ~= "ok" then
            return
        end

        local suggestions, maxPhotos, profile = saveRuntimeSettings(props)
        local _, _, profileSummary = getProfileSettings(profile)
        LrDialogs.message(
            "Local AI settings saved",
            "Suggestions per image: " .. tostring(suggestions) .. "\n" ..
            "Max selected photos per run: " .. tostring(maxPhotos) .. "\n" ..
            "Performance profile: " .. getProfileTitle(profile) .. "\n" ..
            profileSummary,
            "OK"
        )
    end)
end)
