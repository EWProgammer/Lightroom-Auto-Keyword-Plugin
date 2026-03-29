-- ============================================================================
-- MANAGESTYLESEENTRY.LUA
-- Style Presets Manager UI Wrapper
-- ============================================================================
-- This is a lightweight wrapper that acts as the entry point for the 
-- "Manage Style Presets" menu item. It launches the actual ManageStyles 
-- UI in an asynchronous context to avoid blocking Lightroom.
-- ============================================================================

-- Import Lightroom's asynchronous task management library
local LrTasks = import 'LrTasks'

-- Start an async task so the dialog UI doesn't freeze Lightroom
-- This loads and executes the main ManageStyles UI module
LrTasks.startAsyncTask(function()
    require "ManageStyles"
end)
