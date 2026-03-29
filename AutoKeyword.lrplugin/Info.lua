return {
    LrSdkVersion = 6.0,
    LrToolkitIdentifier = "com.ericweist.aikeyword",
    LrPluginName = "AI Keyword Generator",
    LrInitPlugin = "PluginInit.lua",
    VERSION = { major=1, minor=4, revision=0, build=0 },

    LrLibraryMenuItems = {
        {
            title = "AI Generate Keywords",
            file = "KeywordRunner.lua",
            enabledWhen = "photosSelected",
        },
        {
            title = "Manage Style Presets",
            file = "MenuEntry.lua",
        },
        {
            title = "Manage Local AI Runtime",
            file = "LocalAiRuntimeManager.lua",
        },
        {
            title = "Check for Plugin Updates",
            file = "PluginUpdater.lua",
        },
    },
}
