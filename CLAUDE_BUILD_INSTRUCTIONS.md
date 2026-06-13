# Claude Code Build Instructions

Use this file as a prompt for Claude Code (or any AI coding assistant) to build the Lightroom geotagging plugin from scratch. Copy the entire contents into a new Claude Code session and it will produce a working plugin.

---

## Assignment

Build an Adobe Lightroom Classic plugin that geotags photos using Google Timeline location history. The plugin must be written in Lua (Lightroom's plugin language) with a bundled Python script that handles the heavy processing. No external Python packages are required.

## What the plugin does

1. The user selects photos in Lightroom's Library module
2. The user invokes the plugin from Library > Plug-in Extras
3. A dialog asks the user to pick their Google Timeline JSON file and set matching options
4. The plugin collects each photo's capture timestamp from the Lightroom catalog
5. A Python script parses the Google Timeline JSON, finds the closest location for each photo using binary search, and optionally reverse-geocodes coordinates to city/state/country
6. The plugin writes GPS coordinates and IPTC location fields (city, state/province, country, ISO country code) back into the Lightroom catalog
7. When the user later exports photos as JPEG, the location data is embedded automatically

## Architecture

```
Lightroom (Lua)                          Python script
─────────────────                        ──────────────
Collect photo IDs + timestamps    →      Read input JSON
Write temp input JSON file        →      Parse Google Timeline JSON
Call Python via LrTasks.execute   →      Binary search: match photo timestamps to locations
                                  →      Reverse geocode via Nominatim (OpenStreetMap)
Read temp output JSON file        ←      Write output JSON file
Write GPS + IPTC to catalog
Show summary dialog
```

Communication between Lua and Python is done via temporary JSON files (not stdout), because `LrTasks.execute()` only returns exit codes.

## File structure

Create a `.lrplugin` folder with these files:

```
GeotagTimeline.lrplugin/
  Info.lua                 Plugin registration, menu item, SDK version
  GeotagMenuEntry.lua      Main entry point: orchestrates the full workflow
  TimelineDialog.lua       Settings dialog (file picker, options)
  PythonBridge.lua         Writes input JSON, calls Python, reads output JSON
  JSON.lua                 Self-contained JSON encoder/decoder (no external deps)
  PluginInfoProvider.lua   Plugin Manager settings panel (Python path config)
  timeline_matcher.py      Python script: parses timeline, matches, geocodes
```

## Lightroom SDK details

### Info.lua
- `LrSdkVersion = 6.0` (minimum 4.0 for GPS support)
- `LrToolkitIdentifier` = unique reverse-domain string
- `LrLibraryMenuItems` = one menu item pointing to `GeotagMenuEntry.lua`
- `LrPluginInfoProvider` = points to `PluginInfoProvider.lua`

### Key SDK APIs used

```lua
-- Get selected photos
local catalog = LrApplication.activeCatalog()
local photos = catalog:getTargetPhotos()

-- Read photo metadata
photo:getRawMetadata('dateTimeOriginal')  -- returns a number (LrDate internal time)
photo:getRawMetadata('gps')              -- returns table {latitude, longitude} or nil
photo:getRawMetadata('path')             -- file path string
photo.localIdentifier                    -- unique numeric ID in the catalog

-- Convert LrDate to POSIX timestamp
-- LrDate epoch is 2001-01-01 GMT. POSIX epoch is 1970-01-01 GMT.
-- Difference: 978307200 seconds.
-- Use LrDate.timeToPosixDate(lrDate) if available, otherwise add 978307200.

-- Write metadata (must be inside catalog:withWriteAccessDo)
catalog:withWriteAccessDo("action name", function()
    photo:setRawMetadata('gps', { latitude = 40.76, longitude = -73.98 })
    photo:setRawMetadata('city', "New York")
    photo:setRawMetadata('stateProvince', "New York")
    photo:setRawMetadata('country', "United States")
    photo:setRawMetadata('isoCountryCode', "USA")
end)

-- Everything must run inside an async task
LrTasks.startAsyncTask(function()
    -- all plugin logic here
end)

-- Execute external command
LrTasks.execute(cmd)  -- returns exit code (number), blocks until done

-- Progress bar
local scope = LrProgressScope { title = "..." }
scope:setCaption("...")
scope:setPortionComplete(i, total)
scope:isCanceled()  -- check if user cancelled
scope:done()

-- File dialog
LrDialogs.runOpenPanel { title, canChooseFiles, fileTypes = {'json'} }

-- Modal dialog
LrDialogs.presentModalDialog { title, contents, actionVerb = "Geotag" }
-- returns "ok" if user clicked the action button

-- Preferences (persist between sessions)
local prefs = LrPrefs.prefsForPlugin()
prefs.someKey = someValue

-- View factory for building dialog UI
local f = LrView.osFactory()
f:column { ... }
f:row { ... }
f:static_text { title = "..." }
f:edit_field { value = LrView.bind 'key' }
f:checkbox { title = "...", value = LrView.bind 'key' }
f:push_button { title = "Browse...", action = function() ... end }
f:separator { fill_horizontal = 1 }

-- Path utilities
LrPathUtils.child(parent, child)
LrPathUtils.getStandardFilePath("temp")
_PLUGIN.path  -- path to the plugin folder

-- File utilities
LrFileUtils.exists(path)
LrFileUtils.readFile(path)
LrFileUtils.delete(path)
```

### Critical gotchas (bugs we hit and fixed)

1. **Lightroom edit fields return strings, not numbers.** When the user types "24" into a numeric edit field, the value is the string `"24"`, not the number `24`. Always use `tonumber()` in Lua before passing to JSON, and `float()` in Python when reading from JSON. This affects `maxHours`, `timeAdjustment`, and `timestamp`.

2. **JSON.decode must not be called with the module as first arg.** When using pcall:
   ```lua
   -- WRONG: passes JSON table as first arg to decode
   local ok, result = pcall(JSON.decode, JSON, str)

   -- RIGHT: wrap in anonymous function
   local ok, result = pcall(function() return JSON.decode(str) end)
   ```

3. **Capture Python stderr.** Redirect stderr to a temp log file in the command:
   ```lua
   local cmd = string.format('"%s" "%s" "%s" "%s" 2>"%s"',
       pythonPath, scriptPath, inputPath, outputPath, logPath)
   ```
   Read and display the log file if the exit code is non-zero. Without this, Python tracebacks are invisible.

4. **Windows command quoting.** On Windows, `LrTasks.execute` goes through `cmd.exe`, which needs the entire command wrapped in an extra set of quotes:
   ```lua
   if WIN_ENV then
       cmd = '"' .. cmd .. '"'
   end
   ```
   `WIN_ENV` is a global boolean set by Lightroom on Windows.

5. **Writing temp files.** There is no `LrFileUtils.writeFile`. Use `io.open(path, 'w')` for writing. `LrFileUtils.readFile` works for reading.

6. **dateTimeOriginal is an LrDate number, not a string.** Convert to POSIX using `LrDate.timeToPosixDate()` or by adding 978307200 (the offset between the LrDate epoch of 2001-01-01 and the POSIX epoch of 1970-01-01). Always wrap with `tonumber()` for safety.

## JSON.lua requirements

Write a self-contained JSON encoder/decoder in pure Lua. No external dependencies. It must handle:
- Encode: tables (detect array vs object by checking consecutive integer keys), strings (escape backslash, quotes, newlines, tabs), numbers (handle NaN, infinity), booleans, nil as null
- Decode: objects, arrays, strings (with escape sequences including \uXXXX), numbers (integer, float, scientific notation), true, false, null
- Whitespace skipping in decoder

## Python script interface

### Input JSON (written by Lua, read by Python)

```json
{
    "timeline_path": "C:/path/to/Timeline.json",
    "max_hours": 24,
    "time_adjustment_hours": 0,
    "reverse_geocode": true,
    "photos": [
        {
            "id": "12345",
            "filename": "C:/photos/DSC_001.CR3",
            "timestamp": 1728732600
        }
    ]
}
```

### Output JSON (written by Python, read by Lua)

```json
{
    "results": [
        {
            "id": "12345",
            "matched": true,
            "latitude": 40.7593908,
            "longitude": -73.987306,
            "time_diff_hours": 0.3,
            "city": "New York",
            "state": "New York",
            "country": "United States",
            "iso_country_code": "USA"
        },
        {
            "id": "12346",
            "matched": false,
            "reason": "No location within 24 hours"
        }
    ],
    "stats": {
        "total": 2,
        "matched": 1,
        "unmatched": 1,
        "errors": 0
    }
}
```

If there is a top-level error (e.g., timeline file not found):
```json
{
    "error": "Failed to parse timeline: [Errno 2] No such file",
    "results": [],
    "stats": { "total": 2, "matched": 0, "unmatched": 2, "errors": 1 }
}
```

### Python script requirements

- **No external packages.** Use only the Python standard library (json, datetime, bisect, urllib, time, sys).
- Use `bisect.bisect_left` for O(log n) timestamp matching against sorted timeline data.
- Convert all JSON input values to proper types with `float()` since Lua may send strings.
- Wrap `main()` in try/except and write errors to the output file so Lua can display them.
- Print progress to stderr (Lua captures it to a log file for diagnostics).
- Rate-limit reverse geocoding to 1 request per second (Nominatim API requirement).
- Cache reverse geocode results by rounding coordinates to 4 decimal places (~11m precision).
- Use a User-Agent header for Nominatim requests (required by their usage policy).

### Google Timeline JSON formats to support

The Python script must handle all three known Google Timeline JSON export formats:

**Format 1: `semanticSegments` (current, 2024+)**
```json
{
    "semanticSegments": [
        {
            "startTime": "2014-03-28T18:00:00.000-04:00",
            "timelinePath": [
                {
                    "point": "40.7593908°, -73.987306°",
                    "time": "2014-03-28T19:22:00.000-04:00"
                }
            ]
        },
        {
            "startTime": "...",
            "visit": {
                "topCandidate": {
                    "placeLocation": {
                        "latLng": "40.7605248°, -73.9769049°"
                    }
                }
            }
        }
    ]
}
```
Parse both `timelinePath` points (movement) and `visit.topCandidate.placeLocation.latLng` (stationary). Coordinates include degree symbols that must be stripped.

**Format 2: `locations` with `latitudeE7` (older exports)**
```json
{
    "locations": [
        {
            "latitudeE7": 407593908,
            "longitudeE7": -739873060,
            "timestampMs": "1396055520000"
        }
    ]
}
```
Divide `latitudeE7`/`longitudeE7` by 1e7 to get decimal degrees.

**Format 3: `timelineObjects` (intermediate format)**
```json
{
    "timelineObjects": [
        {
            "position": {
                "LatLng": "40.9897797°, 29.0245707°",
                "timestamp": "2025-10-12T10:28:08.000-04:00"
            }
        },
        {
            "activitySegment": {
                "startLocation": { "latitudeE7": 407593908, "longitudeE7": -739873060 },
                "duration": { "startTimestamp": "2023-01-01T12:00:00.000Z" }
            }
        },
        {
            "placeVisit": {
                "location": { "latitudeE7": 407593908, "longitudeE7": -739873060 },
                "duration": { "startTimestamp": "2023-01-01T12:00:00.000Z" }
            }
        }
    ]
}
```

### Reverse geocoding

Use the Nominatim API (OpenStreetMap, free, no API key):
```
GET https://nominatim.openstreetmap.org/reverse?lat=40.76&lon=-73.98&format=json&addressdetails=1&accept-language=en
```
- Required header: `User-Agent: GeotagTimeline-LightroomPlugin/1.0`
- Rate limit: max 1 request per second (use `time.sleep(1.1)`)
- Extract: city (try city/town/village/municipality/county/district), state (try state/province/region), country, country_code
- Convert 2-letter country codes to 3-letter ISO codes for IPTC compatibility

## Settings dialog fields

| Field | Type | Default | Purpose |
|-------|------|---------|---------|
| Google Timeline JSON | file path + browse button | last used path | Path to the exported JSON |
| Max time window (hours) | number | 24 | Maximum gap between photo time and location record |
| Time adjustment (hours) | number | 0 | Shift photo timestamps to compensate for timezone differences |
| Reverse geocode | checkbox | on | Look up city/state/country from coordinates |
| Overwrite existing GPS | checkbox | off | Re-tag photos that already have GPS data |

All settings should persist between sessions using `LrPrefs.prefsForPlugin()`.

## Summary dialog

After processing, show a summary:
```
Geotagging complete!

  Photos tagged:            42
  No match found:            3
  Already tagged (skipped):  5
  No capture date:           0
  Errors:                    0
```

## Testing

After building, test the Python script standalone:

1. Create a test input JSON with a known timeline file and a few photo timestamps
2. Run: `python timeline_matcher.py test_input.json test_output.json`
3. Verify the output JSON has correct matches, coordinates, and geocoded locations
4. Verify that out-of-range photos show `"matched": false`

To test in Lightroom:
1. Add the `.lrplugin` folder via File > Plug-in Manager
2. Select a few photos with known capture dates
3. Run the plugin and verify GPS appears in the Metadata panel
4. Check the Map module to see pins at the correct locations
