local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrApplication = import 'LrApplication'
local LrProgressScope = import 'LrProgressScope'
local LrDate = import 'LrDate'

local TimelineDialog = require 'TimelineDialog'
local PythonBridge = require 'PythonBridge'

-- Lightroom epoch offset: seconds between 1970-01-01 and 2001-01-01 (both GMT)
local LR_EPOCH_OFFSET = 978307200

local function lrDateToPosix(lrDate)
    if LrDate.timeToPosixDate then
        return LrDate.timeToPosixDate(lrDate)
    end
    -- Fallback: Lightroom stores seconds since 2001-01-01 GMT
    return lrDate + LR_EPOCH_OFFSET
end

LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()

    if #photos == 0 then
        LrDialogs.message("Geotag from Timeline", "No photos selected.", "warning")
        return
    end

    -- Show settings dialog
    local settings = TimelineDialog.showDialog(#photos)
    if not settings then return end -- user cancelled

    local progressScope = LrProgressScope {
        title = "Geotagging from Google Timeline",
    }

    -- Phase 1: Collect photo metadata
    progressScope:setCaption("Reading photo metadata...")
    local photoData = {}
    local skippedCount = 0
    local noDateCount = 0

    for i, photo in ipairs(photos) do
        if progressScope:isCanceled() then
            progressScope:done()
            return
        end
        progressScope:setPortionComplete(i, #photos)

        local dateTime = photo:getRawMetadata('dateTimeOriginal')
        if dateTime then
            local existingGps = photo:getRawMetadata('gps')
            if existingGps and not settings.overwriteExisting then
                skippedCount = skippedCount + 1
            else
                photoData[#photoData + 1] = {
                    id       = tostring(photo.localIdentifier),
                    filename = photo:getRawMetadata('path'),
                    timestamp = tonumber(lrDateToPosix(dateTime)) or 0,
                    photo    = photo, -- keep reference for phase 3
                }
            end
        else
            noDateCount = noDateCount + 1
        end
    end

    if #photoData == 0 then
        progressScope:done()
        local msg = "No photos to process."
        if skippedCount > 0 then
            msg = msg .. string.format(
                "\n%d photo(s) already have GPS data (enable 'Overwrite' to re-tag).",
                skippedCount
            )
        end
        if noDateCount > 0 then
            msg = msg .. string.format(
                "\n%d photo(s) have no capture date.",
                noDateCount
            )
        end
        LrDialogs.message("Geotag from Timeline", msg, "info")
        return
    end

    -- Phase 2: Call Python to match locations
    progressScope:setCaption(
        string.format("Matching %d photos to timeline (this may take a while)...", #photoData)
    )
    progressScope:setPortionComplete(0, 1) -- indeterminate during Python

    local output = PythonBridge.matchLocations(photoData, settings)
    if not output or not output.results then
        progressScope:done()
        return
    end

    -- Build lookup: id -> LrPhoto object
    local photoLookup = {}
    for _, pd in ipairs(photoData) do
        photoLookup[pd.id] = pd.photo
    end

    -- Phase 3: Write GPS + location metadata to catalog
    progressScope:setCaption("Writing GPS data to catalog...")
    local taggedCount = 0
    local noMatchCount = 0
    local errorCount = 0
    local errorDetails = {}

    catalog:withWriteAccessDo("Geotag from Google Timeline", function()
        for i, result in ipairs(output.results) do
            if progressScope:isCanceled() then return end
            progressScope:setPortionComplete(i, #output.results)

            if result.matched then
                local photo = photoLookup[result.id]
                if photo then
                    local ok, err = pcall(function()
                        -- GPS coordinates
                        photo:setRawMetadata('gps', {
                            latitude  = result.latitude,
                            longitude = result.longitude,
                        })

                        -- IPTC location fields
                        if result.city and result.city ~= '' then
                            photo:setRawMetadata('city', result.city)
                        end
                        if result.state and result.state ~= '' then
                            photo:setRawMetadata('stateProvince', result.state)
                        end
                        if result.country and result.country ~= '' then
                            photo:setRawMetadata('country', result.country)
                        end
                        if result.iso_country_code and result.iso_country_code ~= '' then
                            photo:setRawMetadata('isoCountryCode', result.iso_country_code)
                        end
                    end)

                    if ok then
                        taggedCount = taggedCount + 1
                    else
                        errorCount = errorCount + 1
                        if #errorDetails < 5 then
                            errorDetails[#errorDetails + 1] = tostring(err)
                        end
                    end
                end
            else
                noMatchCount = noMatchCount + 1
            end
        end
    end)

    progressScope:done()

    -- Phase 4: Summary dialog
    local summary = string.format(
        "Geotagging complete!\n\n" ..
        "  Photos tagged:           %d\n" ..
        "  No match found:          %d\n" ..
        "  Already tagged (skipped): %d\n" ..
        "  No capture date:          %d\n" ..
        "  Errors:                   %d",
        taggedCount, noMatchCount, skippedCount, noDateCount, errorCount
    )

    if #errorDetails > 0 then
        summary = summary .. "\n\nFirst error(s):\n"
        for _, e in ipairs(errorDetails) do
            summary = summary .. "  - " .. e .. "\n"
        end
    end

    LrDialogs.message("Geotag from Timeline", summary, "info")
end)
