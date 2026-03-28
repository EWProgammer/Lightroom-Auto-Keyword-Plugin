return {
    LrSdkVersion = 6.0,
    LrToolkitIdentifier = "com.ericweist.aikeyword",
    LrPluginName = "AI Keyword Generator",
    VERSION = { major=1, minor=3, revision=0, build=0 },

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
    },
}
