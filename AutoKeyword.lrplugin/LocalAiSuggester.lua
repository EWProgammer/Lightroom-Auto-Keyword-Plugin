local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'

local LocalAiSuggester = {}

-- Set to true after configuring LOCAL_AI_COMMAND.
local LOCAL_AI_ENABLED = false

-- Local-only command template. It must write plain text keywords to %OUTPUT_FILE%.
-- Tokens:
--   %IMAGE_PATH%   absolute path to photo file
--   %HISTORY_FILE% text file containing prior keyword profile
--   %OUTPUT_FILE%  output file your local AI should write (comma/newline separated)
-- Important: Do not wrap placeholders in quotes; quoting is handled internally.
-- Example command (edit for your machine):
--   /usr/local/bin/keyword-ai --image %IMAGE_PATH% --history %HISTORY_FILE% --out %OUTPUT_FILE%
local LOCAL_AI_COMMAND = ''

local function trim(value)
    if value == nil then return nil end
    local s = tostring(value):gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' then return nil end
    return s
end

local function shellQuote(s)
    s = tostring(s or '')
    s = s:gsub("'", "'\\''")
    return "'" .. s .. "'"
end

local function uniqueTempPath(prefix, ext)
    local tempDir = LrPathUtils.getStandardFilePath('temp') or '/tmp'
    local stamp = tostring(os.time()) .. '_' .. tostring(math.random(100000, 999999))
    return LrPathUtils.child(tempDir, prefix .. '_' .. stamp .. ext)
end

local function parseKeywordOutput(text)
    local words = {}
    local seen = {}
    for token in tostring(text or ''):gmatch('[^,\n\r;]+') do
        local w = trim(token)
        if w then
            local key = string.lower(w)
            if not seen[key] then
                seen[key] = true
                words[#words + 1] = w
            end
        end
    end
    return words
end

function LocalAiSuggester.isConfigured()
    return LOCAL_AI_ENABLED and LOCAL_AI_COMMAND ~= ''
end

function LocalAiSuggester.suggest(photoPath, historyText)
    if not LOCAL_AI_ENABLED or LOCAL_AI_COMMAND == '' then
        return {}, 'Local AI disabled (set LOCAL_AI_ENABLED and LOCAL_AI_COMMAND in LocalAiSuggester.lua)'
    end

    local imagePath = trim(photoPath)
    if not imagePath then
        return {}, 'Missing image path'
    end

    local historyFile = uniqueTempPath('lrkw_history', '.txt')
    local outputFile = uniqueTempPath('lrkw_ai_output', '.txt')

    LrFileUtils.writeFile(historyFile, tostring(historyText or ''))

    local cmd = LOCAL_AI_COMMAND
    cmd = cmd:gsub('%%IMAGE_PATH%%', shellQuote(imagePath))
    cmd = cmd:gsub('%%HISTORY_FILE%%', shellQuote(historyFile))
    cmd = cmd:gsub('%%OUTPUT_FILE%%', shellQuote(outputFile))

    local exitCode = LrTasks.execute(cmd)
    if exitCode ~= 0 then
        pcall(function() LrFileUtils.delete(historyFile) end)
        pcall(function() LrFileUtils.delete(outputFile) end)
        return {}, 'Local AI command failed with exit code ' .. tostring(exitCode)
    end

    local outputText = ''
    if LrFileUtils.exists(outputFile) then
        outputText = LrFileUtils.readFile(outputFile) or ''
    end

    pcall(function() LrFileUtils.delete(historyFile) end)
    pcall(function() LrFileUtils.delete(outputFile) end)

    return parseKeywordOutput(outputText), nil
end

return LocalAiSuggester
