local LrTasks = import 'LrTasks'

local UpdateCore = require 'PluginUpdateCore'

LrTasks.startAsyncTask(function()
    UpdateCore.runManualCheck()
end)
