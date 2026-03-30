-- ============================================================================
-- INFO.LUA
-- Lightroom Plugin Manifest and Configuration File
-- ============================================================================
-- This file defines the plugin's metadata and menu configuration for Adobe 
-- Lightroom. It specifies the plugin version, unique identifier, initialization
-- file, and all menu items available to users.
-- ============================================================================

local menuItems = {
    -- Primary menu item: Generates AI keywords for selected photos
    {
        title = "Generate Keywords...",
        file = "KeywordRunner.lua",
        enabledWhen = "photosSelected",  -- Only enabled when at least one photo is selected
    },
    
    -- Settings menu item: Create and edit keyword style presets
    {
        title = "Style Presets...",
        file = "MenuEntry.lua",
    },
    
    -- Settings menu item: Configure Ollama AI runtime and model settings
    {
        title = "Local AI Settings...",
        file = "LocalAiRuntimeManager.lua",
    },
    
    -- Utility menu item: Check GitHub for plugin updates
    {
        title = "Check for Updates...",
        file = "PluginUpdater.lua",
    },
}

return {
    -- SDK version required for Lightroom compatibility
    LrSdkVersion = 6.0,
    
    -- Unique identifier for this plugin (reverse domain notation format)
    LrToolkitIdentifier = "com.ericweist.aikeyword",
    
    -- User-friendly name displayed in Lightroom
    LrPluginName = "AI Keyword Generator",
    
    -- Entry point script executed when plugin initializes
    LrInitPlugin = "PluginInit.lua",

    -- Cleanup hook executed when the plugin or Lightroom shuts down
    LrShutdownPlugin = "PluginShutdown.lua",
    LrShutdownApp = "PluginShutdown.lua",
    
    -- Current plugin version (major.minor.revision.build format)
    VERSION = { major=1, minor=4, revision=2, build=9 },

    -- Menu items added to Lightroom's Library module
    LrLibraryMenuItems = menuItems,
}
