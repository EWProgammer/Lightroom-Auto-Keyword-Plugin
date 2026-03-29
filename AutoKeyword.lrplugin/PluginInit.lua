-- ============================================================================
-- PLUGININIT.LUA
-- Plugin Initialization Handler
-- ============================================================================
-- This script is called automatically when the Lightroom plugin loads.
-- It starts an asynchronous task to check for plugin updates at startup.
-- ============================================================================

-- Import Lightroom's asynchronous task management library
local LrTasks = import 'LrTasks'

-- Import the update checking core module
local UpdateCore = require 'PluginUpdateCore'

-- Start an async task that runs without blocking Lightroom's UI
-- This performs a automatic update check on plugin startup
LrTasks.startAsyncTask(function()
    UpdateCore.runStartupAutoCheck()
end)
