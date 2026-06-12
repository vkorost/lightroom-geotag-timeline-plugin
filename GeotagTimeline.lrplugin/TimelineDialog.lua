local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrPrefs = import 'LrPrefs'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'

local TimelineDialog = {}

function TimelineDialog.showDialog(photoCount)
    local prefs = LrPrefs.prefsForPlugin()
    local result = nil

    LrFunctionContext.callWithContext("GeotagTimelineDialog", function(context)
        local props = LrBinding.makePropertyTable(context)

        -- Load saved values or defaults
        props.timelinePath     = prefs.lastTimelinePath or ""
        props.maxHours         = prefs.lastMaxHours or 24
        props.timeAdjustment   = prefs.lastTimeAdjustment or 0
        props.reverseGeocode   = (prefs.lastReverseGeocode ~= false) -- default true
        props.overwriteExisting = prefs.lastOverwriteExisting or false

        local f = LrView.osFactory()

        local contents = f:column {
            spacing = f:dialog_spacing(),
            bind_to_object = props,

            -- Photo count
            f:row {
                f:static_text {
                    title = string.format("Selected photos: %d", photoCount),
                    font = "<system/bold>",
                },
            },

            f:separator { fill_horizontal = 1 },

            -- Timeline file
            f:row {
                f:static_text {
                    title = "Google Timeline JSON:",
                    alignment = 'right',
                    width = LrView.share 'label_width',
                },
                f:edit_field {
                    value = LrView.bind 'timelinePath',
                    width_in_chars = 45,
                },
                f:push_button {
                    title = "Browse...",
                    action = function()
                        local paths = LrDialogs.runOpenPanel {
                            title = "Select Google Timeline JSON",
                            canChooseFiles = true,
                            canChooseDirectories = false,
                            allowsMultipleSelection = false,
                            fileTypes = { 'json' },
                        }
                        if paths then
                            props.timelinePath = paths[1]
                        end
                    end,
                },
            },

            -- Max hours
            f:row {
                f:static_text {
                    title = "Max time window (hours):",
                    alignment = 'right',
                    width = LrView.share 'label_width',
                },
                f:edit_field {
                    value = LrView.bind 'maxHours',
                    width_in_digits = 5,
                },
                f:static_text {
                    title = "Maximum gap between photo time and location record",
                },
            },

            -- Time adjustment
            f:row {
                f:static_text {
                    title = "Time adjustment (hours):",
                    alignment = 'right',
                    width = LrView.share 'label_width',
                },
                f:edit_field {
                    value = LrView.bind 'timeAdjustment',
                    width_in_digits = 5,
                },
                f:static_text {
                    title = "Shift photo times if camera timezone differs",
                },
            },

            -- Checkboxes
            f:row {
                f:static_text {
                    title = "",
                    width = LrView.share 'label_width',
                },
                f:checkbox {
                    title = "Reverse geocode (add city, state, country)",
                    value = LrView.bind 'reverseGeocode',
                },
            },

            f:row {
                f:static_text {
                    title = "",
                    width = LrView.share 'label_width',
                },
                f:checkbox {
                    title = "Overwrite existing GPS data",
                    value = LrView.bind 'overwriteExisting',
                },
            },
        }

        local dialogResult = LrDialogs.presentModalDialog {
            title = "Geotag from Google Timeline",
            contents = contents,
            actionVerb = "Geotag",
        }

        if dialogResult == "ok" then
            -- Validate timeline path
            if not props.timelinePath or props.timelinePath == "" then
                LrDialogs.message(
                    "Geotag from Timeline",
                    "Please select a Google Timeline JSON file.",
                    "critical"
                )
                return
            end

            -- Persist settings
            prefs.lastTimelinePath     = props.timelinePath
            prefs.lastMaxHours         = props.maxHours
            prefs.lastTimeAdjustment   = props.timeAdjustment
            prefs.lastReverseGeocode   = props.reverseGeocode
            prefs.lastOverwriteExisting = props.overwriteExisting

            result = {
                timelinePath     = props.timelinePath,
                maxHours         = props.maxHours,
                timeAdjustment   = props.timeAdjustment,
                reverseGeocode   = props.reverseGeocode,
                overwriteExisting = props.overwriteExisting,
            }
        end
    end)

    return result
end

return TimelineDialog
