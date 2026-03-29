-- ============================================================================
-- PLUGINUPDATER.LUA
-- Manual Plugin Update Checker UI Handler
-- ============================================================================
-- This module provides a user interface for manually checking updates.
-- When invoked from the Lightroom menu, it displays update information
-- and provides options to upgrade the plugin.
-- ============================================================================

-- Import Lightroom's asynchronous task management library
local LrTasks = import 'LrTasks'

-- Import the core update checking and installation logic
local UpdateCore = require 'PluginUpdateCore'

-- Start an async task that doesn't block Lightroom's UI
-- This runs the manual update check triggered by the user menu selection
LrTasks.startAsyncTask(function()
    UpdateCore.runManualCheck()
end)
