-- ============================================================================
-- LOCALAISUGGESTER.LUA
-- Custom Local AI Integration Module
-- ============================================================================
-- This module provides an interface for running a custom external AI command
-- to generate keyword suggestions. This is useful if you want to use a 
-- different AI service instead of Ollama. Users can configure their own
-- command and specify how it should be called.
-- ============================================================================

-- Import Lightroom's task management for executing system commands
local LrTasks = import 'LrTasks'

-- Import Lightroom's file path utilities for temp file handling
local LrPathUtils = import 'LrPathUtils'

-- Import Lightroom's file I/O utilities for reading/writing files
local LrFileUtils = import 'LrFileUtils'

-- Module table that will be exported for other scripts to use
local LocalAiSuggester = {}

-- CONFIGURATION: Set to true only after configuring LOCAL_AI_COMMAND below
local LOCAL_AI_ENABLED = false

-- ============================================================================
-- CONFIGURATION: Custom Local AI Command
-- ============================================================================
-- Define your custom AI command template here. The plugin will substitute
-- the placeholder tokens with actual paths at runtime.
--
-- Required output: Your command MUST write plain text keywords to %OUTPUT_FILE%
-- Keywords can be comma-separated, newline-separated, or semicolon-separated.
--
-- Available placeholder tokens:
--   %IMAGE_PATH%   - Absolute file path to the photo being analyzed
--   %HISTORY_FILE% - Text file containing previously used keywords/history
--   %OUTPUT_FILE%  - File path where your AI should write the generated keywords
--
-- Important notes:
--   - Do NOT manually quote placeholders; the plugin handles quoting for you
--   - The command should exit with code 0 on success, non-zero on error
--   - Output file should be created even if no keywords could be generated
--
-- Example for a local Python script:
--   /usr/local/bin/keyword-ai --image %IMAGE_PATH% --history %HISTORY_FILE% --out %OUTPUT_FILE%
--
-- Example for a local NodeJS service:
--   node /opt/keyword-service/index.js %IMAGE_PATH% %HISTORY_FILE% %OUTPUT_FILE%
--
local LOCAL_AI_COMMAND = ''

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

--- Removes leading and trailing whitespace from a string
-- Returns nil if string is empty after trimming
-- @param value The string to trim
-- @return Trimmed string or nil if empty
local function trim(value)
    if value == nil then return nil end
    local s = tostring(value):gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' then return nil end
    return s
end

--- Escapes a string for safe use in POSIX shell commands
-- Wraps the string in single quotes and escapes any existing single quotes
-- @param s The string to escape
-- @return Shell-escaped string safe for POSIX systems
local function shellQuote(s)
    s = tostring(s or '')
    -- Escape single quotes by ending quote, adding escaped quote, starting quote again
    s = s:gsub("'", "'\\''")
    return "'" .. s .. "'"
end

--- Generates a unique temporary file path
-- Creates a path in the system's temp directory with a timestamped filename
-- to avoid collisions
-- @param prefix String prefix for the temp file (e.g., "lrkw_history")
-- @param ext File extension (e.g., ".txt")
-- @return Unique full path to temp file
local function uniqueTempPath(prefix, ext)
    local tempDir = LrPathUtils.getStandardFilePath('temp') or '/tmp'
    local stamp = tostring(os.time()) .. '_' .. tostring(math.random(100000, 999999))
    return LrPathUtils.child(tempDir, prefix .. '_' .. stamp .. ext)
end

--- Parses AI command output into individual keywords
-- Handles multiple delimiters (commas, newlines, semicolons)
-- Automatically deduplicates keywords (case-insensitive)
-- @param text The raw output from the AI command
-- @return Array of unique keyword strings
local function parseKeywordOutput(text)
    local words = {}
    local seen = {}
    
    -- Split input by common delimiters
    for token in tostring(text or ''):gmatch('[^,\n\r;]+') do
        local w = trim(token)
        if w then
            -- Track seen keywords (lowercase for case-insensitive deduplication)
            local key = string.lower(w)
            if not seen[key] then
                seen[key] = true
                words[#words + 1] = w  -- Preserve original casing in output
            end
        end
    end
    
    return words
end

-- ============================================================================
-- PUBLIC API FUNCTIONS
-- ============================================================================

--- Checks if a custom local AI command has been configured
-- @return Boolean: true if LOCAL_AI_ENABLED is true and command is set
function LocalAiSuggester.isConfigured()
    return LOCAL_AI_ENABLED and LOCAL_AI_COMMAND ~= ''
end

--- Executes the custom AI command to generate keyword suggestions
-- Creates temporary files for history and output, executes the command,
-- and cleans up temporary files after execution
-- @param photoPath Absolute path to the photo file to analyze
-- @param historyText (Optional) String of previously used keywords
-- @return keywords Array of suggested keywords from the AI
-- @return errorMsg Nil on success, error message string on failure
function LocalAiSuggester.suggest(photoPath, historyText)
    -- Validate that custom AI is configured
    if not LOCAL_AI_ENABLED or LOCAL_AI_COMMAND == '' then
        return {}, 'Local AI disabled (set LOCAL_AI_ENABLED and LOCAL_AI_COMMAND in LocalAiSuggester.lua)'
    end

    -- Validate input photo path
    local imagePath = trim(photoPath)
    if not imagePath then
        return {}, 'Missing image path'
    end

    -- Create temporary files for this operation
    local historyFile = uniqueTempPath('lrkw_history', '.txt')
    local outputFile = uniqueTempPath('lrkw_ai_output', '.txt')

    -- Write history to temp file (for context in keyword generation)
    LrFileUtils.writeFile(historyFile, tostring(historyText or ''))

    -- Build command by substituting placeholder tokens with actual values
    local cmd = LOCAL_AI_COMMAND
    cmd = cmd:gsub('%%IMAGE_PATH%%', shellQuote(imagePath))
    cmd = cmd:gsub('%%HISTORY_FILE%%', shellQuote(historyFile))
    cmd = cmd:gsub('%%OUTPUT_FILE%%', shellQuote(outputFile))

    -- Execute the custom AI command
    local exitCode = LrTasks.execute(cmd)
    
    -- Handle command execution errors
    if exitCode ~= 0 then
        -- Clean up temp files even on error
        pcall(function() LrFileUtils.delete(historyFile) end)
        pcall(function() LrFileUtils.delete(outputFile) end)
        return {}, 'Local AI command failed with exit code ' .. tostring(exitCode)
    end

    -- Read the output file generated by the AI command
    local outputText = ''
    if LrFileUtils.exists(outputFile) then
        outputText = LrFileUtils.readFile(outputFile) or ''
    end

    -- Clean up temporary files
    pcall(function() LrFileUtils.delete(historyFile) end)
    pcall(function() LrFileUtils.delete(outputFile) end)

    -- Parse and return the keywords
    return parseKeywordOutput(outputText), nil
end

-- Export the module for use by other scripts
return LocalAiSuggester
