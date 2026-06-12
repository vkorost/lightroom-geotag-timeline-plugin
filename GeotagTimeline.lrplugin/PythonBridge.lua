local LrTasks = import 'LrTasks'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'
local LrDialogs = import 'LrDialogs'

local JSON = require 'JSON'

local PythonBridge = {}

function PythonBridge.matchLocations(photoData, settings)
    local prefs = LrPrefs.prefsForPlugin()
    local pythonPath = prefs.pythonPath or "python"

    -- Path to the Python script bundled with this plugin
    local scriptPath = LrPathUtils.child(_PLUGIN.path, "timeline_matcher.py")

    -- Temp file paths
    local tempDir = LrPathUtils.getStandardFilePath("temp")
    local stamp = tostring(os.time()) .. "_" .. tostring(math.random(10000, 99999))
    local inputPath = LrPathUtils.child(tempDir, "geotag_in_" .. stamp .. ".json")
    local outputPath = LrPathUtils.child(tempDir, "geotag_out_" .. stamp .. ".json")
    local logPath = LrPathUtils.child(tempDir, "geotag_log_" .. stamp .. ".txt")

    -- Build the list of photos (strip the LrPhoto object reference)
    local photos = {}
    for _, pd in ipairs(photoData) do
        photos[#photos + 1] = {
            id = pd.id,
            filename = pd.filename,
            timestamp = pd.timestamp,
        }
    end

    local input = {
        timeline_path = settings.timelinePath,
        max_hours = tonumber(settings.maxHours) or 24,
        time_adjustment_hours = tonumber(settings.timeAdjustment) or 0,
        reverse_geocode = settings.reverseGeocode,
        photos = photos,
    }

    -- Write input JSON
    local inputJson = JSON.encode(input)
    local f = io.open(inputPath, 'w')
    if not f then
        LrDialogs.message(
            "Geotag from Timeline",
            "Could not create temporary input file at:\n" .. inputPath,
            "critical"
        )
        return nil
    end
    f:write(inputJson)
    f:close()

    -- Build command line, redirecting stderr to a log file for diagnostics
    local cmd = string.format('"%s" "%s" "%s" "%s" 2>"%s"',
        pythonPath, scriptPath, inputPath, outputPath, logPath)

    -- Windows cmd.exe needs an extra layer of quotes around the whole command
    if WIN_ENV then
        cmd = '"' .. cmd .. '"'
    end

    -- Execute Python script
    local exitCode = LrTasks.execute(cmd)

    -- Clean up input file
    pcall(function() LrFileUtils.delete(inputPath) end)

    -- Read stderr log if it exists
    local stderrLog = ""
    if LrFileUtils.exists(logPath) then
        stderrLog = LrFileUtils.readFile(logPath) or ""
        pcall(function() LrFileUtils.delete(logPath) end)
    end

    -- Check exit code
    if exitCode ~= 0 then
        local errorMsg = "Python script failed (exit code " .. tostring(exitCode) .. ")."

        -- Try to read structured error from output file
        if LrFileUtils.exists(outputPath) then
            local raw = LrFileUtils.readFile(outputPath)
            if raw then
                local ok, parsed = pcall(function() return JSON.decode(raw) end)
                if ok and parsed and parsed.error then
                    errorMsg = errorMsg .. "\n\n" .. parsed.error
                end
            end
            pcall(function() LrFileUtils.delete(outputPath) end)
        end

        -- Append stderr output (Python traceback)
        if stderrLog ~= "" then
            errorMsg = errorMsg .. "\n\nPython stderr:\n" .. stderrLog
        end

        -- Append diagnostics
        errorMsg = errorMsg ..
            "\n\n--- Diagnostics ---" ..
            "\nPython path: " .. pythonPath ..
            "\nScript: " .. scriptPath ..
            "\nConfigure Python in: File > Plug-in Manager > Geotag from Google Timeline"

        LrDialogs.message("Geotag from Timeline", errorMsg, "critical")
        return nil
    end

    -- Read output file
    if not LrFileUtils.exists(outputPath) then
        LrDialogs.message(
            "Geotag from Timeline",
            "Python script completed but produced no output file.",
            "critical"
        )
        return nil
    end

    local outputJson = LrFileUtils.readFile(outputPath)
    pcall(function() LrFileUtils.delete(outputPath) end)

    if not outputJson or outputJson == '' then
        LrDialogs.message(
            "Geotag from Timeline",
            "Python output file is empty.",
            "critical"
        )
        return nil
    end

    -- Parse output
    local ok, output = pcall(function() return JSON.decode(outputJson) end)
    if not ok then
        LrDialogs.message(
            "Geotag from Timeline",
            "Failed to parse Python output:\n" .. tostring(output),
            "critical"
        )
        return nil
    end

    -- Check for top-level error from the Python script
    if output.error then
        LrDialogs.message(
            "Geotag from Timeline",
            "Timeline processing error:\n" .. output.error,
            "critical"
        )
        return nil
    end

    return output
end

return PythonBridge
